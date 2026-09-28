/**
 * Shared self-scheduling drain loop behind `SyncRunner` and `UploadRunner` (they were line-for-line
 * identical — same running/pausedForAuth/sweeping/resweep flags, timer plumbing, auth pause/resume).
 * Only the per-pass work differs, injected as `sweep`. Mirrors `RetryEngine`'s lifecycle so all
 * three drivers behave identically; all time is injected for deterministic tests.
 *
 *  - Periodic timer re-drives `sweep` on a fixed cadence (the engine self-skips not-yet-due work, so
 *    ticking while offline is a safe no-op).
 *  - `notifyQueued()` kicks an immediate pass when fresh work is enqueued (no whole-interval wait).
 *  - When a pass reports `authRequired` (401/403) the loop PAUSES — hammering Hub with a dead token
 *    turns one failure into N — until `resumeAfterAuth()` is called.
 */
export interface PollingRunnerDeps {
  /** One pass of runner-specific work; `authRequired` true pauses the loop until re-auth. */
  sweep: () => Promise<{ authRequired: boolean }>;
  /** Telemetry scope label for a sweep throw (e.g. 'sync' | 'upload'). */
  scope: string;
  /** Fixed polling cadence (ms); kick-on-enqueue handles fresh work. Floored at 1s to never spin. */
  intervalMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  /** Fired when a pass hit a 401/403 — the auth slice refreshes/re-logins, then resumes the loop. */
  onAuthRequired?: () => void;
  /** Telemetry for a sweep throw; the loop re-arms on the next tick regardless. */
  onSyncError?: (scope: string, error: unknown) => void;
}

const DEFAULT_INTERVAL_MS = 60_000;
/** Never poll faster than this — a misconfigured tiny interval must not busy-spin the network. */
const MIN_INTERVAL_MS = 1_000;

export class PollingRunner {
  private readonly intervalMs: number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;

  private running = false;
  private pausedForAuth = false;
  private sweeping = false;
  private resweepRequested = false;
  private timer: unknown;

  constructor(private readonly deps: PollingRunnerDeps) {
    this.intervalMs = Math.max(MIN_INTERVAL_MS, deps.intervalMs ?? DEFAULT_INTERVAL_MS);
    this.setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.pausedForAuth = false;
    void this.runSweep();
  }

  stop(): void {
    this.running = false;
    this.cancelTimer();
  }

  /** True while the runner is holding off because a pass hit a 401/403. */
  isPausedForAuth(): boolean {
    return this.pausedForAuth;
  }

  /**
   * Call whenever a valid session is (re)established — interactive login OR a silent refresh
   * observed elsewhere. Idempotent and cheap when there is nothing to resume.
   */
  resumeAfterAuth(): void {
    if (!this.running || !this.pausedForAuth) return;
    this.pausedForAuth = false;
    void this.runSweep();
  }

  /** Re-arm immediately when new work enters the queue (fresh evidence / blob / print event). */
  notifyQueued(): void {
    if (!this.running || this.pausedForAuth) return;
    if (this.sweeping) {
      this.resweepRequested = true;
      return;
    }
    void this.runSweep();
  }

  /**
   * One pass: run the injected sweep, pause on auth, otherwise re-arm the periodic timer. Public for
   * tests and a user-facing "sync now". A throw never kills the loop.
   */
  async runSweep(): Promise<void> {
    if (!this.running || this.pausedForAuth) return;
    if (this.sweeping) {
      // A sweep is in progress; run another full pass when it finishes instead of dropping this.
      this.resweepRequested = true;
      return;
    }
    this.sweeping = true;
    try {
      const { authRequired } = await this.deps.sweep();
      if (authRequired) {
        this.pausedForAuth = true;
        this.deps.onAuthRequired?.();
        return; // paused — do NOT re-arm; resumeAfterAuth() restarts the loop
      }
    } catch (error) {
      // A sweep must never kill the loop: the timer below re-arms regardless, so the queue keeps
      // draining on the next tick instead of silently freezing.
      this.deps.onSyncError?.(this.deps.scope, error);
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
    // Fixed cadence: the engine self-skips work still inside its backoff window, so a plain interval
    // is enough — no per-row due-time scan (unlike RetryEngine, which owns the schedule).
    this.timer = this.setTimer(() => void this.runSweep(), this.intervalMs);
  }

  private cancelTimer(): void {
    if (this.timer !== undefined) {
      this.clearTimer(this.timer);
      this.timer = undefined;
    }
  }
}
