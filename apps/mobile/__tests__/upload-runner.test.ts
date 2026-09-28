/**
 * UploadRunner: the runtime driver that makes the ADR-004 UploadEngine drain blobs. Same discipline
 * as SyncRunner — injected timers, scriptable engine — so the schedule is deterministic. Proves it
 * drives processOnce (+purgeOnce) on start, kicks on capture, re-arms periodically, pauses on a 401
 * (authRequired), resumes on re-auth, survives a throw, and is inert before start / after stop.
 */
import { UploadRunner, type UploadRunnerDeps, type UploadSweepReport } from '../src/runtime';

const INTERVAL_MS = 30_000;

function report(overrides?: Partial<UploadSweepReport>): UploadSweepReport {
  return {
    uploaded: 0,
    dedupedAlreadyPresent: 0,
    linksEnqueued: 0,
    linked: 0,
    expired: 0,
    deferred: 0,
    authRequired: false,
    ...overrides,
  };
}

class FakeUploadEngine {
  processOnceCalls = 0;
  purgeOnceCalls = 0;
  nextReport: UploadSweepReport = report();
  onProcess?: () => void; // hook to throw

  async processOnce(): Promise<UploadSweepReport> {
    this.processOnceCalls += 1;
    this.onProcess?.();
    return this.nextReport;
  }

  async purgeOnce(): Promise<string[]> {
    this.purgeOnceCalls += 1;
    return [];
  }
}

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) await new Promise((r) => setImmediate(r));
}

function makeRunner(engineOverrides?: Partial<FakeUploadEngine>) {
  const engine = Object.assign(new FakeUploadEngine(), engineOverrides);
  const timers: { fn: () => void; ms: number }[] = [];
  let authRequired = 0;
  const syncErrors: unknown[] = [];
  const deps: UploadRunnerDeps = {
    uploadEngine: engine,
    intervalMs: INTERVAL_MS,
    setTimer: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length - 1;
    },
    clearTimer: () => undefined,
    onAuthRequired: () => {
      authRequired += 1;
    },
    onSyncError: (_scope, error) => {
      syncErrors.push(error);
    },
  };
  const runner = new UploadRunner(deps);
  return {
    runner,
    engine,
    timers,
    fireLastTimer: () => timers[timers.length - 1]?.fn(),
    authReq: () => authRequired,
    syncErrors,
  };
}

describe('UploadRunner', () => {
  it('drives processOnce + purgeOnce on start and arms the periodic timer', async () => {
    const { runner, engine, timers } = makeRunner();
    runner.start();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
    expect(engine.purgeOnceCalls).toBe(1);
    expect(timers.at(-1)?.ms).toBe(INTERVAL_MS);
    runner.stop();
  });

  it('re-sweeps when the periodic timer fires', async () => {
    const { runner, engine, fireLastTimer } = makeRunner();
    runner.start();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
    fireLastTimer();
    await flush();
    expect(engine.processOnceCalls).toBe(2);
    runner.stop();
  });

  it('kicks an immediate sweep on notifyQueued (a fresh blob captured)', async () => {
    const { runner, engine } = makeRunner();
    runner.start();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
    runner.notifyQueued();
    await flush();
    expect(engine.processOnceCalls).toBe(2);
    runner.stop();
  });

  it('pauses on authRequired: no purge, no timer, and notifyQueued is inert until resume', async () => {
    const { runner, engine, timers, authReq } = makeRunner({
      nextReport: report({ authRequired: true }),
    });
    runner.start();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
    expect(engine.purgeOnceCalls).toBe(0); // paused before purge
    expect(runner.isPausedForAuth()).toBe(true);
    expect(authReq()).toBe(1);
    expect(timers).toHaveLength(0);
    runner.notifyQueued();
    await flush();
    expect(engine.processOnceCalls).toBe(1); // still paused
    runner.stop();
  });

  it('resumes and drains after resumeAfterAuth once a fresh token exists', async () => {
    const { runner, engine } = makeRunner({ nextReport: report({ authRequired: true }) });
    runner.start();
    await flush();
    expect(runner.isPausedForAuth()).toBe(true);
    engine.nextReport = report({ uploaded: 1 }); // token is good now
    runner.resumeAfterAuth();
    await flush();
    expect(runner.isPausedForAuth()).toBe(false);
    expect(engine.processOnceCalls).toBe(2);
    expect(engine.purgeOnceCalls).toBe(1);
    runner.stop();
  });

  it('a processOnce throw is contained (onSyncError) and the loop re-arms', async () => {
    const { runner, engine, timers, syncErrors } = makeRunner();
    engine.onProcess = () => {
      throw new Error('boom');
    };
    runner.start();
    await flush();
    expect(syncErrors).toHaveLength(1);
    expect(timers.at(-1)?.ms).toBe(INTERVAL_MS); // re-armed despite the throw
    runner.stop();
  });

  it('is inert before start and after stop', async () => {
    const { runner, engine, fireLastTimer } = makeRunner();
    runner.notifyQueued(); // not started
    await flush();
    expect(engine.processOnceCalls).toBe(0);

    runner.start();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
    runner.stop();
    fireLastTimer(); // a stale timer firing after stop must do nothing
    runner.notifyQueued();
    await flush();
    expect(engine.processOnceCalls).toBe(1);
  });
});
