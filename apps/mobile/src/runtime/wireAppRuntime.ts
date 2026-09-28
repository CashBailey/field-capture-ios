/**
 * Production wiring: the only place the controller meets real device modules (SQLCipher
 * database, keychain, secure random, global fetch). Throws `HubConfigError` when the build has
 * no Hub URL — the app shows that visibly instead of guessing a Hub (config honesty).
 */
import { fieldwork, printer, sync } from '@fieldcapture/contracts';

import {
  OpsHubSyncTransport,
  OpsHubV1Client,
  TusUploadClient,
  createTusFetch,
} from '../adapters/sync';
import { HubAuthApiV1, KeychainTokenStore } from '../adapters/auth';
import { Pt210PrinterTransport } from '../adapters/printer';
import { resolveHubRuntimeConfig } from '../config/hubConfig';
import { hubUrl } from '../config/env';
import {
  FileBlobBytesSource,
  DeviceIdentity,
  SqliteAssignmentStore,
  SqliteBlobUploadStore,
  SqliteFieldFormStore,
  SqliteFieldTicketDraftStore,
  SqliteLocationEvidenceStore,
  SqliteOfflinePolicyStore,
  SqlitePrintJobStore,
  SqliteDiagnosticLogStore,
  SqliteReceiptDraftStore,
  SqliteSyncChangeLedger,
  SqliteSyncFrontierStore,
  SqliteSyncOutboxStore,
  SqliteTicketEvidenceStore,
  createNativeBlobFileDriver,
  getOrCreateDatabaseKey,
  openFieldDatabase,
} from '../data';
import { randomUuid } from '../platform/random';
import {
  HubNetworkError,
  parseWorkflowRequirementsFromAssignments,
  recordChanges,
  type AssignmentStore,
  type FieldWorkGate,
  type StoreDurability,
} from '../domain';
import { AppController } from './appController';
import {
  PrintRuntime,
  VolatilePrintPayloadStore,
  printEventOutcomeFromOutbox,
} from './printRuntime';
import type { EvidenceRecovery } from './restartRecovery';
import { CaptureFlow } from './captureFlow';
import { FieldWorkflowService } from './fieldWorkflowService';
import { LocationEvidenceSyncService } from './locationEvidenceSyncService';
import { SyncEngine } from './syncEngine';
import { UploadEngine } from './uploadEngine';
import { WorkStartService } from './workStartService';

export interface AppRuntime {
  controller: AppController;
  /** What the local store REALLY guarantees (verified at open, surfaced in the UI). */
  durability: Exclude<StoreDurability, 'volatile-memory'>;
  assignmentStore: AssignmentStore;
  /** Durable pre-submit draft storage; submit evidence/outbox rows are separate. */
  draftStore: SqliteFieldTicketDraftStore;
  /** Durable pre-submit receipt drafts (the receipt half of the ticket+receipt package). */
  receiptStore: SqliteReceiptDraftStore;
  /** Durable, non-evictable validation-only location evidence (Phase 7). */
  locationStore: SqliteLocationEvidenceStore;
  /** Durable 24h offline-policy baseline (last successful Hub contact). */
  offlinePolicyStore: SqliteOfflinePolicyStore;
  /** Generic ADR-004 operation outbox (safety-form events, blob links, print events). */
  outbox: SqliteSyncOutboxStore;
  /** ADR-004 V2 sync engine with the REAL transport wired (push DVIR/JHA evidence via
   *  /sync/commands). A caller must drive syncOnce/pushOnce — the runtime trigger is a follow-up. */
  syncEngine: SyncEngine;
  field: FieldRuntimeWorkspace;
  recovery: EvidenceRecovery;
}

export interface FieldRuntimeWorkspace {
  gate: {
    get(): FieldWorkGate;
    set(gate: FieldWorkGate): void;
  };
  workflow: FieldWorkflowService;
  workStart: WorkStartService;
  locationEvidenceSync: LocationEvidenceSyncService;
  forms: SqliteFieldFormStore;
  capture: CaptureFlow;
  /** Stable per-install device id, for signature/audit metadata. */
  deviceInstanceId: string;
  uploadEngine: UploadEngine;
  blobs: SqliteBlobUploadStore;
  printRuntime: PrintRuntime;
  printQueue: printer.PrintJobQueue;
  linkOutcome(opId: string): sync.OutboxItemState | undefined;
}

const INITIAL_GATE: FieldWorkGate = {
  state: 'locked',
  reason: 'hub-unreachable',
  detail: 'session not refreshed yet',
};

function workflowRequirementsFromAssignments(
  assignments: AssignmentStore,
): fieldwork.WorkflowRequirements {
  return parseWorkflowRequirementsFromAssignments(assignments.listAssignments());
}

