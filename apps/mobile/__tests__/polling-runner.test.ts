/**
 * PollingRunner: the shared self-scheduling drain loop behind SyncRunner/UploadRunner. Injected
 * timers make the schedule deterministic. Proves the interval floor (never busy-spin), the
 * pause-on-auth / resume cycle, and that a thrown sweep never kills the loop.
 */
import { PollingRunner } from '../src/runtime/pollingRunner';

function makeRunner(over: {
  sweep: () => Promise<{ authRequired: boolean }>;
  intervalMs?: number;
  onSyncError?: (scope: string, error: unknown) => void;
  onAuthRequired?: () => void;
}) {
  const timers: { fn: () => void; ms: number }[] = [];
  const runner = new PollingRunner({
    scope: 'test',
    sweep: over.sweep,
    ...(over.intervalMs !== undefined ? { intervalMs: over.intervalMs } : {}),
    setTimer: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length - 1;
    },
    clearTimer: () => undefined,
    ...(over.onSyncError !== undefined ? { onSyncError: over.onSyncError } : {}),
    ...(over.onAuthRequired !== undefined ? { onAuthRequired: over.onAuthRequired } : {}),
  });
  const flush = () => new Promise((r) => setImmediate(r));
  return { runner, timers, flush, fireLast: () => timers.at(-1)?.fn() };
}

describe('PollingRunner', () => {
  it('floors a too-small interval at 1s so the loop never busy-spins', async () => {
    const { runner, timers, flush } = makeRunner({
      sweep: async () => ({ authRequired: false }),
      intervalMs: 10,
    });
    runner.start();
    await flush();
    expect(timers.at(-1)?.ms).toBe(1_000); // 10ms request floored to 1000ms
    runner.stop();
  });

  it('defaults to the 60s cadence when no interval is given', async () => {
    const { runner, timers, flush } = makeRunner({ sweep: async () => ({ authRequired: false }) });
    runner.start();
    await flush();
    expect(timers.at(-1)?.ms).toBe(60_000);
    runner.stop();
  });

  it('honors a sane interval unchanged', async () => {
    const { runner, timers, flush } = makeRunner({
      sweep: async () => ({ authRequired: false }),
      intervalMs: 30_000,
    });
    runner.start();
    await flush();
    expect(timers.at(-1)?.ms).toBe(30_000);
    runner.stop();
  });

  it('pauses on authRequired (no re-arm) and resumes on resumeAfterAuth', async () => {
    let auth = true;
    let authRequiredCalls = 0;
    const { runner, timers, flush } = makeRunner({
      sweep: async () => ({ authRequired: auth }),
      onAuthRequired: () => {
        authRequiredCalls += 1;
      },
    });
    runner.start();
    await flush();
    expect(authRequiredCalls).toBe(1);
    expect(runner.isPausedForAuth()).toBe(true);
    expect(timers).toHaveLength(0); // paused → did NOT arm a periodic timer

    auth = false;
    runner.resumeAfterAuth();
    await flush();
    expect(runner.isPausedForAuth()).toBe(false);
    expect(timers.at(-1)?.ms).toBe(60_000); // resumed and re-armed
    runner.stop();
  });

  it('a thrown sweep is reported with the scope and never kills the loop', async () => {
    let blowUp = true;
    const errors: Array<{ scope: string; error: unknown }> = [];
    const { runner, timers, flush, fireLast } = makeRunner({
      sweep: async () => {
        if (blowUp) throw new Error('boom');
        return { authRequired: false };
      },
      onSyncError: (scope, error) => errors.push({ scope, error }),
    });
    runner.start();
    await flush();
    expect(errors).toHaveLength(1);
    expect(errors[0]!.scope).toBe('test');
    expect(timers.at(-1)?.ms).toBe(60_000); // re-armed despite the throw

    blowUp = false;
    fireLast(); // the next tick drains cleanly
    await flush();
    expect(errors).toHaveLength(1); // no new error
    runner.stop();
  });
});
