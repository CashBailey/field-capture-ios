/**
 * Composition-root controller: token production feeds every Hub call, snapshot hashes come from
 * the cached assignment (missing → submit REFUSED), restart recovery precedes the engine, and
 * every path resolves to a state — signed out, offline, or Hub-down included.
 */
import { sync } from '@fieldcapture/contracts';

import {
  HubAuthError,
  HubNetworkError,
  VolatileAssignmentStore,
  VolatileOfflinePolicyStore,
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
  VolatileTicketEvidenceStore,
  type AuthApi,
  type AuthApiResult,
  type AuthSession,
  type HubAssignment,
  type HubSessionStatus,
  type HubSubmitOutcome,
  type HubFieldTicketSubmission,
  type StoreDurability,
  type TokenStore,
} from '../src/domain';
import { AppController, SyncEngine, type HubClient, type UploadEngine } from '../src/runtime';

class FakeTokenStore implements TokenStore {
  readonly durability: StoreDurability = 'volatile-memory';
  session: AuthSession | null = null;
  async load() {
    return this.session;
  }
  async save(session: AuthSession) {
    this.session = session;
  }
  async clear() {
    this.session = null;
  }
}

const CLOCKED_IN: HubSessionStatus = {
  clockedIn: true,
  clockedInSince: '2026-06-10T08:00:00Z',
  source: 'timeclock',
  employeeId: 'emp-1',
  assignmentsAvailable: true,
};

const ASSIGNMENT: HubAssignment = { serviceRequestId: 'sr-1', snapshotHash: 'h1', snapshot: {} };

function fakeClient(submitOutcome: HubSubmitOutcome): HubClient & {
  submits: HubFieldTicketSubmission[];
  tokens: string[];
} {
  const submits: HubFieldTicketSubmission[] = [];
  return {
    submits,
    tokens: [],
    getSessionStatus: async () => CLOCKED_IN,
    getAssignments: async () => [ASSIGNMENT],
    submitFieldTicket: async (s) => {
      submits.push(s);
      return submitOutcome;
    },
  };
}

function makeController(opts: {
  signedIn?: boolean;
  submitOutcome?: HubSubmitOutcome;
  authApi?: Partial<AuthApi>;
  syncEngine?: SyncEngine;
  uploadEngine?: UploadEngine;
  offlinePolicyStore?: VolatileOfflinePolicyStore;
}) {
  const evidenceStore = new VolatileTicketEvidenceStore();
  const assignmentStore = new VolatileAssignmentStore();
  const tokenStore = new FakeTokenStore();
  if (opts.signedIn !== false) tokenStore.session = { sessionToken: 'tok-live' };
  const client = fakeClient(opts.submitOutcome ?? { outcome: 'accepted', duplicate: false });
  const usedTokens: string[] = [];
  let seq = 0;
  const controller = new AppController({
    evidenceStore,
    assignmentStore,
    tokenStore,
    authApi: {
      login: async (): Promise<AuthApiResult> => ({
        outcome: 'authenticated',
        session: { sessionToken: 'tok-new' },
      }),
      refresh: async (): Promise<AuthApiResult> => ({ outcome: 'transient', reason: 'network' }),
      logout: async () => undefined,
      ...opts.authApi,
    },
    hubClientFor: (token) => {
      usedTokens.push(token);
      return client;
    },
    ...(opts.syncEngine !== undefined ? { syncEngine: opts.syncEngine } : {}),
    ...(opts.uploadEngine !== undefined ? { uploadEngine: opts.uploadEngine } : {}),
    ...(opts.offlinePolicyStore !== undefined
      ? { offlinePolicyStore: opts.offlinePolicyStore }
      : {}),
    identity: {
      ensureDeviceInstanceId: () => 'dev-fixed',
      allocateLocalSeq: () => seq++,
    },
    generateUuid: () => `uuid-${seq}`,
    now: () => new Date('2026-06-10T20:00:00.000Z'),
    setTimer: () => 0,
    clearTimer: () => undefined,
  });
  return { controller, evidenceStore, assignmentStore, tokenStore, client, usedTokens };
}

