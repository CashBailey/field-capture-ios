/**
 * Full sync engine behaviour (ADR 004): durable outbox dispatch over `/sync/commands`,
 * authoritative pull over `/sync/changes`, dependency ordering, idempotent replay, backoff,
 * frontier advancement, stale-token reset, and restart recovery. Hardware-free: fake transport,
 * volatile stores, injected clock/randomness.
 */
import { sync } from '@fieldcapture/contracts';

import {
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
  HubAuthError,
  HubNetworkError,
} from '../src/domain';
import { SyncEngine } from '../src/runtime';

function envelope(
  opId: string,
  localSeq: number,
  overrides?: Partial<sync.OperationEnvelope>,
): sync.OperationEnvelope {
  return {
    opId,
    kind: 'event',
    type: 'test.op',
    idempotencyKey: `gtr:devA:${localSeq}:${opId}`,
    localSeq,
    dependsOn: [],
    payload: { opId },
    ...overrides,
  };
}

function accepted(opId: string, commitSeq: number): sync.CommandResult {
  return { outcome: 'accepted', opId, token: { authorityEpoch: 1, commitSeq } };
}

/** Scriptable fake transport recording every batch and pull. */
class FakeTransport implements sync.SyncTransport {
  batches: sync.OperationEnvelope[][] = [];
  pulls: sync.ChangeToken[] = [];
  onSubmit: (batch: readonly sync.OperationEnvelope[]) => sync.CommandResult[] | Error = (batch) =>
    batch.map((env, i) => accepted(env.opId, i + 1));
  onPull: (since: sync.ChangeToken) => sync.ChangePage | Error = (since) => ({
    token: since,
    changes: [],
  });

  async submitBatch(batch: readonly sync.OperationEnvelope[]): Promise<sync.CommandResult[]> {
    this.batches.push([...batch]);
    const result = this.onSubmit(batch);
    if (result instanceof Error) throw result;
    return result;
  }

  async pullChanges(since: sync.ChangeToken): Promise<sync.ChangePage> {
    this.pulls.push(since);
    const result = this.onPull(since);
    if (result instanceof Error) throw result;
    return result;
  }

  async openUploadSession(): Promise<sync.UploadSessionResponse> {
    throw new Error('not under test');
  }
}

function makeEngine(overrides?: {
  transport?: FakeTransport;
  applyChanges?: (changes: readonly unknown[]) => void;
  nowMs?: () => number;
  onHubContact?: (at: Date) => void;
}) {
  const outbox = new VolatileSyncOutboxStore();
  const frontier = new VolatileSyncFrontierStore();
  const transport = overrides?.transport ?? new FakeTransport();
  const applied: unknown[] = [];
  const engine = new SyncEngine({
    outbox,
    frontier,
    transport,
    applyChanges: overrides?.applyChanges ?? ((changes) => applied.push(...changes)),
    now: () => new Date(overrides?.nowMs?.() ?? 1_000_000),
    random: () => 0.5,
    ...(overrides?.onHubContact !== undefined ? { onHubContact: overrides.onHubContact } : {}),
  });
  return { engine, outbox, frontier, transport, applied };
}

