/**
 * SR → driver field flow → invoice, MOBILE side, against the LIVE Ops Hub.
 *
 * Deliverable (A) of docs/HANDOFF-sr-to-invoice-e2e-mobile.md, driven against the REAL Hub: it
 * builds the field data with the real @fieldcapture/contracts forms + field-ticket draft, pushes it
 * through the REAL mobile→Hub wire (OpsHubV1Client /sync/submit, OpsHubSyncTransport
 * /sync/commands, TusUploadClient + /sync/uploads two-phase blob), and asserts the live Hub accepts
 * it — DVIR + JHA events accepted, a field ticket accepted (ticket_no == SR request_no, idempotent
 * replay deduped), and every evidence blob reaches `linked`. Runs for each seeded driver, so the
 * pass proves multiple drivers / jobs / invoices across one run.
 *
 * GATED on FIELD_LIVE_HUB so the default `npm test` stays hermetic:
 *   FIELD_LIVE_HUB=http://192.168.1.149:8000 npm test -- sr-to-invoice-live
 *   FIELD_LIVE_DRIVERS=jose.antonio.martinez,agustin.vela,...   (default: the 5 seeded drivers)
 *   password == username (seeded demo accounts).
 *
 * Loop-closure boundary: the driver role lacks `invoice:read` (Hub RBAC, verified 403), so this
 * test asserts the Hub ACCEPTED the priced inputs and logs request_no + quantity per driver; the
 * resulting priced invoice is verified Hub-side (handoff §6), not from this client.
 */
import { createHash, randomUUID } from 'node:crypto';

import { fieldwork, sync } from '@fieldcapture/contracts';

import {
  OpsHubSyncTransport,
  OpsHubV1Client,
  TusUploadClient,
  createTusFetch,
  type FetchLike,
  type HubFetch,
} from '../src/adapters/sync';
import {
  VolatileBlobBytesSource,
  VolatileBlobUploadStore,
  VolatileFieldFormStore,
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
  VolatileTicketEvidenceStore,
  submitFieldTicket,
  type FieldWorkGate,
} from '../src/domain';
import type { FieldTicketDraft } from '../src/domain/fieldTicketDraft';
import { FieldWorkflowService, SyncEngine, UploadEngine } from '../src/runtime';

const HUB = process.env.FIELD_LIVE_HUB;
const DRIVERS = (
  process.env.FIELD_LIVE_DRIVERS ??
  'jose.antonio.martinez,agustin.vela,alejandro.gonzalez,alex.arizpe,angel.villalpando'
)
  .split(',')
  .map((d) => d.trim())
  .filter(Boolean);
const DEVICE = 'jestLiveE2E';
const APP_VERSION = '0.0.0-live-e2e';

// Node's global fetch satisfies both seams: HubFetch wants {ok,status,json()}; FetchLike wants
// {status,headers.get()} — a WHATWG Response is exactly both.
const hubFetch = globalThis.fetch as unknown as HubFetch;
const tusFetch = globalThis.fetch as unknown as FetchLike;

const describeLive = HUB ? describe : describe.skip;

async function login(baseUrl: string, driver: string): Promise<string> {
  const password = process.env.FIELD_LIVE_PASSWORD ?? driver; // seeded: password == username
  const res = await fetch(`${baseUrl}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: driver, password }),
  });
  if (!res.ok) throw new Error(`login failed ${res.status} for ${driver}`);
  const body = (await res.json()) as { access_token?: string };
  if (!body.access_token) throw new Error(`login returned no access_token for ${driver}`);
  return body.access_token;
}

function makeBlob(mimeType: string, label: string) {
  const bytes = new TextEncoder().encode(`${label}:${randomUUID()}`);
  return {
    blobId: randomUUID(),
    bytes,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    byteLength: bytes.length,
    mimeType,
    localUri: `mem://${label}/${randomUUID()}`,
  };
}

