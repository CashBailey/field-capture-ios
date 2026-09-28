/**
 * SyncRunner: the runtime driver that makes the ADR-004 SyncEngine actually drain. Mirrors the
 * RetryEngine test discipline — scriptable fake transport, volatile stores, injected timers — so
 * the schedule is fully deterministic. Proves it drives syncOnce on start, kicks on enqueue,
 * re-arms periodically, backs off (never hammers), pauses on a 401 (push OR pull leg), resumes on
 * re-auth, and stays inert before start / after stop.
 */
import { sync } from '@fieldcapture/contracts';

import {
  HubAuthError,
  HubNetworkError,
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
} from '../src/domain';
import { SyncEngine, SyncRunner } from '../src/runtime';

const INTERVAL_MS = 30_000;

function envelope(opId: string, localSeq: number): sync.OperationEnvelope {
  return {
    opId,
    kind: 'event',
    type: 'dvir.submit',
    idempotencyKey: `gtr:devA:${localSeq}:${opId}`,
    localSeq,
    dependsOn: [],
    payload: { opId },
  };
}

function accepted(opId: string, commitSeq: number): sync.CommandResult {
  return { outcome: 'accepted', opId, token: { authorityEpoch: 1, commitSeq } };
}

class FakeTransport implements sync.SyncTransport {
  batches: sync.OperationEnvelope[][] = [];
  pulls: sync.ChangeToken[] = [];
  onSubmit: (batch: readonly sync.OperationEnvelope[]) => sync.CommandResult[] | Error = (batch) =>
    batch.map((e, i) => accepted(e.opId, i + 1));
  onPull: (since: sync.ChangeToken) => sync.ChangePage | Error = (since) => ({
    token: since,
    changes: [],
  });

  async submitBatch(batch: readonly sync.OperationEnvelope[]): Promise<sync.CommandResult[]> {
    this.batches.push([...batch]);
    const r = this.onSubmit(batch);
    if (r instanceof Error) throw r;
    return r;
  }

  async pullChanges(since: sync.ChangeToken): Promise<sync.ChangePage> {
    this.pulls.push(since);
    const r = this.onPull(since);
    if (r instanceof Error) throw r;
    return r;
  }

  async openUploadSession(): Promise<sync.UploadSessionResponse> {
    throw new Error('not under test');
  }
}

/** Flush chained microtasks (runSweep awaits syncOnce, may re-sweep once). */
async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) await new Promise((r) => setImmediate(r));
}

function makeRunner() {
  const outbox = new VolatileSyncOutboxStore();
  const frontier = new VolatileSyncFrontierStore();
  const transport = new FakeTransport();
  const engine = new SyncEngine({
    outbox,
    frontier,
    transport,
    applyChanges: () => {},
    now: () => new Date(1_000_000),
    random: () => 0.5,
  });
  const timers: { fn: () => void; ms: number }[] = [];
  let authRequired = 0;
  const runner = new SyncRunner({
    syncEngine: engine,
    intervalMs: INTERVAL_MS,
    setTimer: (fn, ms) => {
      timers.push({ fn, ms });
      return timers.length - 1;
    },
    clearTimer: () => undefined,
    onAuthRequired: () => {
      authRequired += 1;
    },
  });
  const fireLastTimer = () => timers[timers.length - 1]?.fn();
  return { runner, engine, outbox, transport, timers, fireLastTimer, authReq: () => authRequired };
}

describe('SyncRunner', () => {
  it('drives a push on start and arms the periodic timer', async () => {
    const { runner, engine, transport, timers } = makeRunner();
    engine.enqueue(envelope('op-1', 1));
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(1);
    expect(transport.batches[0]!.map((e) => e.opId)).toEqual(['op-1']);
    expect(timers.at(-1)?.ms).toBe(INTERVAL_MS); // re-armed for the next periodic drain
    runner.stop();
  });

  it('re-sweeps when the periodic timer fires', async () => {
    const { runner, engine, transport, fireLastTimer } = makeRunner();
    engine.enqueue(envelope('op-1', 1));
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(1);
    engine.enqueue(envelope('op-2', 2));
    fireLastTimer(); // the periodic tick
    await flush();
    expect(transport.batches).toHaveLength(2);
    runner.stop();
  });

  it('kicks an immediate push on notifyQueued (fresh evidence enqueued)', async () => {
    const { runner, engine, transport } = makeRunner();
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(0); // nothing to push yet
    engine.enqueue(envelope('op-1', 1));
    runner.notifyQueued();
    await flush();
    expect(transport.batches).toHaveLength(1);
    runner.stop();
  });

  it('backs off and does not hammer: a transient failure is not re-submitted within its window', async () => {
    const { runner, engine, transport, fireLastTimer } = makeRunner();
    transport.onSubmit = () => new HubNetworkError('offline');
    engine.enqueue(envelope('op-1', 1));
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(1); // one attempt
    fireLastTimer(); // next tick — but the row is inside its backoff window (clock frozen)
    await flush();
    expect(transport.batches).toHaveLength(1); // engine skips the backed-off row; no hammering
    runner.stop();
  });

  it('pauses on a push 401 and stops scheduling until re-auth', async () => {
    const { runner, engine, transport, timers, authReq } = makeRunner();
    transport.onSubmit = () => new HubAuthError('dead token', 401);
    engine.enqueue(envelope('op-1', 1));
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(1);
    expect(runner.isPausedForAuth()).toBe(true);
    expect(authReq()).toBe(1);
    expect(timers).toHaveLength(0); // paused: no periodic timer armed
    // notifyQueued is a no-op while paused — no extra push.
    engine.enqueue(envelope('op-2', 2));
    runner.notifyQueued();
    await flush();
    expect(transport.batches).toHaveLength(1);
    runner.stop();
  });

  it('resumes and drains after resumeAfterAuth once a fresh token exists', async () => {
    const { runner, engine, transport } = makeRunner();
    transport.onSubmit = () => new HubAuthError('dead token', 401);
    engine.enqueue(envelope('op-1', 1));
    runner.start();
    await flush();
    expect(runner.isPausedForAuth()).toBe(true);
    transport.onSubmit = (batch) => batch.map((e) => accepted(e.opId, 1));
    runner.resumeAfterAuth();
    await flush();
    expect(runner.isPausedForAuth()).toBe(false);
    expect(transport.batches).toHaveLength(2); // the retry went through
    runner.stop();
  });

  it('is inert before start and after stop', async () => {
    const { runner, engine, transport, fireLastTimer } = makeRunner();
    engine.enqueue(envelope('op-1', 1));
    runner.notifyQueued(); // not started yet
    await flush();
    expect(transport.batches).toHaveLength(0);

    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(1);
    runner.stop();
    engine.enqueue(envelope('op-2', 2));
    fireLastTimer(); // a stale timer firing after stop must do nothing
    runner.notifyQueued();
    await flush();
    expect(transport.batches).toHaveLength(1);
  });

  it('pauses on a pull-leg 401 too (the hardening): no push work, pull 401s', async () => {
    const { runner, transport } = makeRunner();
    // Nothing enqueued -> push sends nothing (authRequired false from push); pull then 401s.
    transport.onPull = () => new HubAuthError('dead token', 401);
    runner.start();
    await flush();
    expect(transport.batches).toHaveLength(0);
    expect(transport.pulls.length).toBeGreaterThanOrEqual(1);
    expect(runner.isPausedForAuth()).toBe(true);
    runner.stop();
  });
});
