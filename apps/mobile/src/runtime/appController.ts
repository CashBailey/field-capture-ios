/**
 * Composition-root controller: the one object screens talk to. Wires auth (token production),
 * the durable stores, the Hub client, restart recovery, and the retry engine — while keeping
 * every Hub truth question (clock gate, assignment, accept/reject) answered by Hub alone.
 *
 * Ordering invariant (spec req: restart recovery): `start()` sweeps orphaned in-flight evidence
 * BEFORE the retry engine runs and before any submit can execute.
 *
 * Token discipline: every Hub call resolves the session first (`getValidSession` — refreshes
 * when expiring). No valid session → the call resolves to a locked/auth state, never a hang
 * and never a guess.
 */
import {
  evaluateClockGate,
  getValidSession,
  HubAuthError,
  HubNetworkError,
  login as loginUseCase,
  logout as logoutUseCase,
  perSrSyncState,
  refreshFieldSession,
  evaluateOfflinePolicy,
  submitFieldTicket,
  summarizeSyncCenter,
  type AssignmentSource,
  type AssignmentStore,
  type AuthApi,
  type FieldSessionResult,
  type FieldTicketDetail,
  type FieldTicketSubmitter,
  type FieldWorkGate,
  type LoginResult,
  type OfflinePolicy,
  type OfflinePolicyStore,
  type SessionState,
  type SessionStatusSource,
  type SrSyncState,
  type SubmitFieldTicketResult,
  type SyncCenterSummary,
  type TicketEvidenceStore,
  type TokenStore,
  type UserProfile,
} from '../domain';
import { recoverEvidenceOnStartup, type EvidenceRecovery } from './restartRecovery';
import { RetryEngine, inputFromEvidence } from './retryEngine';
import { SyncRunner } from './syncRunner';
import { UploadRunner } from './uploadRunner';
import type { SyncEngine } from './syncEngine';
import type { UploadEngine } from './uploadEngine';

export interface TicketDraft {
  serviceRequestId: string;
  ticketNo: string;
  quantityBbl: number;
  disposalTicketNo: string;
  /** Full paper-ticket detail (gauges, times, rig #, line items); rides along additively. */
  detail?: FieldTicketDetail;
}

export type ControllerSubmitResult =
  | SubmitFieldTicketResult
  | { status: 'not-signed-in' }
  /** No cached assignment (and therefore no snapshot_hash) for this SR — submit refused. */
  | { status: 'assignment-missing'; serviceRequestId: string }
  /** resubmitEvidence was asked for a key that has no stored evidence. */
  | { status: 'evidence-missing'; idempotencyKey: string };

export type HubClient = SessionStatusSource & AssignmentSource & FieldTicketSubmitter;

export interface AppControllerDeps {
  evidenceStore: TicketEvidenceStore;
  assignmentStore: AssignmentStore;
  tokenStore: TokenStore;
  authApi: AuthApi;
  /** The ADR-004 V2 sync engine to drive in the background. Optional: when absent, no sync runner
   *  is created and the controller behaves exactly as before. */
  syncEngine?: SyncEngine;
  /** The ADR-004 blob-upload engine to drive in the background. Optional: when absent, no upload
   *  runner is created (uploads then run only via an explicit processOnce caller). */
  uploadEngine?: UploadEngine;
  /** Durable 24h offline-policy baseline; optional for tests/legacy composition roots. */
  offlinePolicyStore?: OfflinePolicyStore;
  /** Build a Hub client bound to a live session token (tokens rotate; clients are cheap). */
  hubClientFor(sessionToken: string): HubClient;
  identity: {
    ensureDeviceInstanceId(generateUuid: () => string): string;
    allocateLocalSeq(): number;
  };
  generateUuid: () => string;
  now?: () => Date;
  random?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Surfaced when background retries need a re-login (engine is paused meanwhile). */
  onAuthRequired?: () => void;
  /** Telemetry hook for contained sweep errors (the retry loop continues regardless). */
  onSweepError?: (idempotencyKey: string, error: unknown) => void;
  /** Telemetry for contained V2 SyncRunner errors (scope, error); the sync loop continues regardless. */
  onSyncError?: (scope: string, error: unknown) => void;
  /** Override the V2 sync driver polling cadence (ms). Defaults to the SyncRunner default (60s). */
  syncIntervalMs?: number;
}

