/**
 * ADR-004 first slice (Hub<->Mobile push): a completed pre-trip DVIR syncs END TO END through the
 * REAL OpsHubSyncTransport — not the placeholder. Composes the real FieldWorkflowService ->
 * SyncEngine -> real transport against a fake Hub `fetch`, proving:
 *   - submitForm() enqueues exactly one append-only `dvir.submit` EVENT op (no precondition);
 *   - the transport POSTs it to /api/v1/sync/commands in the Hub wire shape;
 *   - an accepted outcome folds back so the form becomes durable (`accepted`);
 *   - a Hub clock-gate rejection (`not_clocked_in`) is recorded as a `rejected` form verbatim,
 *     never a crash — even when the client gate was open.
 * The runtime DRIVER (when wireAppRuntime calls syncOnce) is a separate follow-up slice; this test
 * drives pushOnce() directly, which is the authoritative proof the wired path works.
 */
import { fieldwork } from '@fieldcapture/contracts';

import {
  OpsHubSyncTransport,
  type HubFetch,
  type HubFetchInit,
  type HubHttpResponse,
} from '../src/adapters/sync';
import {
  VolatileFieldFormStore,
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
  type FieldWorkGate,
} from '../src/domain';
import { FieldWorkflowService, SyncEngine } from '../src/runtime';

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
};

function preTripDvir(): fieldwork.DvirForm {
  return {
    formId: 'dvir-1',
    kind: 'pre-trip-dvir',
    vehicleRef: 'truck-7',
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: ['sig-1'],
  };
}

function jhaForm(): fieldwork.JhaForm {
  return {
    formId: 'jha-1',
    kind: 'jha-jsa',
    serviceRequestId: 'sr-9',
    hazards: [{ hazardId: 'h1', description: 'H2S', mitigation: 'monitor' }],
    signatureBlobIds: ['sig-2'],
  };
}

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