describe('pullOnce — atomic apply + frontier advance', () => {
  it('applies changes and advances the frontier inside one transaction', async () => {
    const outbox = new VolatileSyncOutboxStore();
    const frontier = new VolatileSyncFrontierStore();
    const transport = new FakeTransport();
    const order: string[] = [];
    const applied: unknown[] = [];
    let txDepth = 0;
    let appliedInTx = false;
    let frontierInTx = false;
    const engine = new SyncEngine({
      outbox,
      frontier,
      transport,
      applyChanges: (changes) => {
        applied.push(...changes);
        order.push('apply');
        if (txDepth > 0) appliedInTx = true;
      },
      transaction: (fn) => {
        txDepth += 1;
        order.push('tx-start');
        try {
          return fn();
        } finally {
          txDepth -= 1;
          order.push('tx-end');
        }
      },
      now: () => new Date(1_000_000),
      random: () => 0.5,
    });
    transport.onPull = () => ({
      token: { authorityEpoch: 1, commitSeq: 5 },
      changes: [{ authority_epoch: 1, commit_seq: 5, change_type: 'assignment.upsert' }],
    });
    const origSet = frontier.set.bind(frontier);
    jest.spyOn(frontier, 'set').mockImplementation((t) => {
      order.push('frontier');
      if (txDepth > 0) frontierInTx = true;
      origSet(t);
    });

    await engine.pullOnce();

    expect(appliedInTx).toBe(true);
    expect(frontierInTx).toBe(true);
    expect(order).toEqual(['tx-start', 'apply', 'frontier', 'tx-end']);
    expect(applied).toHaveLength(1);
  });
});

describe('enqueue', () => {
  it('persists a pending durable row with timestamps', () => {
    const { engine, outbox } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    const item = outbox.get('op-1');
    expect(item).toMatchObject({ state: 'pending', retryCount: 0 });
    expect(item?.createdAt).toBeDefined();
  });

  it('is idempotent on opId; a different envelope under the same opId throws', () => {
    const { engine } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    expect(engine.enqueue(envelope('op-1', 1)).envelope.localSeq).toBe(1);
    expect(() => engine.enqueue(envelope('op-1', 2))).toThrow(sync.OutboxError);
  });

  it('refuses an inconsistent envelope before anything is stored', () => {
    const { engine, outbox } = makeEngine();
    expect(() =>
      engine.enqueue(envelope('op-1', 1, { idempotencyKey: 'gtr:devA:9:op-1' })),
    ).toThrow(sync.OutboxError);
    expect(outbox.list()).toHaveLength(0);
  });
});

describe('pushOnce — command submit', () => {
  it('submits ready items in local_seq order and folds accepted outcomes', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-b', 2));
    engine.enqueue(envelope('op-a', 1));

    const report = await engine.pushOnce();

    expect(transport.batches[0].map((e) => e.opId)).toEqual(['op-a', 'op-b']);
    expect(report).toMatchObject({ submitted: 2, accepted: 2 });
    expect(outbox.get('op-a')).toMatchObject({
      state: 'accepted',
      committedToken: { authorityEpoch: 1, commitSeq: 1 },
    });
  });

  it('records a Hub contact after a commands exchange succeeds', async () => {
    const contacts: Date[] = [];
    const { engine } = makeEngine({
      nowMs: () => Date.parse('2026-06-10T20:00:00.000Z'),
      onHubContact: (at) => contacts.push(at),
    });
    engine.enqueue(envelope('op-1', 1));

    await engine.pushOnce();

    expect(contacts.map((d) => d.toISOString())).toEqual(['2026-06-10T20:00:00.000Z']);
  });

  it('duplicate replay: a transient failure re-sends the SAME envelope and lands accepted', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));

    transport.onSubmit = () => new HubNetworkError('offline');
    await engine.pushOnce();
    expect(outbox.get('op-1')).toMatchObject({ state: 'pending', retryCount: 1 });

    // Hub's idempotency ledger replays the accept; the key never changed.
    transport.onSubmit = (batch) => batch.map((e) => accepted(e.opId, 7));
    const { engine: engine2 } = { engine: null };
    void engine2;
    // clear the backoff stamp by moving the clock past it
    const item = outbox.get('op-1');
    const dueAt = item?.nextAttemptAtMs ?? 0;
    const engineLater = new SyncEngine({
      outbox,
      frontier: new VolatileSyncFrontierStore(),
      transport,
      applyChanges: () => {},
      now: () => new Date(dueAt + 1),
      random: () => 0.5,
    });
    const report = await engineLater.pushOnce();

    expect(report.accepted).toBe(1);
    expect(transport.batches).toHaveLength(2);
    expect(transport.batches[0][0].idempotencyKey).toBe(transport.batches[1][0].idempotencyKey);
    expect(outbox.get('op-1')?.state).toBe('accepted');
  });

  it('a rejected command freezes terminally with its code and detail; the envelope is preserved', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    transport.onSubmit = () => [
      { outcome: 'rejected', opId: 'op-1', rejectionCode: 'locked_sr', detail: 'SR locked by hub' },
    ];

    const report = await engine.pushOnce();

    expect(report.rejected).toBe(1);
    const item = outbox.get('op-1');
    expect(item).toMatchObject({
      state: 'rejected',
      rejectionCode: 'locked_sr',
      lastError: 'SR locked by hub',
    });
    // Local state preservation: the payload is still there for review — never wiped.
    expect(item?.envelope.payload).toEqual({ opId: 'op-1' });
    // Terminal: a later push never re-sends it.
    transport.onSubmit = () => [];
    await engine.pushOnce();
    expect(transport.batches).toHaveLength(1);
  });

  it('needs-review freezes the item with the review reason; never auto-resubmitted', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    transport.onSubmit = () => [
      { outcome: 'needs-review', opId: 'op-1', reviewReason: 'assignment_changed' },
    ];

    const report = await engine.pushOnce();

    expect(report.needsReview).toBe(1);
    expect(outbox.get('op-1')).toMatchObject({
      state: 'needs-review',
      lastError: 'assignment_changed',
    });
    await engine.pushOnce();
    expect(transport.batches).toHaveLength(1);
  });

  it('a missing per-op result reschedules ONLY that op', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    engine.enqueue(envelope('op-2', 2));
    transport.onSubmit = () => [accepted('op-1', 1)];

    const report = await engine.pushOnce();

    expect(report).toMatchObject({ accepted: 1, rescheduled: 1 });
    expect(outbox.get('op-1')?.state).toBe('accepted');
    expect(outbox.get('op-2')).toMatchObject({ state: 'pending', retryCount: 1 });
  });
});