/** Minimal V2 sync transport: records pushed batches, accepts everything, empty pulls. */
class FakeSyncTransport implements sync.SyncTransport {
  batches: sync.OperationEnvelope[][] = [];
  async submitBatch(batch: readonly sync.OperationEnvelope[]): Promise<sync.CommandResult[]> {
    this.batches.push([...batch]);
    return batch.map((e, i) => ({
      outcome: 'accepted',
      opId: e.opId,
      token: { authorityEpoch: 1, commitSeq: i + 1 },
    }));
  }
  async pullChanges(since: sync.ChangeToken): Promise<sync.ChangePage> {
    return { token: since, changes: [] };
  }
  async openUploadSession(): Promise<sync.UploadSessionResponse> {
    throw new Error('not under test');
  }
}

function syncEnvelope(opId: string, localSeq: number): sync.OperationEnvelope {
  return {
    opId,
    kind: 'event',
    type: 'dvir.submit',
    idempotencyKey: `gtr:dev:${localSeq}:${opId}`,
    localSeq,
    dependsOn: [],
    payload: { opId },
  };
}

/** Wire a real SyncEngine to a real AppController exactly as wireAppRuntime does (onEnqueue ->
 *  controller.notifyQueuedSync), so the kick path is exercised end-to-end. Fake timers (from
 *  makeController) mean the runner only acts on start()/notifyQueued, never a real interval. */
function makeSyncController() {
  const outbox = new VolatileSyncOutboxStore();
  const transport = new FakeSyncTransport();
  let controller: AppController | undefined;
  const engine = new SyncEngine({
    outbox,
    frontier: new VolatileSyncFrontierStore(),
    transport,
    applyChanges: () => undefined,
    now: () => new Date('2026-06-10T20:00:00.000Z'),
    random: () => 0.5,
    onEnqueue: () => controller?.notifyQueuedSync(),
  });
  controller = makeController({ syncEngine: engine }).controller;
  return { controller, engine, outbox, transport };
}

const flushSync = async () => {
  for (let i = 0; i < 4; i += 1) await new Promise((r) => setImmediate(r));
};

describe('SyncRunner integration (driven through AppController)', () => {
  it('start() recovers orphaned in-flight V2 rows AND the runner pushes pending work', async () => {
    const { controller, engine, outbox, transport } = makeSyncController();
    engine.enqueue(syncEnvelope('op-pending', 1));
    // An orphaned in-flight row (the app died before Hub answered last run).
    const orphan = engine.enqueue(syncEnvelope('op-orphan', 2));
    outbox.save({ ...orphan, state: 'in-flight' });

    controller.start();
    await flushSync();

    // The orphan can only be pushed if recoverOnStartup flipped it back to pending first, and a
    // push can only happen if the runner started — so this proves both wiring points at once.
    expect(
      transport.batches
        .flat()
        .map((e) => e.opId)
        .sort(),
    ).toEqual(['op-orphan', 'op-pending']);
    controller.stop();
  });

  it('kicks an immediate push when fresh evidence is enqueued (onEnqueue -> notifyQueuedSync -> runner)', async () => {
    const { controller, engine, transport } = makeSyncController();
    controller.start();
    await flushSync();
    transport.batches.length = 0; // ignore the empty initial sweep

    // No direct runner call: rely entirely on the SyncEngine.onEnqueue -> controller wiring.
    engine.enqueue(syncEnvelope('op-1', 1));
    await flushSync();

    expect(transport.batches.flat().map((e) => e.opId)).toEqual(['op-1']);
    controller.stop();
  });
});

class FakeUploadEngineForController {
  processOnceCalls = 0;
  authRequired = false;
  async processOnce() {
    this.processOnceCalls += 1;
    return {
      uploaded: 0,
      dedupedAlreadyPresent: 0,
      linksEnqueued: 0,
      linked: 0,
      expired: 0,
      deferred: 0,
      authRequired: this.authRequired,
    };
  }
  async purgeOnce(): Promise<string[]> {
    return [];
  }
}