/** Real FieldWorkflowService -> SyncEngine -> real OpsHubSyncTransport, sharing one outbox. */
function harness(hubFetch: HubFetch) {
  const outbox = new VolatileSyncOutboxStore();
  const transport = new OpsHubSyncTransport(
    { baseUrl: 'http://hub.test', sessionToken: 'unused-static' },
    hubFetch,
    { tokenProvider: () => 'tok-1' },
  );
  const engine = new SyncEngine({
    outbox,
    frontier: new VolatileSyncFrontierStore(),
    transport,
    applyChanges: () => {},
    now: () => new Date(1_000_000),
    random: () => 0.5,
  });
  let seq = 0;
  let uuid = 0;
  const forms = new VolatileFieldFormStore();
  const service = new FieldWorkflowService({
    forms,
    gateState: () => UNLOCKED,
    enqueueEvidence: (envelope) => engine.enqueue(envelope),
    outboxItem: (opId) => outbox.get(opId),
    requirements: () => ({ clockInRequired: true, requiredSteps: [] }),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { service, forms, engine };
}

describe('dvir.submit pushes end-to-end through the real transport', () => {
  it('a completed pre-trip DVIR reaches /sync/commands and reconciles to accepted', async () => {
    const bodies: { operations: Record<string, unknown>[] }[] = [];
    const { service, forms, engine } = harness(async (url: string, init: HubFetchInit) => {
      if (!url.includes('/sync/commands')) throw new Error(`unexpected url ${url}`);
      const body = JSON.parse(init.body as string) as { operations: Record<string, unknown>[] };
      bodies.push(body);
      return jsonResponse(200, {
        results: body.operations.map((op, i) => ({
          op_id: op.op_id,
          outcome: 'accepted',
          token: { authority_epoch: 1, commit_seq: i + 1 },
        })),
      });
    });

    expect(service.saveDraft(preTripDvir()).status).toBe('ok');
    expect(service.completeForm('dvir-1').status).toBe('ok');
    expect(service.submitForm('dvir-1').status).toBe('ok');
    expect(forms.get('dvir-1')?.status).toBe('enqueued');

    const push = await engine.pushOnce();
    expect(push).toMatchObject({ submitted: 1, accepted: 1 });

    // Wire contract: exactly one append-only dvir.submit event, no precondition, DvirForm payload.
    expect(bodies).toHaveLength(1);
    expect(bodies[0]!.operations).toHaveLength(1);
    const op = bodies[0]!.operations[0]!;
    expect(op.type).toBe('dvir.submit');
    expect(op.kind).toBe('event');
    expect(op.precondition).toBeUndefined();
    expect(op.payload).toMatchObject({
      formId: 'dvir-1',
      kind: 'pre-trip-dvir',
      vehicleRef: 'truck-7',
    });
    expect(typeof op.idempotency_key).toBe('string');

    // Accepted outcome folds back onto the form record: now durable.
    expect(service.reconcileOutcomes().accepted).toEqual(['dvir-1']);
    expect(forms.get('dvir-1')?.status).toBe('accepted');
  });

  it('a Hub clock-gate rejection (not_clocked_in) is recorded as a rejected form, not a crash', async () => {
    const { service, forms, engine } = harness(async (url: string, init: HubFetchInit) => {
      if (!url.includes('/sync/commands')) throw new Error(`unexpected url ${url}`);
      const body = JSON.parse(init.body as string) as { operations: { op_id: string }[] };
      return jsonResponse(200, {
        results: body.operations.map((op) => ({
          op_id: op.op_id,
          outcome: 'rejected',
          rejection_code: 'not_clocked_in',
        })),
      });
    });

    service.saveDraft(preTripDvir());
    service.completeForm('dvir-1');
    service.submitForm('dvir-1');

    const push = await engine.pushOnce();
    expect(push).toMatchObject({ submitted: 1 });

    // Server-side rejection is data, not an exception — the form freezes with Hub's verbatim code.
    expect(service.reconcileOutcomes().rejected).toEqual(['dvir-1']);
    expect(forms.get('dvir-1')).toMatchObject({ status: 'rejected', lastError: 'not_clocked_in' });
  });

  it('a JHA rides the identical path and reaches /sync/commands as jhajsa.submit', async () => {
    const bodies: { operations: Record<string, unknown>[] }[] = [];
    const { service, forms, engine } = harness(async (url: string, init: HubFetchInit) => {
      if (!url.includes('/sync/commands')) throw new Error(`unexpected url ${url}`);
      const body = JSON.parse(init.body as string) as { operations: Record<string, unknown>[] };
      bodies.push(body);
      return jsonResponse(200, {
        results: body.operations.map((op, i) => ({
          op_id: op.op_id,
          outcome: 'accepted',
          token: { authority_epoch: 1, commit_seq: i + 1 },
        })),
      });
    });

    expect(service.saveDraft(jhaForm()).status).toBe('ok');
    expect(service.completeForm('jha-1').status).toBe('ok');
    expect(service.submitForm('jha-1').status).toBe('ok');
    await engine.pushOnce();

    expect(bodies[0]!.operations[0]!.type).toBe('jhajsa.submit');
    expect(bodies[0]!.operations[0]!.kind).toBe('event');
    expect(service.reconcileOutcomes().accepted).toEqual(['jha-1']);
    expect(forms.get('jha-1')?.status).toBe('accepted');
  });

  it('a needs-review outcome freezes the form with the Hub reason — not accepted', async () => {
    const { service, forms, engine } = harness(async (url: string, init: HubFetchInit) => {
      if (!url.includes('/sync/commands')) throw new Error(`unexpected url ${url}`);
      const body = JSON.parse(init.body as string) as { operations: { op_id: string }[] };
      return jsonResponse(200, {
        results: body.operations.map((op) => ({
          op_id: op.op_id,
          outcome: 'needs-review',
          review_reason: 'assignment_changed',
        })),
      });
    });

    service.saveDraft(preTripDvir());
    service.completeForm('dvir-1');
    service.submitForm('dvir-1');
    await engine.pushOnce();

    const reconciled = service.reconcileOutcomes();
    expect(reconciled.needsReview).toEqual(['dvir-1']);
    expect(reconciled.accepted).toEqual([]);
    expect(forms.get('dvir-1')).toMatchObject({
      status: 'needs-review',
      lastError: 'assignment_changed',
    });
  });
});