describe('pushOnce — retry, backoff, auth', () => {
  it('a transport failure returns the whole batch to pending with a backoff stamp', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    transport.onSubmit = () => new HubNetworkError('offline');

    const report = await engine.pushOnce();

    expect(report.rescheduled).toBe(1);
    const item = outbox.get('op-1');
    expect(item).toMatchObject({ state: 'pending', retryCount: 1 });
    expect(item?.nextAttemptAtMs).toBeGreaterThan(1_000_000);
  });

  it('items inside their backoff window are not redispatched; due items are', async () => {
    let nowMs = 1_000_000;
    const { engine, outbox, transport } = makeEngine({ nowMs: () => nowMs });
    engine.enqueue(envelope('op-1', 1));
    transport.onSubmit = () => new HubNetworkError('offline');
    await engine.pushOnce();

    transport.onSubmit = (batch) => batch.map((e) => accepted(e.opId, 1));
    const early = await engine.pushOnce();
    expect(early).toMatchObject({ submitted: 0, waitingBackoff: 1 });

    nowMs = (outbox.get('op-1')?.nextAttemptAtMs ?? 0) + 1;
    const due = await engine.pushOnce();
    expect(due).toMatchObject({ submitted: 1, accepted: 1 });
  });

  it('an auth failure reports authRequired and leaves items pending WITHOUT backoff', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    transport.onSubmit = () => new HubAuthError('dead token', 401);

    const report = await engine.pushOnce();

    expect(report.authRequired).toBe(true);
    const item = outbox.get('op-1');
    expect(item?.state).toBe('pending');
    expect(item?.nextAttemptAtMs).toBeUndefined(); // due the moment re-auth lands
  });
});

