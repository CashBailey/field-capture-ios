/**
 * Background retry engine (spec req: retry loop + exponential backoff).
 *
 * What it auto-retries — ONLY transient failures (network / 5xx / 429), i.e. pending evidence
 * with no rejection code, once its full-jitter backoff window has elapsed.
 *
 * What it must NEVER auto-retry:
 *  - 403/409 "blocked" rows: pending but carrying `lastRejectionCode` — user-action-gated
 *    (clock in / wait out the in-progress original). A manual resubmission clears the code on
 *    its next outcome.
 *  - 412/422 "needs-review" and `rejected` rows: terminal, frozen for manual review (the
 *    contracts state machine throws on any transition out of them).
 *  - `auth-failed` rows: the engine PAUSES instead — hammering Hub with a dead token converts
 *    one failure into N. `resumeAfterAuth()` restarts it once a fresh token exists.
 *
 * All time and randomness are injected so the schedule is deterministic under test.
 */
import { sync } from '@fieldcapture/contracts';

import {
  submitFieldTicket,
  type FieldTicketInput,
  type FieldTicketSubmitter,
  type SubmitFieldTicketResult,
  type TicketEvidence,
  type TicketEvidenceStore,
} from '../domain';

export interface SweepReport {
  attempted: number;
  accepted: number;
  /** Still pending on a transient failure — rescheduled with backoff. */
  rescheduled: number;
  /** Pending but user-action-gated (blocked rejection) or not yet due — left alone. */
  skipped: number;
  /** True when the sweep hit an auth failure and the engine paused. */
  pausedForAuth: boolean;
}

export interface RetryEngineDeps {
  evidenceStore: TicketEvidenceStore;
  submitter: FieldTicketSubmitter;
  policy?: sync.RetryPolicy;
  now?: () => Date;
  random?: () => number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Fired when a retry hit a 401 — the auth slice should refresh/re-login, then resume. */
  onAuthRequired?: () => void;
  /** Fired when a sweep or one row's dispatch threw (telemetry); the loop continues either way. */
  onSweepError?: (idempotencyKey: string, error: unknown) => void;
}

/** Reconstruct the original submit input from the durable envelope (identity included). */
export function inputFromEvidence(evidence: TicketEvidence): FieldTicketInput {
  const identity = sync.parseIdempotencyKey(evidence.envelope.idempotencyKey);
  const payload = evidence.envelope.payload;
  return {
    serviceRequestId: payload.serviceRequestId,
    snapshotHash: payload.snapshotHash,
    ticketNo: payload.ticketNo,
    quantityBbl: payload.quantityBbl,
    disposalTicketNo: payload.disposalTicketNo,
    ...(payload.detail !== undefined ? { detail: payload.detail } : {}),
    deviceInstanceId: identity.deviceInstanceId,
    localSeq: identity.localSeq,
    opUuid: identity.opUuid,
  };
}

/** Pending, not user-action-gated, not waiting on re-auth. (Due-ness is checked separately.) */
export function isAutoRetryable(evidence: TicketEvidence): boolean {
  return (
    evidence.state === 'pending' &&
    evidence.lastRejectionCode === undefined &&
    evidence.lastTransientReason !== 'auth-failed'
  );
}

export class RetryEngine {
  private readonly policy: sync.RetryPolicy;
  private readonly now: () => Date;
  private readonly random: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;

  private running = false;
  private pausedForAuth = false;
  private sweeping = false;
  private resweepRequested = false;
  private timer: unknown;

  constructor(private readonly deps: RetryEngineDeps) {
    this.policy = deps.policy ?? sync.DEFAULT_RETRY_POLICY;
    this.now = deps.now ?? (() => new Date());
    this.random = deps.random ?? Math.random;
    this.setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.pausedForAuth = false;
    // Rows gated 'auth-failed' in a previous run must not starve forever: the token situation
    // may have changed across the restart, so they get one fresh chance now. A still-dead
    // token re-pauses the engine on the first dispatch.
    this.clearAuthGates();
    void this.runSweep();
  }

  stop(): void {
    this.running = false;
    this.cancelTimer();
  }

  /** True while the engine is holding off because a dispatch hit a 401. */
  isPausedForAuth(): boolean {
    return this.pausedForAuth;
  }

  /**
   * Call whenever a valid session is (re)established — interactive login OR a silent refresh
   * observed elsewhere. Idempotent and cheap when there is nothing to resume.
   */
  resumeAfterAuth(): void {
    if (!this.running) return;
    const hadGates = this.clearAuthGates();
    if (!this.pausedForAuth && !hadGates) return;
    this.pausedForAuth = false;
    void this.runSweep();
  }