describeLive('SR → invoice, live Hub, real mobile wire (per seeded driver)', () => {
  it.each(DRIVERS)(
    'drives a real driver-day for %s: DVIR + JHA + field ticket + evidence, all accepted on Hub',
    async (driver) => {
      const baseUrl = HUB!;
      const token = await login(baseUrl, driver);
      const tokenProvider = () => token;

      // ----- real clients, composed exactly as wireAppRuntime does -----
      const v1 = new OpsHubV1Client({ baseUrl, sessionToken: token }, hubFetch);
      const transport = new OpsHubSyncTransport({ baseUrl, sessionToken: token }, hubFetch, {
        tokenProvider,
      });
      const tus = new TusUploadClient({ tokenProvider, fetchFn: createTusFetch(tusFetch) });

      let seq = 0;
      const identity = {
        deviceInstanceId: DEVICE,
        allocateLocalSeq: () => seq++,
        generateUuid: () => randomUUID(),
      };
      const outbox = new VolatileSyncOutboxStore();
      const syncEngine = new SyncEngine({
        outbox,
        frontier: new VolatileSyncFrontierStore(),
        transport,
        applyChanges: () => {},
        now: () => new Date(),
        random: () => 0.5,
      });
      const blobs = new VolatileBlobUploadStore();
      const bytesSource = new VolatileBlobBytesSource();
      const uploadEngine = new UploadEngine({
        blobs,
        bytes: bytesSource,
        transport,
        tus,
        enqueueLink: (envelope) => syncEngine.enqueue(envelope),
        linkState: (opId) => outbox.get(opId)?.state,
        identity,
        now: () => new Date(),
      });

      // ----- 1. clock gate must be open (assignments are gated on it) -----
      const status = await v1.getSessionStatus();
      expect(status.clockedIn).toBe(true);

      // ----- 2. pull the seeded assignment -----
      const assignments = await v1.getAssignments();
      expect(assignments.length).toBeGreaterThan(0);
      const sr = assignments[0]!;
      const ticketNo = sr.details?.requestNo; // ticket_no == SR request_no (the loop's join key)
      const snapshotHash = sr.latestServerVersion ?? sr.snapshotHash;
      expect(typeof ticketNo).toBe('string');
      expect(typeof snapshotHash).toBe('string');
      // Hub validates DVIR vehicleRef against the fleet by ID (rejects truck_no/name as
      // vehicle_not_found); the assignment snapshot carries the vehicle's stable id.
      const truck = sr.details?.vehicle?.id ?? sr.details?.vehicle?.name ?? 'TRUCK';

      const gate: FieldWorkGate = {
        state: 'unlocked',
        clockedInSince: status.clockedInSince ?? new Date().toISOString(),
        source: 'timeclock',
      };
      const requirements = sr.details?.workflowRequirements ?? {
        clockInRequired: true,
        requiredSteps: [],
      };
      const workflow = new FieldWorkflowService({
        forms: new VolatileFieldFormStore(),
        gateState: () => gate,
        enqueueEvidence: (envelope) => syncEngine.enqueue(envelope),
        outboxItem: (opId) => outbox.get(opId),
        requirements: () => requirements,
        identity,
        now: () => new Date(),
      });

      const sign = (blobId: string, text: string): fieldwork.SignatureRecord => ({
        blobId,
        signerName: driver,
        signedAtUtc: new Date().toISOString(),
        certificationText: text,
        consentToElectronicSignature: true,
        deviceInstanceId: DEVICE,
        appVersion: APP_VERSION,
      });

      const submitForm = (form: fieldwork.FieldForm) => {
        expect(fieldwork.validateFormCompletion(form)).toEqual([]);
        expect(workflow.saveDraft(form).status).toBe('ok');
        expect(workflow.completeForm(form.formId).status).toBe('ok');
        expect(workflow.submitForm(form.formId).status).toBe('ok');
      };

      // ----- 3. pre-trip DVIR -----
      const preSig = `sig-pre-${randomUUID()}`;
      const preTrip: fieldwork.DvirForm = {
        formId: `dvir-pre-${randomUUID()}`,
        kind: 'pre-trip-dvir',
        vehicleRef: truck,
        odometer: 123456,
        items: [
          { itemId: 'brakes', label: 'Brakes', result: 'ok' },
          { itemId: 'tires', label: 'Tires', result: 'ok' },
          { itemId: 'lights', label: 'Lights', result: 'ok' },
        ],
        signatureBlobIds: [preSig],
        signatures: [sign(preSig, fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT)],
      };
      submitForm(preTrip);

      // ----- 4. JHA for the SR -----
      const jhaSig = `sig-jha-${randomUUID()}`;
      const jha: fieldwork.JhaForm = {
        formId: `jha-${randomUUID()}`,
        kind: 'jha-jsa',
        serviceRequestId: sr.serviceRequestId,
        hazards: [
          { hazardId: 'h2s', description: 'H2S at wellhead', mitigation: 'monitor + PPE' },
          {
            hazardId: 'slip',
            description: 'Slick walkways',
            mitigation: 'three points of contact',
          },
        ],
        signatureBlobIds: [jhaSig],
        signatures: [sign(jhaSig, fieldwork.JHA_CERTIFICATION_TEXT)],
      };
      submitForm(jha);

      // cross-form contract gate: pre-trip + JHA complete → ticket submission allowed
      expect(
        fieldwork.checkTicketSubmitAllowed(
          requirements,
          {
            preTripDvirFormId: preTrip.formId,
            jhaFormIdByServiceRequest: { [sr.serviceRequestId]: jha.formId },
          },
          sr.serviceRequestId,
        ).allowed,
      ).toBe(true);

      // ----- 5. push DVIR + JHA events to the live Hub /sync/commands -----
      const push1 = await syncEngine.pushOnce();
      const recon1 = workflow.reconcileOutcomes();
      if (!recon1.accepted.includes(preTrip.formId) || !recon1.accepted.includes(jha.formId)) {
        // eslint-disable-next-line no-console
        console.error(`[${driver}] DVIR/JHA not all accepted`, { push1, recon1 });
      }
      expect(recon1.accepted).toEqual(expect.arrayContaining([preTrip.formId, jha.formId]));

      // ----- 6. field ticket via the real V1 /sync/submit (domain submit path) -----
      // Hub quantity_bbl is an INTEGER field (fractional → FastAPI 422). Distinct per driver so the
      // resulting invoices are distinguishable Hub-side.
      const idx = Math.max(0, DRIVERS.indexOf(driver));
      const quantityBbl = 80 + idx * 10;
      const draft: FieldTicketDraft = {
        id: randomUUID(),
        serviceRequestId: sr.serviceRequestId,
        ticketNo: ticketNo!,
        quantityBbl,
        disposalTicketNo: `D-${randomUUID().slice(0, 8)}`,
        truck,
        driver,
        captureMethod: 'digital',
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };
      // Stable idempotency identity, reused by the replay below.
      const ftSeq = seq++;
      const ftUuid = randomUUID();
      const ticketInput = {
        serviceRequestId: draft.serviceRequestId,
        snapshotHash: snapshotHash!,
        ticketNo: draft.ticketNo,
        quantityBbl: draft.quantityBbl,
        disposalTicketNo: draft.disposalTicketNo,
        deviceInstanceId: DEVICE,
        localSeq: ftSeq,
        opUuid: ftUuid,
      };
      const ticketResult = await submitFieldTicket(
        { submitter: v1, evidenceStore: new VolatileTicketEvidenceStore(), now: () => new Date() },
        ticketInput,
      );
      if (ticketResult.status !== 'accepted') {
        // eslint-disable-next-line no-console
        console.error(`[${driver}] field ticket not accepted`, ticketResult);
      }
      expect(ticketResult.status).toBe('accepted');

      // ----- 7. idempotent replay: SAME key, fresh store → Hub dedupes (duplicate, no 2nd ticket)
      const replay = await submitFieldTicket(
        { submitter: v1, evidenceStore: new VolatileTicketEvidenceStore(), now: () => new Date() },
        ticketInput, // identical localSeq + opUuid → identical idempotency key
      );
      expect(replay.status).toBe('accepted');
      expect((replay as { duplicate?: boolean }).duplicate).toBe(true);

      // ----- 8. evidence blobs → two-phase upload + attachment.link → linked -----
      // Link to the SR (the stable Hub entity) per the signature-capture wiring contract.
      const evidence = [
        { ...makeBlob('image/jpeg', 'ft-photo'), kind: 'field-ticket-photo' as const },
        { ...makeBlob('image/jpeg', 'disposal'), kind: 'disposal-photo' as const },
        { ...makeBlob('application/octet-stream', 'signature'), kind: 'signature' as const },
      ];
      for (const e of evidence) {
        bytesSource.put(e.localUri, e.bytes);
        uploadEngine.register({
          blobId: e.blobId,
          sha256: e.sha256,
          byteLength: e.byteLength,
          mimeType: e.mimeType,
          localUri: e.localUri,
          attachmentId: randomUUID(),
          parentType: 'sr',
          parentId: sr.serviceRequestId,
          attachmentKind: e.kind,
        });
      }
      for (let i = 0; i < 15; i++) {
        const up = await uploadEngine.processOnce();
        const push = await syncEngine.pushOnce();
        if (
          up.uploaded === 0 &&
          up.linked === 0 &&
          up.linksEnqueued === 0 &&
          push.submitted === 0
        ) {
          break;
        }
      }
      for (const e of evidence) {
        const rec = blobs.get(e.blobId);
        if (rec?.state !== 'linked') {
          // eslint-disable-next-line no-console
          console.error(`[${driver}] blob not linked`, e.kind, rec);
        }
        expect(rec?.state).toBe('linked');
        expect(sync.isBlobPurgeable(rec!)).toBe(true);
      }

      // ----- 9. post-trip DVIR -----
      const postSig = `sig-post-${randomUUID()}`;
      const postTrip: fieldwork.DvirForm = {
        formId: `dvir-post-${randomUUID()}`,
        kind: 'post-trip-dvir',
        vehicleRef: truck,
        odometer: 123512,
        items: [
          { itemId: 'brakes', label: 'Brakes', result: 'ok' },
          { itemId: 'tires', label: 'Tires', result: 'ok' },
        ],
        signatureBlobIds: [postSig],
        signatures: [sign(postSig, fieldwork.DVIR_POSTTRIP_CERTIFICATION_TEXT)],
      };
      submitForm(postTrip);
      await syncEngine.pushOnce();
      expect(workflow.reconcileOutcomes().accepted).toEqual(
        expect.arrayContaining([postTrip.formId]),
      );

      // ----- loop-closure evidence for the Hub-side invoice check (driver can't read invoices) ---
      // eslint-disable-next-line no-console
      console.log(`[live-e2e] ${driver} driver-day landed on Hub`, {
        serviceRequestId: sr.serviceRequestId,
        requestNo: ticketNo,
        ticketNo,
        quantityBbl,
        captureSource: 'mobile',
        blobs: evidence.map((e) => `${e.kind}:${e.blobId}`),
      });
    },
    60_000,
  );
});