describe('pushOnce — dependency ordering', () => {
  it('a child waits while its parent is unresolved, then ships after the parent commits', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('parent', 1));
    engine.enqueue(envelope('child', 2, { dependsOn: ['parent'] }));

    // Parent transiently fails: child must NOT be in that batch.
    transport.onSubmit = (batch) =>
      batch.some((e) => e.opId === 'parent') ? new HubNetworkError('offline') : [];
    const first = await engine.pushOnce();
    expect(transport.batches[0].map((e) => e.opId)).toEqual(['parent']);
    expect(first.waitingDependency).toBe(1);

    // Parent due again and accepted; child ships on the NEXT pass (after the commit is durable).
    const dueAt = (outbox.get('parent')?.nextAttemptAtMs ?? 0) + 1;
    const engineLater = new SyncEngine({
      outbox,
      frontier: new VolatileSyncFrontierStore(),
      transport,
      applyChanges: () => {},
      now: () => new Date(dueAt),
      random: () => 0.5,
    });
    transport.onSubmit = (batch) => batch.map((e) => accepted(e.opId, 1));
    await engineLater.pushOnce();
    expect(transport.batches[1].map((e) => e.opId)).toEqual(['parent']);
    await engineLater.pushOnce();
    expect(transport.batches[2].map((e) => e.opId)).toEqual(['child']);
    expect(outbox.get('child')?.state).toBe('accepted');
  });

  it('a child of a terminally rejected parent surfaces as blocked, never dispatched', async () => {
    const { engine, transport } = makeEngine();
    engine.enqueue(envelope('parent', 1));
    engine.enqueue(envelope('child', 2, { dependsOn: ['parent'] }));
    transport.onSubmit = () => [
      { outcome: 'rejected', opId: 'parent', rejectionCode: 'locked_sr' },
    ];
    await engine.pushOnce();

    const report = await engine.pushOnce();
    expect(report.blocked).toEqual([
      { opId: 'child', reason: 'dead-dependency', deps: ['parent'] },
    ]);
    expect(transport.batches.flat().some((e) => e.opId === 'child')).toBe(false);
  });

  it('a parent pruned to the committed-op ledger still satisfies its child', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('parent', 1));
    transport.onSubmit = (batch) => batch.map((e) => accepted(e.opId, 1));
    await engine.pushOnce();
    outbox.markCommittedAndRemove('parent');

    engine.enqueue(envelope('child', 2, { dependsOn: ['parent'] }));
    const report = await engine.pushOnce();
    expect(report.accepted).toBe(1);
    expect(outbox.get('child')?.state).toBe('accepted');
  });
});

describe('pullOnce — change-token advancement', () => {
  it('pulls after the stored frontier, applies changes, then persists the new frontier', async () => {
    const { engine, frontier, transport, applied } = makeEngine();
    frontier.set({ authorityEpoch: 1, commitSeq: 10 });
    transport.onPull = () => ({
      token: { authorityEpoch: 1, commitSeq: 12 },
      changes: [{ entity: 'assignment' }, { entity: 'sr' }],
    });

    const report = await engine.pullOnce();

    expect(transport.pulls[0]).toEqual({ authorityEpoch: 1, commitSeq: 10 });
    expect(applied).toHaveLength(2);
    expect(report).toEqual({
      applied: 2,
      frontier: { authorityEpoch: 1, commitSeq: 12 },
      frontierReset: false,
    });
    expect(frontier.get()).toEqual({ authorityEpoch: 1, commitSeq: 12 });
  });

  it('records a Hub contact after a changes pull succeeds', async () => {
    const contacts: Date[] = [];
    const { engine } = makeEngine({
      nowMs: () => Date.parse('2026-06-10T20:00:00.000Z'),
      onHubContact: (at) => contacts.push(at),
    });

    await engine.pullOnce();

    expect(contacts.map((d) => d.toISOString())).toEqual(['2026-06-10T20:00:00.000Z']);
  });

  it('first pull ever starts from the zero token', async () => {
    const { engine, transport } = makeEngine();
    await engine.pullOnce();
    expect(transport.pulls[0]).toEqual({ authorityEpoch: 0, commitSeq: 0 });
  });

  it('a regressed page token throws BEFORE any change is applied or persisted', async () => {
    const { engine, frontier, transport, applied } = makeEngine();
    frontier.set({ authorityEpoch: 1, commitSeq: 10 });
    transport.onPull = () => ({
      token: { authorityEpoch: 1, commitSeq: 9 },
      changes: [{ entity: 'assignment' }],
    });

    await expect(engine.pullOnce()).rejects.toThrow(sync.ChangeTokenError);
    expect(applied).toHaveLength(0);
    expect(frontier.get()).toEqual({ authorityEpoch: 1, commitSeq: 10 });
  });

  it('a higher epoch with a restarted commit_seq is a legitimate advance', async () => {
    const { engine, frontier, transport } = makeEngine();
    frontier.set({ authorityEpoch: 1, commitSeq: 10 });
    transport.onPull = () => ({ token: { authorityEpoch: 2, commitSeq: 1 }, changes: [] });
    const report = await engine.pullOnce();
    expect(report.frontier).toEqual({ authorityEpoch: 2, commitSeq: 1 });
  });
});