export class AppController {
  readonly retryEngine: RetryEngine;
  private readonly syncRunner?: SyncRunner;
  private readonly uploadRunner?: UploadRunner;
  private started = false;

  constructor(private readonly deps: AppControllerDeps) {
    // The engine's submitter resolves the CURRENT session per dispatch — a token refreshed
    // mid-queue is picked up automatically; a dead session pauses the engine via auth-failed.
    const submitter: FieldTicketSubmitter = {
      submitFieldTicket: async (submission) => {
        const session = await this.getSession();
        if (session.status === 'auth-required') {
          return { outcome: 'auth-failed', httpStatus: 401 };
        }
        if (session.status === 'unavailable') {
          return { outcome: 'transient', reason: 'network', detail: session.reason };
        }
        return deps.hubClientFor(session.session.sessionToken).submitFieldTicket(submission);
      },
    };
    this.retryEngine = new RetryEngine({
      evidenceStore: deps.evidenceStore,
      submitter,
      ...(deps.now !== undefined ? { now: deps.now } : {}),
      ...(deps.random !== undefined ? { random: deps.random } : {}),
      ...(deps.setTimer !== undefined ? { setTimer: deps.setTimer } : {}),
      ...(deps.clearTimer !== undefined ? { clearTimer: deps.clearTimer } : {}),
      ...(deps.onAuthRequired !== undefined ? { onAuthRequired: deps.onAuthRequired } : {}),
      ...(deps.onSweepError !== undefined ? { onSweepError: deps.onSweepError } : {}),
    });
    // The V2 sync driver mirrors the RetryEngine lifecycle: same injected timers, same
    // pause-on-auth / resume-on-refresh hooks (wired in start/stop/getSession/login below).
    if (deps.syncEngine !== undefined) {
      this.syncRunner = new SyncRunner({
        syncEngine: deps.syncEngine,
        ...(deps.syncIntervalMs !== undefined ? { intervalMs: deps.syncIntervalMs } : {}),
        ...(deps.setTimer !== undefined ? { setTimer: deps.setTimer } : {}),
        ...(deps.clearTimer !== undefined ? { clearTimer: deps.clearTimer } : {}),
        ...(deps.onAuthRequired !== undefined ? { onAuthRequired: deps.onAuthRequired } : {}),
        ...(deps.onSyncError !== undefined ? { onSyncError: deps.onSyncError } : {}),
      });
    }
    // The blob-upload driver: same lifecycle + auth pause/resume as the sync driver.
    if (deps.uploadEngine !== undefined) {
      this.uploadRunner = new UploadRunner({
        uploadEngine: deps.uploadEngine,
        ...(deps.syncIntervalMs !== undefined ? { intervalMs: deps.syncIntervalMs } : {}),
        ...(deps.setTimer !== undefined ? { setTimer: deps.setTimer } : {}),
        ...(deps.clearTimer !== undefined ? { clearTimer: deps.clearTimer } : {}),
        ...(deps.onAuthRequired !== undefined ? { onAuthRequired: deps.onAuthRequired } : {}),
        ...(deps.onSyncError !== undefined ? { onSyncError: deps.onSyncError } : {}),
      });
    }
  }

  private authDeps() {
    return {
      api: this.deps.authApi,
      tokenStore: this.deps.tokenStore,
      ...(this.deps.now !== undefined ? { now: this.deps.now } : {}),
    };
  }

  private recordHubContact(at: Date = this.deps.now?.() ?? new Date()): void {
    this.deps.offlinePolicyStore?.recordHubContact(at.getTime());
  }

  private sessionCheck: Promise<SessionState> | undefined;

  /**
   * Single-flight session resolution: concurrent Hub calls share ONE getValidSession (and
   * therefore at most one refresh — no refresh storms, no stale-rejection-clears-fresh-token
   * races). Observing a valid session also resumes a retry engine paused for auth, so queued
   * work recovers after a SILENT token refresh, not only after an interactive login.
   */
  private getSession(): Promise<SessionState> {
    this.sessionCheck ??= getValidSession(this.authDeps()).finally(() => {
      this.sessionCheck = undefined;
    });
    return this.sessionCheck.then((state) => {
      if (state.status === 'valid') {
        // The one place a silent token refresh is observed — resume BOTH engines that may be
        // paused for auth (V1 ticket retries and the V2 sync driver).
        if (this.retryEngine.isPausedForAuth()) this.retryEngine.resumeAfterAuth();
        if (this.syncRunner?.isPausedForAuth()) this.syncRunner.resumeAfterAuth();
        if (this.uploadRunner?.isPausedForAuth()) this.uploadRunner.resumeAfterAuth();
      }
      return state;
    });
  }