describe('UploadRunner integration (driven through AppController)', () => {
  it('start() starts the upload runner; notifyQueuedUpload kicks a sweep', async () => {
    const engine = new FakeUploadEngineForController();
    const { controller } = makeController({ uploadEngine: engine as unknown as UploadEngine });
    controller.start();
    await flushSync();
    expect(engine.processOnceCalls).toBe(1); // runner started + drove a sweep
    controller.notifyQueuedUpload();
    await flushSync();
    expect(engine.processOnceCalls).toBe(2); // the kick drove another
    controller.stop();
  });

  it('onForeground re-validates the session and RESUMES a runner that paused for auth', async () => {
    const engine = new FakeUploadEngineForController();
    engine.authRequired = true; // the first sweep pauses the runner (dead token)
    const { controller } = makeController({ uploadEngine: engine as unknown as UploadEngine });
    controller.start();
    await flushSync();
    expect(engine.processOnceCalls).toBe(1); // ran once, then paused-for-auth

    engine.authRequired = false; // a silent refresh would now succeed
    await controller.onForeground(); // valid session -> getSession resumes the paused runner + kicks
    await flushSync();
    expect(engine.processOnceCalls).toBeGreaterThanOrEqual(2); // resumed and swept again
    controller.stop();
  });

  it('onForeground does NOT resume while still signed out (a dead token is never hammered)', async () => {
    const engine = new FakeUploadEngineForController();
    engine.authRequired = true;
    const { controller } = makeController({
      signedIn: false,
      uploadEngine: engine as unknown as UploadEngine,
    });
    controller.start();
    await flushSync();
    const afterStart = engine.processOnceCalls; // paused-for-auth

    await controller.onForeground(); // session still auth-required -> no resume, no kick
    await flushSync();
    expect(engine.processOnceCalls).toBe(afterStart);
    controller.stop();
  });
});

describe('getSyncSessionToken (ADR-004 sync transport tokenProvider)', () => {
  it('returns the live session token when signed in (shared single-flight session)', async () => {
    const { controller } = makeController({});
    await expect(controller.getSyncSessionToken()).resolves.toBe('tok-live');
  });

  it('throws HubAuthError when signed out so the engine pauses for re-auth (work never dropped)', async () => {
    const { controller } = makeController({ signedIn: false });
    await expect(controller.getSyncSessionToken()).rejects.toBeInstanceOf(HubAuthError);
  });

  it('throws HubNetworkError when the session is unavailable (offline refresh) — engine retries, not re-auth', async () => {
    const { controller, tokenStore } = makeController({});
    // Expiring session (now is 2026-06-10T20:00:00Z, so this is inside the 60s margin) + the
    // default authApi.refresh returning transient/network => getValidSession resolves 'unavailable'.
    // That must surface as HubNetworkError so the SyncEngine reschedules with backoff (offline),
    // distinct from the auth-pause path.
    tokenStore.session = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T19:59:30.000Z',
      refreshToken: 'r',
    };
    await expect(controller.getSyncSessionToken()).rejects.toBeInstanceOf(HubNetworkError);
  });
});

