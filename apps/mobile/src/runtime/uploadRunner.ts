/**
 * Runtime driver for the ADR-004 UploadEngine — the blob-upload counterpart of SyncRunner.
 *
 * The UploadEngine is inert on its own; this thin adapter over the shared `PollingRunner` runs one
 * pass — `processOnce()` (open session → chunked PATCH → hash-verify → enqueue attachment.link →
 * reconcile link) and, when not paused for auth, `purgeOnce()` (drop local bytes once a blob is
 * fully linked). See `PollingRunner` for the lifecycle (periodic drain, kick-on-capture via
 * `notifyQueued`, pause-on-401 until `resumeAfterAuth`).
 */
import { PollingRunner } from './pollingRunner';
import type { UploadEngine } from './uploadEngine';

export interface UploadRunnerDeps {
  uploadEngine: Pick<UploadEngine, 'processOnce' | 'purgeOnce'>;
  /** Fixed polling cadence (ms) that drains in-progress uploads; kick-on-capture handles fresh ones. */
  intervalMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Fired when an upload hit a 401/403 — the auth slice refreshes/re-logins, then resumes. */
  onAuthRequired?: () => void;
  /** Telemetry for a sweep throw; the loop re-arms on the next tick regardless. */
  onSyncError?: (scope: string, error: unknown) => void;
}

export class UploadRunner extends PollingRunner {
  constructor(deps: UploadRunnerDeps) {
    super({
      scope: 'upload',
      sweep: async () => {
        const report = await deps.uploadEngine.processOnce();
        if (report.authRequired) return { authRequired: true };
        // Cheap, network-free: drop local bytes for blobs that are now fully linked.
        await deps.uploadEngine.purgeOnce();
        return { authRequired: false };
      },
      ...(deps.intervalMs !== undefined ? { intervalMs: deps.intervalMs } : {}),
      ...(deps.setTimer !== undefined ? { setTimer: deps.setTimer } : {}),
      ...(deps.clearTimer !== undefined ? { clearTimer: deps.clearTimer } : {}),
      ...(deps.onAuthRequired !== undefined ? { onAuthRequired: deps.onAuthRequired } : {}),
      ...(deps.onSyncError !== undefined ? { onSyncError: deps.onSyncError } : {}),
    });
  }
}