describe('pullOnce — stale token handling', () => {
  it('resets the frontier to Hub`s suggestion and re-pulls in the same pass', async () => {
    const { engine, frontier, transport, applied } = makeEngine();
    frontier.set({ authorityEpoch: 1, commitSeq: 99 });
    let first = true;
    transport.onPull = (since) => {
      if (first) {
        first = false;
        return Object.assign(
          new sync.StaleChangeTokenError('stale', { authorityEpoch: 2, commitSeq: 0 }),
        );
      }
      expect(since).toEqual({ authorityEpoch: 2, commitSeq: 0 });
      return { token: { authorityEpoch: 2, commitSeq: 3 }, changes: [{ entity: 'sr' }] };
    };

    const report = await engine.pullOnce();

    expect(report).toEqual({
      applied: 1,
      frontier: { authorityEpoch: 2, commitSeq: 3 },
      frontierReset: true,
    });
    expect(applied).toHaveLength(1);
    expect(frontier.get()).toEqual({ authorityEpoch: 2, commitSeq: 3 });
  });

  it('without a suggested reset it restarts from the zero token (full resync)', async () => {
    const { engine, transport } = makeEngine();
    let first = true;
    transport.onPull = () => {
      if (first) {
        first = false;
        return new sync.StaleChangeTokenError('stale');
      }
      return { token: { authorityEpoch: 1, commitSeq: 1 }, changes: [] };
    };
    const report = await engine.pullOnce();
    expect(transport.pulls[1]).toEqual({ authorityEpoch: 0, commitSeq: 0 });
    expect(report.frontierReset).toBe(true);
  });
});

describe('restart recovery', () => {
  it('orphaned in-flight rows return to pending; terminal rows stay frozen', async () => {
    const { engine, outbox, transport } = makeEngine();
    engine.enqueue(envelope('op-1', 1));
    engine.enqueue(envelope('op-2', 2));
    transport.onSubmit = () => [
      accepted('op-1', 1),
      { outcome: 'needs-review', opId: 'op-2', reviewReason: 'drift' },
    ];
    await engine.pushOnce();
    // Simulate a crash mid-flight for a third op.
    engine.enqueue(envelope('op-3', 3));
    const item = outbox.get('op-3');
    outbox.save({ ...(item as NonNullable<typeof item>), state: 'in-flight' });

    const recovered = engine.recoverOnStartup();

    expect(recovered).toEqual(['op-3']);
    expect(outbox.get('op-3')).toMatchObject({ state: 'pending', retryCount: 1 });
    expect(outbox.get('op-1')?.state).toBe('accepted');
    expect(outbox.get('op-2')?.state).toBe('needs-review');
  });
});