  /**
   * Fresh bearer for the ADR-004 V2 sync transport's per-request tokenProvider. Reuses the
   * single-flight `getSession()` so the sync engine shares the SAME refresh as every other Hub
   * call (no refresh storms; a silent refresh resumes a paused engine). It THROWS when no token is
   * available so the SyncEngine treats the batch as a transient failure — work stays queued, never
   * dropped: `auth-required` -> HubAuthError (engine pauses for re-auth); offline/`unavailable` ->
   * HubNetworkError (engine retries with backoff).
   */
  async getSyncSessionToken(): Promise<string> {
    const session = await this.getSession();
    if (session.status === 'valid') return session.session.sessionToken;
    if (session.status === 'auth-required') {
      throw new HubAuthError(`sync session token unavailable: ${session.reason}`, 401);
    }
    throw new HubNetworkError(`sync session token unavailable: ${session.reason}`);
  }

  /** Submitter for a resolved session: live client, or a durable offline fallback. */
  private submitterFor(session: SessionState & { status: 'valid' | 'unavailable' }) {
    if (session.status === 'valid') {
      return this.deps.hubClientFor(session.session.sessionToken);
    }
    // Session refresh unavailable (offline): record the evidence locally as a transient
    // failure so the work is durable NOW and retries when connectivity returns.
    const submitter: FieldTicketSubmitter = {
      submitFieldTicket: async () => ({
        outcome: 'transient',
        reason: 'network',
        detail: session.reason,
      }),
    };
    return submitter;
  }

  /** Boot: restart-recovery sweep FIRST, then the retry engine. Idempotent. */
  start(): EvidenceRecovery {
    if (this.started) return { recoveredKeys: [] };
    this.started = true;
    const recovery = recoverEvidenceOnStartup(
      this.deps.evidenceStore,
      this.deps.now ?? (() => new Date()),
    );
    this.retryEngine.start();
    // Recover orphaned in-flight V2 outbox rows (same idempotency-key replay safety as V1), then
    // start the background sync driver so enqueued field evidence (DVIR/JHA/...) reaches the Hub.
    this.deps.syncEngine?.recoverOnStartup();
    this.syncRunner?.start();
    this.uploadRunner?.start();
    return recovery;
  }

  stop(): void {
    this.retryEngine.stop();
    this.syncRunner?.stop();
    this.uploadRunner?.stop();
  }

  /** Kick the background sync driver to run a sweep now — used both when fresh V2 evidence is
   *  enqueued and when the app returns to the foreground. No-op when there is no runner wired, or
   *  while the runner is paused for auth (a dead token is never hammered). */
  notifyQueuedSync(): void {
    this.syncRunner?.notifyQueued();
  }

  /** Kick the background upload driver to run a sweep now — used when a fresh blob is registered
   *  (kick-on-capture). No-op when there is no runner wired, or while it is paused for auth. */
  notifyQueuedUpload(): void {
    this.uploadRunner?.notifyQueued();
  }

  /**
   * The app returned to the foreground. Re-validate the session FIRST: a silent refresh observed
   * here resumes any runner that paused for auth while backgrounded (e.g. an overnight token
   * expiry) — without this, a kick alone is a no-op while paused and queued evidence would sit
   * until the next manual Hub call. Then kick the sync + upload drivers so a still-valid session
   * drains promptly. Best-effort: a failed refresh leaves the runners paused (correct).
   */
  async onForeground(): Promise<void> {
    const session = await this.getSession();
    if (session.status === 'valid') {
      this.notifyQueuedSync();
      this.notifyQueuedUpload();
    }
  }

  async login(credentials: { username: string; password: string }): Promise<LoginResult> {
    const result = await loginUseCase(this.authDeps(), credentials);
    if (result.status === 'signed-in') {
      this.recordHubContact();
      this.retryEngine.resumeAfterAuth(); // queued work held back by a dead token can go now
      this.syncRunner?.resumeAfterAuth();
      this.uploadRunner?.resumeAfterAuth();
    }
    return result;
  }

