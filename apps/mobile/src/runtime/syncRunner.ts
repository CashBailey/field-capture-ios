/**
 * Runtime driver for the ADR-004 SyncEngine (spec: the V2 outbox must actually drain).
 *
 * The SyncEngine is inert on its own — it only acts when something calls `syncOnce()`. This runner
 * is that something: a thin adapter over the shared `PollingRunner` that maps one sync pass to the
 * loop's `authRequired` signal. See `PollingRunner` for the lifecycle (periodic drain, kick-on-
 * enqueue via `notifyQueued`, pause-on-401 until `resumeAfterAuth`).
 */
import { PollingRunner } from './pollingRunner';
import type { SyncEngine } from './syncEngine';

export interface SyncRunnerDeps {
  syncEngine: SyncEngine;
  /** Fixed polling cadence (ms) that drains backed-off rows; kick-on-enqueue handles fresh work. */
  intervalMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Fired when a push hit a 401/403 — the auth slice refreshes/re-logins, then resumes the loop. */
  onAuthRequired?: () => void;
  /** Telemetry for a sweep throw; the loop re-arms on the next tick regardless. */
  onSyncError?: (scope: string, error: unknown) => void;
}

export class SyncRunner extends PollingRunner {
  constructor(deps: SyncRunnerDeps) {
    super({
      scope: 'sync',
      sweep: async () => {
        const { push } = await deps.syncEngine.syncOnce();
        return { authRequired: push.authRequired };
      },
      ...(deps.intervalMs !== undefined ? { intervalMs: deps.intervalMs } : {}),
      ...(deps.setTimer !== undefined ? { setTimer: deps.setTimer } : {}),
      ...(deps.clearTimer !== undefined ? { clearTimer: deps.clearTimer } : {}),
      ...(deps.onAuthRequired !== undefined ? { onAuthRequired: deps.onAuthRequired } : {}),
      ...(deps.onSyncError !== undefined ? { onSyncError: deps.onSyncError } : {}),
    });
  }
}