  /** Un-gate pending rows whose last failure was auth. Returns whether any row was un-gated. */
  private clearAuthGates(): boolean {
    let cleared = false;
    for (const evidence of this.deps.evidenceStore.list()) {
      if (evidence.state === 'pending' && evidence.lastTransientReason === 'auth-failed') {
        const rest = { ...evidence };
        delete rest.lastTransientReason;
        this.deps.evidenceStore.save({ ...rest, updatedAt: this.now().toISOString() });
        cleared = true;
      }
    }
    return cleared;
  }

  /**
   * One pass: submit every due auto-retryable row, reschedule transients with backoff, pause on
   * auth failure. Public for tests and for a user-facing "sync now" action.
   */
  async sweepOnce(): Promise<SweepReport> {
    const report: SweepReport = {
      attempted: 0,
      accepted: 0,
      rescheduled: 0,
      skipped: 0,
      pausedForAuth: false,
    };
    const nowMs = this.now().getTime();
    for (const evidence of this.deps.evidenceStore.list()) {
      if (evidence.state !== 'pending') continue;
      if (!isAutoRetryable(evidence)) {
        report.skipped += 1;
        continue;
      }
      if (evidence.nextAttemptAtMs !== undefined && evidence.nextAttemptAtMs > nowMs) {
        report.skipped += 1;
        continue;
      }
      report.attempted += 1;
      let result: SubmitFieldTicketResult;
      try {
        result = await this.dispatch(evidence);
      } catch (error) {
        // submitFieldTicket contains submitter throws itself; this guards the residue (a store
        // write failing, a frozen row mutated mid-sweep). One bad row must never kill the
        // sweep for the healthy rows behind it.
        report.skipped += 1;
        this.deps.onSweepError?.(evidence.envelope.idempotencyKey, error);
        continue;
      }
      if (result.status === 'accepted') {
        report.accepted += 1;
      } else if (result.status === 'pending-retry') {
        report.rescheduled += 1;
      } else if (result.status === 'auth-required') {
        this.pausedForAuth = true;
        report.pausedForAuth = true;
        this.deps.onAuthRequired?.();
        break; // a dead token fails every row identically — stop the pass
      }
      // blocked / needs-review: submitFieldTicket already recorded the outcome; nothing to do.
    }
    return report;
  }

  private async dispatch(evidence: TicketEvidence): Promise<SubmitFieldTicketResult> {
    const result = await submitFieldTicket(
      { submitter: this.deps.submitter, evidenceStore: this.deps.evidenceStore, now: this.now },
      inputFromEvidence(evidence),
    );
    if (result.status === 'pending-retry') {
      // Stamp the next attempt time with full-jitter exponential backoff. Re-read the row:
      // submitFieldTicket just rewrote it (attempts, failure detail).
      const fresh = this.deps.evidenceStore.get(evidence.envelope.idempotencyKey);
      if (fresh !== undefined && fresh.state === 'pending') {
        const retryCount = Math.max(0, fresh.attempts - 1);
        this.deps.evidenceStore.save({
          ...fresh,
          nextAttemptAtMs: sync.computeNextAttemptAtMs(
            this.now().getTime(),
            retryCount,
            this.random,
            this.policy,
          ),
        });
      }
    }
    return result;
  }

  private async runSweep(): Promise<void> {
    if (!this.running || this.pausedForAuth) return;
    if (this.sweeping) {
      // A sweep is in progress; run another full pass when it finishes (e.g. resumeAfterAuth
      // landed mid-sweep) instead of silently dropping the request.
      this.resweepRequested = true;
      return;
    }
    this.sweeping = true;
    try {
      await this.sweepOnce();
    } catch (error) {
      // A sweep must never kill the loop: scheduleNext below re-arms the timer regardless,
      // so the queue keeps draining on the next tick instead of silently freezing.
      this.deps.onSweepError?.('(sweep)', error);
    } finally {
      this.sweeping = false;
    }
    if (this.resweepRequested) {
      this.resweepRequested = false;
      return this.runSweep();
    }
    this.scheduleNext();
  }

  private scheduleNext(): void {
    this.cancelTimer();
    if (!this.running || this.pausedForAuth) return;
    const nowMs = this.now().getTime();
    let nextDueMs: number | undefined;
    for (const evidence of this.deps.evidenceStore.list()) {
      if (!isAutoRetryable(evidence)) continue;
      const due = evidence.nextAttemptAtMs ?? nowMs;
      if (nextDueMs === undefined || due < nextDueMs) nextDueMs = due;
    }
    if (nextDueMs === undefined) return; // queue drained — start() or an enqueue re-arms
    const delay = Math.max(1_000, nextDueMs - nowMs); // floor: never busy-spin
    this.timer = this.setTimer(() => void this.runSweep(), delay);
  }

  /** Re-arm after new work enters the queue (e.g. a fresh submit failed while offline). */
  notifyQueued(): void {
    if (!this.running || this.pausedForAuth || this.sweeping) return;
    this.scheduleNext();
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) {
      this.clearTimer(this.timer);
      this.timer = undefined;
    }
  }
}