  async currentUserProfile(): Promise<UserProfile | null> {
    return (await this.deps.tokenStore.load())?.userProfile ?? null;
  }

  /** Sign out. Unsynced evidence stays in the durable store for the next sign-in. */
  async logout(): Promise<void> {
    await logoutUseCase(this.authDeps());
  }

  /**
   * One refresh cycle: clock gate, then assignments (only when unlocked). Without a valid
   * session this resolves to locked(auth-failed) — a state, not a spinner, not a throw.
   */
  async refreshSession(): Promise<FieldSessionResult> {
    const session = await this.getSession();
    if (session.status === 'auth-required') {
      return {
        gate: { state: 'locked', reason: 'auth-failed', detail: `sign in (${session.reason})` },
        assignments: { status: 'not-pulled', reason: 'locked' },
      };
    }
    if (session.status === 'unavailable') {
      return {
        gate: { state: 'locked', reason: 'hub-unreachable', detail: session.reason },
        assignments: { status: 'not-pulled', reason: 'locked' },
      };
    }
    const client = this.deps.hubClientFor(session.session.sessionToken);
    const result = await refreshFieldSession({
      statusSource: client,
      assignmentSource: client,
      store: this.deps.assignmentStore,
    });
    if (
      result.gate.state === 'unlocked' ||
      (result.gate.state === 'locked' && result.gate.reason === 'not-clocked-in')
    ) {
      this.recordHubContact();
    }
    return result;
  }

  /** The current gate alone (no assignment pull) — for cheap re-checks. */
  async checkGate(): Promise<FieldWorkGate> {
    const session = await this.getSession();
    if (session.status === 'auth-required') {
      return { state: 'locked', reason: 'auth-failed', detail: `sign in (${session.reason})` };
    }
    if (session.status === 'unavailable') {
      return { state: 'locked', reason: 'hub-unreachable', detail: session.reason };
    }
    const gate = await evaluateClockGate(this.deps.hubClientFor(session.session.sessionToken));
    if (
      gate.state === 'unlocked' ||
      (gate.state === 'locked' && gate.reason === 'not-clocked-in')
    ) {
      this.recordHubContact();
    }
    return gate;
  }

  offlinePolicy(now: Date = this.deps.now?.() ?? new Date()): OfflinePolicy | undefined {
    const state = this.deps.offlinePolicyStore?.getState();
    if (state === undefined) return undefined;
    return evaluateOfflinePolicy({
      lastHubContactAtMs: state.lastHubContactAtMs,
      nowMs: now.getTime(),
      ...(state.windowHours !== undefined ? { windowHours: state.windowHours } : {}),
    });
  }

  /**
   * Submit a new field ticket. The snapshot hash is resolved from the cached assignment — a
   * missing assignment (no hash) REFUSES the submit (spec req 7: the hash is the only drift
   * protection). Write identity (device id + local_seq) is allocated durably — but ONLY for a
   * genuinely new draft: if evidence already exists for the same (SR, ticketNo), it is
   * resubmitted with its ORIGINAL idempotency key. A double-tap or user-initiated retry must
   * never mint a second key for the same ticket — Hub would create a duplicate.
   */
  async submitNewTicket(draft: TicketDraft): Promise<ControllerSubmitResult> {
    const existing = this.deps.evidenceStore
      .list()
      .find(
        (e) =>
          e.envelope.payload.serviceRequestId === draft.serviceRequestId &&
          e.envelope.payload.ticketNo === draft.ticketNo,
      );
    if (existing !== undefined) {
      return this.resubmitEvidence(existing.envelope.idempotencyKey);
    }

    const session = await this.getSession();
    if (session.status === 'auth-required') {
      return { status: 'not-signed-in' };
    }
    const snapshotHash = this.deps.assignmentStore.getSnapshotHash(draft.serviceRequestId);
    if (snapshotHash === undefined || snapshotHash.trim() === '') {
      return { status: 'assignment-missing', serviceRequestId: draft.serviceRequestId };
    }
    const deviceInstanceId = this.deps.identity.ensureDeviceInstanceId(this.deps.generateUuid);
    const localSeq = this.deps.identity.allocateLocalSeq();
    const opUuid = this.deps.generateUuid();

    const result = await submitFieldTicket(
      {
        submitter: this.submitterFor(session),
        evidenceStore: this.deps.evidenceStore,
        ...(this.deps.now !== undefined ? { now: this.deps.now } : {}),
      },
      {
        serviceRequestId: draft.serviceRequestId,
        snapshotHash,
        ticketNo: draft.ticketNo,
        quantityBbl: draft.quantityBbl,
        disposalTicketNo: draft.disposalTicketNo,
        ...(draft.detail !== undefined ? { detail: draft.detail } : {}),
        deviceInstanceId,
        localSeq,
        opUuid,
      },
    );
    if (result.status === 'pending-retry') {
      this.retryEngine.notifyQueued();
    }
    return result;
  }