export async function wireAppRuntime(options?: {
  onAuthRequired?: () => void;
}): Promise<AppRuntime> {
  // Validates the build-time Hub URL (throws HubConfigError when unset). The placeholder token
  // is never sent anywhere — real tokens come from the auth slice per call.
  const baseUrl = resolveHubRuntimeConfig({ hubUrl, sessionToken: 'startup-validation' }).baseUrl;

  const encryptionKey = await getOrCreateDatabaseKey();
  const { db, durability } = openFieldDatabase({ encryptionKey });
  const assignmentStore = new SqliteAssignmentStore(db, durability);
  const draftStore = new SqliteFieldTicketDraftStore(db, durability);
  const receiptStore = new SqliteReceiptDraftStore(db, durability);
  const locationStore = new SqliteLocationEvidenceStore(db, durability);
  const offlinePolicyStore = new SqliteOfflinePolicyStore(db, durability);
  const identity = new DeviceIdentity(db);
  const outbox = new SqliteSyncOutboxStore(db, durability);
  const frontier = new SqliteSyncFrontierStore(db, durability);
  const changeLedger = new SqliteSyncChangeLedger(db, durability);
  // Durable, secret-free anomaly log (Sync Center copy-diagnostic). Sync engine non-fatal events —
  // including an unkeyable down-sync change the Hub should never have sent — land here so they are
  // surfaced for the office rather than silently swallowed.
  const diagnosticLog = new SqliteDiagnosticLogStore(db, durability);
  const recordAnomaly = (
    level: 'warning' | 'error',
    message: string,
    context?: Record<string, unknown>,
  ): void => {
    diagnosticLog.record({
      id: randomUuid(),
      level,
      message,
      ...(context !== undefined ? { context } : {}),
      createdAt: new Date().toISOString(),
    });
  };
  // The real ADR-004 transports share ONE lazy token provider that resolves a fresh bearer through
  // the AppController's single-flight session (the controller is built below; controllerRef is set
  // right after, before anything can drive a push or an upload).
  let controllerRef: AppController | undefined;
  const syncTokenProvider = (): string | Promise<string> => {
    if (controllerRef === undefined) {
      // No push/upload can run before wiring; throw (transient) rather than send a junk token.
      throw new HubNetworkError('sync transport used before controller wiring');
    }
    return controllerRef.getSyncSessionToken();
  };
  // SyncEngine push/pull (/sync/commands, /sync/changes) AND blob upload session-open
  // (/sync/uploads) go through this one transport — both share the controller's session refresh.
  const pushTransport = new OpsHubSyncTransport(
    // sessionToken is a never-used fallback: tokenProvider resolves a fresh bearer per call.
    { baseUrl, sessionToken: 'unused-tokenProvider-overrides' },
    undefined,
    { tokenProvider: syncTokenProvider },
  );
  // Real tus blob-upload client (replaces the throwing stubs): HEAD/PATCH the per-session
  // upload_url with a fresh bearer per request — a multi-chunk upload can outlive a token.
  const tusClient = new TusUploadClient({
    tokenProvider: syncTokenProvider,
    fetchFn: createTusFetch(),
  });
  // The SyncRunner (owned by the AppController below) DRIVES this engine: a periodic timer plus a
  // kick-on-enqueue (the onEnqueue hook -> controller.notifyQueuedSync), so enqueued field evidence
  // (DVIR/JHA/...) actually reaches the Hub. An on-foreground trigger is a deferred follow-up.
  const syncEngine = new SyncEngine({
    outbox,
    frontier,
    transport: pushTransport,
    // Idempotently record every down-synced change BEFORE the frontier advances, so authoritative
    // changes are durably kept (never dropped by a no-op apply). Per-entity application layers on
    // top of this ledger as consumers land (§4g). An unkeyable/malformed change (Hub contract
    // violation) cannot be recorded — surface it instead of letting the frontier silently skip past.
    applyChanges: (changes) => {
      const { skipped } = recordChanges(changeLedger, changes);
      if (skipped > 0) {
        recordAnomaly('error', 'Hub sent unkeyable down-sync change(s); not applied', { skipped });
      }
    },
    // Atomic apply + frontier-advance: the frontier never moves past changes that were not applied.
    transaction: (fn) => db.transaction(fn),
    // Non-fatal sync anomalies (e.g. Hub answered for an op we never sent, or a pull-leg error) are
    // logged to the durable diagnostic store rather than dropped.
    onError: (scope, error) =>
      recordAnomaly('warning', `sync ${scope} anomaly`, { detail: String(error) }),
    // Kick the background driver to push promptly when fresh work is enqueued (controllerRef is set
    // right after the controller is built, before any submit-time enqueue can happen).
    onEnqueue: () => controllerRef?.notifyQueuedSync(),
    onHubContact: (at) => offlinePolicyStore.recordHubContact(at.getTime()),
  });
  const writeIdentity = {
    get deviceInstanceId() {
      return identity.ensureDeviceInstanceId(randomUuid);
    },
    allocateLocalSeq: () => {
      identity.ensureDeviceInstanceId(randomUuid);
      return identity.allocateLocalSeq();
    },
    generateUuid: randomUuid,
  };
  let currentGate: FieldWorkGate = INITIAL_GATE;
  const forms = new SqliteFieldFormStore(db, durability);
  const blobs = new SqliteBlobUploadStore(db, durability);
  const uploadEngine = new UploadEngine({
    blobs,
    bytes: new FileBlobBytesSource(createNativeBlobFileDriver()),
    // Real blob upload: open the session via the same Hub transport as commands, then HEAD/PATCH
    // the bytes through the real tus client. A captured photo/signature reaches the Hub and its
    // attachment.link is enqueued for the SyncRunner to push. Driven by the UploadRunner (owned by
    // the AppController below): a periodic timer plus the onRegister kick-on-capture.
    transport: pushTransport,
    tus: tusClient,
    enqueueLink: (envelope) => {
      syncEngine.enqueue(envelope);
    },
    linkState: (opId) => outbox.get(opId)?.state,
    // Kick the upload driver the moment a blob is captured (controllerRef is set before any capture).
    onRegister: () => controllerRef?.notifyQueuedUpload(),
    identity: writeIdentity,
  });
  const printQueue = new printer.PrintJobQueue(new SqlitePrintJobStore(db));
  const printRuntime = new PrintRuntime({
    queue: printQueue,
    payloads: new VolatilePrintPayloadStore(),
    transport: new Pt210PrinterTransport(),
    enqueueEvent: (envelope) => {
      syncEngine.enqueue(envelope);
    },
    eventOutcome: (printJobId, event) =>
      printEventOutcomeFromOutbox(outbox.list(), printJobId, event),
    identity: writeIdentity,
  });
  const field: FieldRuntimeWorkspace = {
    gate: {
      get: () => currentGate,
      set: (gate) => {
        currentGate = gate;
      },
    },
    workflow: new FieldWorkflowService({
      forms,
      gateState: () => currentGate,
      enqueueEvidence: (envelope) => {
        syncEngine.enqueue(envelope);
      },
      outboxItem: (opId) => outbox.get(opId),
      requirements: () => workflowRequirementsFromAssignments(assignmentStore),
      identity: writeIdentity,
    }),
    workStart: new WorkStartService({
      gateState: () => currentGate,
      enqueueEvent: (envelope) => {
        syncEngine.enqueue(envelope);
      },
      identity: writeIdentity,
    }),
    locationEvidenceSync: new LocationEvidenceSyncService({
      enqueueEvent: (envelope) => {
        syncEngine.enqueue(envelope);
      },
      identity: writeIdentity,
    }),
    forms,
    capture: new CaptureFlow({
      uploads: uploadEngine,
      persistBytes: (blobId, bytes) =>
        new FileBlobBytesSource(createNativeBlobFileDriver()).persist(blobId, bytes),
      gateState: () => currentGate,
      identity: { generateUuid: randomUuid },
    }),
    uploadEngine,
    blobs,
    printRuntime,
    printQueue,
    deviceInstanceId: writeIdentity.deviceInstanceId,
    linkOutcome: (opId) => outbox.get(opId)?.state,
  };

  const controller = new AppController({
    evidenceStore: new SqliteTicketEvidenceStore(db, durability),
    assignmentStore,
    tokenStore: new KeychainTokenStore(),
    // Bind the refresh-token family to this install's stable device id (resolved lazily so the
    // device-identity store needn't be touched until first sign-in).
    authApi: new HubAuthApiV1(baseUrl, undefined, {
      deviceId: () => identity.ensureDeviceInstanceId(randomUuid),
    }),
    hubClientFor: (sessionToken) => new OpsHubV1Client({ baseUrl, sessionToken }),
    // Hand the V2 sync + upload engines to the controller so it owns their runners (start/stop +
    // auth pause/resume).
    syncEngine,
    uploadEngine,
    offlinePolicyStore,
    identity,
    generateUuid: randomUuid,
    ...(options?.onAuthRequired !== undefined ? { onAuthRequired: options.onAuthRequired } : {}),
  });
  // The push transport's lazy tokenProvider resolves through the controller — wire it now, before
  // start() or any caller can drive a sync push.
  controllerRef = controller;

  // Restart recovery MUST precede the retry engine and any submit (start() enforces order).
  const recovery = controller.start();
  return {
    controller,
    durability,
    assignmentStore,
    draftStore,
    receiptStore,
    locationStore,
    offlinePolicyStore,
    outbox,
    syncEngine,
    field,
    recovery,
  };
}