describe('AppController', () => {
  it('start(): sweeps orphaned in-flight evidence BEFORE the retry engine runs', async () => {
    const { controller, evidenceStore } = makeController({});
    evidenceStore.save({
      envelope: {
        opId: 'op-0',
        kind: 'command',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:dev-fixed:0:op-0',
        localSeq: 0,
        dependsOn: [],
        payload: {
          idempotencyKey: 'gtr:dev-fixed:0:op-0',
          serviceRequestId: 'sr-1',
          snapshotHash: 'h1',
          ticketNo: 'T-1',
          quantityBbl: 1,
          disposalTicketNo: 'D-1',
        },
      },
      state: 'in-flight',
      attempts: 1,
      createdAt: '2026-06-10T19:00:00.000Z',
      updatedAt: '2026-06-10T19:00:00.000Z',
    });
    const recovery = controller.start();
    expect(recovery.recoveredKeys).toEqual(['gtr:dev-fixed:0:op-0']);
    // The sweep unblocked the orphan (in-flight would deadlock the double-submit guard), and
    // the engine then retried it with the SAME key — Hub accepted, so it lands durable.
    await new Promise((resolve) => setImmediate(resolve));
    expect(evidenceStore.get('gtr:dev-fixed:0:op-0')?.state).toBe('accepted');
    expect(controller.start()).toEqual({ recoveredKeys: [] }); // idempotent
    controller.stop();
  });

  it('refuses to submit when no cached assignment provides the snapshot hash', async () => {
    const { controller, client, evidenceStore } = makeController({});
    const result = await controller.submitNewTicket({
      serviceRequestId: 'sr-unknown',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    expect(result).toEqual({ status: 'assignment-missing', serviceRequestId: 'sr-unknown' });
    expect(client.submits).toHaveLength(0);
    expect(evidenceStore.list()).toHaveLength(0);
  });

  it('resolves the snapshot hash from the assignment store and echoes it on the wire', async () => {
    const { controller, assignmentStore, client } = makeController({});
    assignmentStore.putAssignments([ASSIGNMENT]);
    const result = await controller.submitNewTicket({
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    expect(result).toMatchObject({ status: 'accepted' });
    expect(client.submits[0]).toMatchObject({ serviceRequestId: 'sr-1', snapshotHash: 'h1' });
    expect(client.submits[0]?.idempotencyKey).toBe('gtr:dev-fixed:0:uuid-1');
  });

  it('signed out → not-signed-in, nothing recorded, nothing sent', async () => {
    const { controller, client, evidenceStore } = makeController({ signedIn: false });
    const result = await controller.submitNewTicket({
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    expect(result).toEqual({ status: 'not-signed-in' });
    expect(client.submits).toHaveLength(0);
    expect(evidenceStore.list()).toHaveLength(0);
  });

  it('session refresh unavailable (offline) → evidence recorded durable-pending, no wire call', async () => {
    const { controller, assignmentStore, client, evidenceStore, tokenStore } = makeController({});
    assignmentStore.putAssignments([ASSIGNMENT]);
    // expiring session + refresh transient (network) → getValidSession 'unavailable'
    tokenStore.session = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T20:00:30.000Z',
      refreshToken: 'r',
    };
    const result = await controller.submitNewTicket({
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    expect(result).toMatchObject({ status: 'pending-retry' });
    expect(client.submits).toHaveLength(0); // never used a token it could not validate
    const saved = evidenceStore.list();
    expect(saved).toHaveLength(1);
    expect(saved[0]).toMatchObject({ state: 'pending', attempts: 1 });
  });

  it('refreshSession resolves to locked(auth-failed) when signed out — a state, not a throw', async () => {
    const { controller } = makeController({ signedIn: false });
    const result = await controller.refreshSession();
    expect(result.gate).toMatchObject({ state: 'locked', reason: 'auth-failed' });
    expect(result.assignments).toEqual({ status: 'not-pulled', reason: 'locked' });
  });

  it('refreshSession pulls gate + assignments with the live token when signed in', async () => {
    const { controller, assignmentStore, usedTokens } = makeController({});
    const result = await controller.refreshSession();
    expect(result.gate.state).toBe('unlocked');
    expect(result.assignments).toEqual({ status: 'synced', count: 1 });
    expect(assignmentStore.getSnapshotHash('sr-1')).toBe('h1');
    expect(usedTokens).toEqual(['tok-live']);
  });

  it('records durable last-Hub-contact on successful session refresh, but not signed-out/offline states', async () => {
    const offlinePolicyStore = new VolatileOfflinePolicyStore();
    const { controller } = makeController({ offlinePolicyStore });

    await controller.refreshSession();
    expect(offlinePolicyStore.getState().lastHubContactAtMs).toBe(
      Date.parse('2026-06-10T20:00:00.000Z'),
    );

    const signedOutStore = new VolatileOfflinePolicyStore();
    const signedOut = makeController({
      signedIn: false,
      offlinePolicyStore: signedOutStore,
    }).controller;
    await signedOut.refreshSession();
    expect(signedOutStore.getState().lastHubContactAtMs).toBeNull();

    const offlineStore = new VolatileOfflinePolicyStore();
    const { controller: offlineController, tokenStore } = makeController({
      offlinePolicyStore: offlineStore,
    });
    tokenStore.session = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T19:59:30.000Z',
      refreshToken: 'r',
    };
    await offlineController.refreshSession();
    expect(offlineStore.getState().lastHubContactAtMs).toBeNull();
  });

  it('login and checkGate record durable Hub contact, and expose the evaluated offline policy', async () => {
    const offlinePolicyStore = new VolatileOfflinePolicyStore();
    const { controller } = makeController({
      signedIn: false,
      offlinePolicyStore,
    });

    await controller.login({ username: 'driver', password: 'pw' });
    expect(offlinePolicyStore.getState().lastHubContactAtMs).toBe(
      Date.parse('2026-06-10T20:00:00.000Z'),
    );
    offlinePolicyStore.recordHubContact(Date.parse('2026-06-10T18:00:00.000Z'));
    await controller.checkGate();
    expect(offlinePolicyStore.getState().lastHubContactAtMs).toBe(
      Date.parse('2026-06-10T20:00:00.000Z'),
    );
    expect(controller.offlinePolicy(new Date('2026-06-10T21:00:00.000Z'))).toMatchObject({
      state: 'offline-within-limit',
    });
  });

  it('login stores the new session; logout clears it but PRESERVES unsynced evidence', async () => {
    const { controller, tokenStore, assignmentStore, evidenceStore } = makeController({
      signedIn: false,
      submitOutcome: { outcome: 'transient', reason: 'network' },
    });
    await expect(controller.login({ username: 'driver', password: 'pw' })).resolves.toEqual({
      status: 'signed-in',
    });
    expect(tokenStore.session).toEqual({ sessionToken: 'tok-new' });

    assignmentStore.putAssignments([ASSIGNMENT]);
    await controller.submitNewTicket({
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    expect(evidenceStore.list()).toHaveLength(1);

    await controller.logout();
    expect(tokenStore.session).toBeNull();
    expect(evidenceStore.list()).toHaveLength(1); // sign-out never destroys field work
  });

  it('double-tap / repeated submit of the same draft NEVER mints a second idempotency key', async () => {
    const { controller, assignmentStore, client, evidenceStore } = makeController({
      submitOutcome: { outcome: 'transient', reason: 'network' },
    });
    assignmentStore.putAssignments([ASSIGNMENT]);
    const draft = {
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    };
    const first = await controller.submitNewTicket(draft); // offline → pending
    expect(first).toMatchObject({ status: 'pending-retry' });
    const second = await controller.submitNewTicket(draft); // user taps again
    expect(second).toMatchObject({ status: 'pending-retry' });
    // ONE evidence row, ONE key, both wire calls (if any) under the same key
    expect(evidenceStore.list()).toHaveLength(1);
    const keys = new Set(client.submits.map((s) => s.idempotencyKey));
    expect(keys.size).toBe(1);
  });

  it('resubmitEvidence retries a blocked row with its ORIGINAL key after the user acts', async () => {
    const { controller, assignmentStore, client, evidenceStore } = makeController({
      submitOutcome: {
        outcome: 'rejected',
        kind: 'blocked',
        httpStatus: 403,
        rejectionCode: 'not_clocked_in',
      },
    });
    assignmentStore.putAssignments([ASSIGNMENT]);
    const draft = {
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    };
    const blocked = await controller.submitNewTicket(draft);
    expect(blocked).toMatchObject({ status: 'blocked', rejectionCode: 'not_clocked_in' });
    const key = (blocked as { idempotencyKey: string }).idempotencyKey;
    // driver clocks in; Hub now accepts
    client.submits.length = 0;
    const acceptingClient = client as unknown as {
      submitFieldTicket: (s: HubFieldTicketSubmission) => Promise<HubSubmitOutcome>;
    };
    acceptingClient.submitFieldTicket = async (s: HubFieldTicketSubmission) => {
      client.submits.push(s);
      return { outcome: 'accepted', duplicate: false };
    };
    const retried = await controller.resubmitEvidence(key);
    expect(retried).toMatchObject({ status: 'accepted', idempotencyKey: key });
    expect(client.submits[0]?.idempotencyKey).toBe(key); // SAME key on the wire
    expect(evidenceStore.list()).toHaveLength(1);
  });

  it('resubmitEvidence never resubmits frozen rows and reports a missing key as a state', async () => {
    const { controller, assignmentStore } = makeController({
      submitOutcome: {
        outcome: 'rejected',
        kind: 'needs-review',
        httpStatus: 412,
        rejectionCode: 'stale_version',
      },
    });
    assignmentStore.putAssignments([ASSIGNMENT]);
    const frozen = await controller.submitNewTicket({
      serviceRequestId: 'sr-1',
      ticketNo: 'T-9',
      quantityBbl: 5,
      disposalTicketNo: 'D-9',
    });
    const key = (frozen as { idempotencyKey: string }).idempotencyKey;
    await expect(controller.resubmitEvidence(key)).resolves.toMatchObject({
      status: 'needs-review',
      rejectionCode: 'stale_version',
    });
    await expect(controller.resubmitEvidence('gtr:nope:0:x')).resolves.toEqual({
      status: 'evidence-missing',
      idempotencyKey: 'gtr:nope:0:x',
    });
  });

  it('observing a valid session resumes a retry engine paused for auth (silent refresh case)', async () => {
    const { controller, assignmentStore, tokenStore, evidenceStore } = makeController({
      signedIn: false,
    });
    assignmentStore.putAssignments([ASSIGNMENT]);
    controller.start();
    // engine pauses: a queued row dispatches against no session → auth-failed
    evidenceStore.save({
      envelope: {
        opId: 'op-q',
        kind: 'command',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:dev-fixed:7:op-q',
        localSeq: 7,
        dependsOn: [],
        payload: {
          idempotencyKey: 'gtr:dev-fixed:7:op-q',
          serviceRequestId: 'sr-1',
          snapshotHash: 'h1',
          ticketNo: 'T-q',
          quantityBbl: 1,
          disposalTicketNo: 'D-q',
        },
      },
      state: 'pending',
      attempts: 0,
      createdAt: '2026-06-10T19:00:00.000Z',
      updatedAt: '2026-06-10T19:00:00.000Z',
    });
    await controller.retryEngine.sweepOnce();
    expect(controller.retryEngine.isPausedForAuth()).toBe(true);
    // a session appears WITHOUT an interactive login (e.g. restored externally)
    tokenStore.session = { sessionToken: 'tok-restored' };
    await controller.refreshSession(); // observes valid → resumes the engine
    await new Promise((resolve) => setImmediate(resolve));
    expect(controller.retryEngine.isPausedForAuth()).toBe(false);
    expect(evidenceStore.get('gtr:dev-fixed:7:op-q')?.state).toBe('accepted');
    controller.stop();
  });

  it('outboxSummary reports finite counts by state, splitting blocked from retryable pending', () => {
    const { controller, evidenceStore } = makeController({});
    const base = (n: number, state: 'pending' | 'needs-review' | 'accepted') => ({
      envelope: {
        opId: `op-${n}`,
        kind: 'command' as const,
        type: 'ticket.submit',
        idempotencyKey: `gtr:dev:${n}:op-${n}`,
        localSeq: n,
        dependsOn: [],
        payload: {
          idempotencyKey: `gtr:dev:${n}:op-${n}`,
          serviceRequestId: 'sr-1',
          snapshotHash: 'h1',
          ticketNo: 'T',
          quantityBbl: 1,
          disposalTicketNo: 'D',
        },
      },
      state,
      attempts: 0,
      createdAt: '2026-06-10T19:00:00.000Z',
      updatedAt: '2026-06-10T19:00:00.000Z',
    });
    evidenceStore.save(base(0, 'pending'));
    evidenceStore.save({ ...base(1, 'pending'), lastRejectionCode: 'not_clocked_in' });
    evidenceStore.save(base(2, 'needs-review'));
    evidenceStore.save(base(3, 'accepted'));
    expect(controller.outboxSummary()).toEqual({
      pending: 1,
      blocked: 1,
      needsReview: 1,
      accepted: 1,
      inFlight: 0,
    });
  });

  // Shared builder for the read-path rollups: one durable evidence row for (SR, state).
  const evidenceRow = (
    n: number,
    serviceRequestId: string,
    state: 'pending' | 'in-flight' | 'needs-review' | 'accepted' | 'rejected',
    rejectionCode?: string,
  ) => ({
    envelope: {
      opId: `op-${n}`,
      kind: 'command' as const,
      type: 'ticket.submit',
      idempotencyKey: `gtr:dev:${n}:op-${n}`,
      localSeq: n,
      dependsOn: [],
      payload: {
        idempotencyKey: `gtr:dev:${n}:op-${n}`,
        serviceRequestId,
        snapshotHash: 'h1',
        ticketNo: `T-${n}`,
        quantityBbl: 1,
        disposalTicketNo: `D-${n}`,
      },
    },
    state,
    attempts: 0,
    createdAt: '2026-06-10T19:00:00.000Z',
    updatedAt: '2026-06-10T19:00:00.000Z',
    ...(rejectionCode !== undefined ? { lastRejectionCode: rejectionCode } : {}),
  });

  it('srSyncStateById rolls ticket evidence up per SR, worst-state-first (display-only read path)', () => {
    const { controller, evidenceStore } = makeController({});
    // sr-A has both accepted AND still-owed pending → worst-first makes it needs-sync.
    evidenceStore.save(evidenceRow(0, 'sr-A', 'accepted'));
    evidenceStore.save(evidenceRow(1, 'sr-A', 'pending'));
    evidenceStore.save(evidenceRow(2, 'sr-B', 'accepted'));
    evidenceStore.save(evidenceRow(3, 'sr-C', 'needs-review'));

    const byId = controller.srSyncStateById();
    expect(byId.get('sr-A')).toBe('needs-sync');
    expect(byId.get('sr-B')).toBe('synced');
    expect(byId.get('sr-C')).toBe('needs-review');
    expect(byId.has('sr-never')).toBe(false); // SRs with no local work are simply absent
  });

  it('syncCenterSummary buckets local drafts + evidence into worker-facing categories', () => {
    const { controller, evidenceStore } = makeController({});
    evidenceStore.save(evidenceRow(0, 'sr-A', 'pending')); // waiting-to-sync
    evidenceStore.save(evidenceRow(1, 'sr-B', 'pending', 'not_clocked_in')); // waiting-on-you
    evidenceStore.save(evidenceRow(2, 'sr-C', 'accepted')); // accepted-by-hub
    evidenceStore.save(evidenceRow(3, 'sr-D', 'needs-review')); // needs-review

    const summary = controller.syncCenterSummary(2); // 2 local drafts not yet submitted
    expect(summary.counts).toMatchObject({
      'saved-on-phone': 2,
      'waiting-to-sync': 1,
      'waiting-on-you': 1,
      'accepted-by-hub': 1,
      'needs-review': 1,
      'rejected-by-hub': 0,
    });
    expect(summary.hasOutstanding).toBe(true);
  });
});