  /**
   * Resubmit existing evidence with its ORIGINAL idempotency key — the manual retry path for
   * blocked (403/409) rows after the user acts, and the dedupe target for repeated submits of
   * the same draft. Frozen rows (needs-review / rejected) are NOT resubmitted: their stored
   * status is returned instead, preserving the manual-review discipline.
   */
  async resubmitEvidence(idempotencyKey: string): Promise<ControllerSubmitResult> {
    const evidence = this.deps.evidenceStore.get(idempotencyKey);
    if (evidence === undefined) {
      return { status: 'evidence-missing', idempotencyKey };
    }
    if (evidence.state === 'needs-review' || evidence.state === 'rejected') {
      return {
        status: 'needs-review',
        rejectionCode: evidence.lastRejectionCode ?? 'frozen',
        httpStatus: evidence.lastHttpStatus ?? 0,
        ...(evidence.lastDetail !== undefined ? { detail: evidence.lastDetail } : {}),
        idempotencyKey,
      };
    }
    const session = await this.getSession();
    if (session.status === 'auth-required') {
      return { status: 'not-signed-in' };
    }
    const result = await submitFieldTicket(
      {
        submitter: this.submitterFor(session),
        evidenceStore: this.deps.evidenceStore,
        ...(this.deps.now !== undefined ? { now: this.deps.now } : {}),
      },
      inputFromEvidence(evidence),
    );
    if (result.status === 'pending-retry') {
      this.retryEngine.notifyQueued();
    }
    return result;
  }

  /**
   * Per-SR rollup of ticket-submit work for the inbox / Today read path (spec 7.5) — DISPLAY-ONLY,
   * derived from the SAME durable evidence store as outboxSummary(). It never triggers a refetch
   * and never mutates anything. SRs with no local ticket work are simply absent from the map (the
   * screen defaults them to 'no-local-work').
   */
  srSyncStateById(): Map<string, SrSyncState> {
    return perSrSyncState(
      this.deps.evidenceStore.list().map((e) => ({
        serviceRequestId: e.envelope.payload.serviceRequestId,
        state: e.state,
      })),
    );
  }

  /**
   * Sync Center rollup (spec 7.15) across local drafts (`draftCount` — ticket + receipt drafts,
   * counted by the caller) and the durable ticket-submit evidence. Honest by construction: only
   * Hub-accepted rows land in 'accepted-by-hub'. Form/blob/print events fold in as those outboxes
   * gain per-SR attribution (§4g).
   */
  syncCenterSummary(draftCount: number): SyncCenterSummary {
    return summarizeSyncCenter({
      draftCount,
      evidence: this.deps.evidenceStore.list().map((e) => ({
        state: e.state,
        ...(e.lastRejectionCode !== undefined ? { lastRejectionCode: e.lastRejectionCode } : {}),
      })),
    });
  }

  /** Outbox counts for the UI — pending/blocked/review/accepted, never a spinner. */
  outboxSummary() {
    const items = this.deps.evidenceStore.list();
    return {
      pending: items.filter((e) => e.state === 'pending' && e.lastRejectionCode === undefined)
        .length,
      blocked: items.filter((e) => e.state === 'pending' && e.lastRejectionCode !== undefined)
        .length,
      needsReview: items.filter((e) => e.state === 'needs-review').length,
      accepted: items.filter((e) => e.state === 'accepted').length,
      inFlight: items.filter((e) => e.state === 'in-flight').length,
    };
  }
}
