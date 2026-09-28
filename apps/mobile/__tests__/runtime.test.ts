/**
 * Restart recovery + background retry engine (spec reqs 9 & 10):
 *  - boot sweep: in-flight → retry, pending → retry, terminal stays
 *  - engine: exponential backoff on transients; NEVER auto-retries blocked (403/409) or
 *    frozen (412/422) work; pauses on auth failure instead of hammering a dead token.
 */
import { sync } from '@fieldcapture/contracts';
import {
  VolatileTicketEvidenceStore,
  submitFieldTicket,
  type HubSubmitOutcome,
  type HubFieldTicketSubmission,
  type TicketEvidence,
} from '../src/domain';
import {
  RetryEngine,
  inputFromEvidence,
  isAutoRetryable,
  recoverEvidenceOnStartup,
} from '../src/runtime';

const T0 = Date.parse('2026-06-10T18:00:00.000Z');

function evidence(
  localSeq: number,
  state: sync.OutboxItemState,
  extra: Partial<TicketEvidence> = {},
): TicketEvidence {
  const idempotencyKey = sync.buildIdempotencyKey('devA', localSeq, `op-${localSeq}`);
  return {
    envelope: {
      opId: `op-${localSeq}`,
      kind: 'command',
      type: 'ticket.submit',
      idempotencyKey,
      localSeq,
      dependsOn: [],
      payload: {
        idempotencyKey,
        serviceRequestId: `sr-${localSeq}`,
        snapshotHash: `hash-${localSeq}`,
        ticketNo: `T-${localSeq}`,
        quantityBbl: 10,
        disposalTicketNo: `D-${localSeq}`,
      },
    },
    state,
    attempts: 0,
    createdAt: new Date(T0).toISOString(),
    updatedAt: new Date(T0).toISOString(),
    ...extra,
  };
}

function queueSubmitter(outcomes: HubSubmitOutcome[]) {
  const calls: HubFieldTicketSubmission[] = [];
  return {
    calls,
    submitFieldTicket: async (s: HubFieldTicketSubmission): Promise<HubSubmitOutcome> => {
      calls.push(s);
      const next = outcomes.shift();
      if (next === undefined) throw new Error('unexpected extra submit');
      return next;
    },
  };
}

describe('recoverEvidenceOnStartup (boot sweep)', () => {
  it('sweeps orphaned in-flight rows to pending and leaves everything else alone', () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'in-flight', { attempts: 2 }));
    store.save(evidence(1, 'pending'));
    store.save(evidence(2, 'accepted'));
    store.save(evidence(3, 'rejected'));
    store.save(evidence(4, 'needs-review'));

    const { recoveredKeys } = recoverEvidenceOnStartup(store, () => new Date(T0 + 1_000));

    expect(recoveredKeys).toEqual(['gtr:devA:0:op-0']);
    expect(store.get('gtr:devA:0:op-0')).toMatchObject({
      state: 'pending',
      attempts: 3, // the interrupted attempt counts
      lastTransientReason: 'restart-interrupted',
    });
    expect(store.get('gtr:devA:1:op-1')?.state).toBe('pending');
    expect(store.get('gtr:devA:2:op-2')?.state).toBe('accepted');
    expect(store.get('gtr:devA:3:op-3')?.state).toBe('rejected');
    expect(store.get('gtr:devA:4:op-4')?.state).toBe('needs-review');
  });

  it('unblocks the double-submit guard: a recovered op can be resubmitted with the SAME key', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'in-flight'));
    recoverEvidenceOnStartup(store);
    const sub = queueSubmitter([{ outcome: 'accepted', duplicate: true }]);
    const result = await submitFieldTicket(
      { submitter: sub, evidenceStore: store },
      inputFromEvidence(store.get('gtr:devA:0:op-0')!),
    );
    expect(result).toMatchObject({ status: 'accepted', duplicate: true });
    expect(sub.calls[0]?.idempotencyKey).toBe('gtr:devA:0:op-0');
  });

  it('keeps a blocked rejection code through the sweep — still user-action-gated after restart', () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'in-flight', { lastRejectionCode: 'not_clocked_in' }));
    recoverEvidenceOnStartup(store);
    const swept = store.get('gtr:devA:0:op-0');
    expect(swept?.state).toBe('pending');
    expect(swept?.lastRejectionCode).toBe('not_clocked_in');
    expect(isAutoRetryable(swept!)).toBe(false);
  });
});

describe('RetryEngine.sweepOnce (classification discipline)', () => {
  const mkEngine = (
    store: VolatileTicketEvidenceStore,
    submitter: { submitFieldTicket: (s: HubFieldTicketSubmission) => Promise<HubSubmitOutcome> },
    overrides: Partial<ConstructorParameters<typeof RetryEngine>[0]> = {},
  ) =>
    new RetryEngine({
      evidenceStore: store,
      submitter,
      now: () => new Date(T0),
      random: () => 0.5,
      policy: { baseDelayMs: 1_000, maxDelayMs: 60_000 },
      ...overrides,
    });

  it('retries a due transient row with the same idempotency key and marks acceptance', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { attempts: 1, lastTransientReason: 'network' }));
    const sub = queueSubmitter([{ outcome: 'accepted', duplicate: false }]);
    const report = await mkEngine(store, sub).sweepOnce();
    expect(report).toMatchObject({ attempted: 1, accepted: 1, rescheduled: 0 });
    expect(sub.calls[0]?.idempotencyKey).toBe('gtr:devA:0:op-0');
    expect(store.get('gtr:devA:0:op-0')?.state).toBe('accepted');
  });

  it('NEVER auto-retries blocked (403/409) rows — they wait for the user', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { lastRejectionCode: 'not_clocked_in' }));
    store.save(evidence(1, 'pending', { lastRejectionCode: 'in_progress' }));
    const sub = queueSubmitter([]);
    const report = await mkEngine(store, sub).sweepOnce();
    expect(report).toMatchObject({ attempted: 0, skipped: 2 });
    expect(sub.calls).toHaveLength(0);
  });

  it('never touches frozen or terminal rows (412/422 needs-review, rejected, accepted)', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'needs-review', { lastRejectionCode: 'stale_version' }));
    store.save(evidence(1, 'rejected'));
    store.save(evidence(2, 'accepted'));
    const sub = queueSubmitter([]);
    const report = await mkEngine(store, sub).sweepOnce();
    expect(report).toMatchObject({ attempted: 0 });
    expect(sub.calls).toHaveLength(0);
  });

  it('respects the backoff schedule: not due yet → skipped; due → sent', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { nextAttemptAtMs: T0 + 5_000 })); // future
    store.save(evidence(1, 'pending', { nextAttemptAtMs: T0 - 1 })); // past
    const sub = queueSubmitter([{ outcome: 'accepted', duplicate: false }]);
    const report = await mkEngine(store, sub).sweepOnce();
    expect(report).toMatchObject({ attempted: 1, accepted: 1, skipped: 1 });
    expect(sub.calls[0]?.idempotencyKey).toBe('gtr:devA:1:op-1');
  });

  it('reschedules a transient failure with exponential full-jitter backoff', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { attempts: 2, lastTransientReason: 'server' }));
    const sub = queueSubmitter([{ outcome: 'transient', reason: 'network' }]);
    const report = await mkEngine(store, sub).sweepOnce();
    expect(report).toMatchObject({ attempted: 1, rescheduled: 1 });
    const row = store.get('gtr:devA:0:op-0');
    expect(row?.state).toBe('pending');
    expect(row?.attempts).toBe(3);
    // retryCount = attempts-1 = 2 → window = 1000 * 2^2 = 4000; random 0.5 → +2000ms
    expect(row?.nextAttemptAtMs).toBe(T0 + 2_000);
  });

  it('pauses on auth failure (one dead token must not fail every queued row)', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending'));
    store.save(evidence(1, 'pending'));
    const onAuthRequired = jest.fn();
    const sub = queueSubmitter([{ outcome: 'auth-failed', httpStatus: 401 }]);
    const report = await mkEngine(store, sub, { onAuthRequired }).sweepOnce();
    expect(report.pausedForAuth).toBe(true);
    expect(onAuthRequired).toHaveBeenCalledTimes(1);
    expect(sub.calls).toHaveLength(1); // second row NOT attempted
    expect(store.get('gtr:devA:0:op-0')).toMatchObject({
      state: 'pending',
      lastTransientReason: 'auth-failed',
    });
  });

  it('survives a throwing submitter: the row goes back to pending and the loop re-arms', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending'));
    const timers: number[] = [];
    const onSweepError = jest.fn();
    const engine = new RetryEngine({
      evidenceStore: store,
      submitter: {
        submitFieldTicket: async () => {
          throw new Error('store exploded');
        },
      },
      now: () => new Date(T0),
      random: () => 0.5,
      policy: { baseDelayMs: 1_000, maxDelayMs: 60_000 },
      setTimer: (_fn, ms) => {
        timers.push(ms);
        return timers.length;
      },
      clearTimer: () => undefined,
      onSweepError,
    });
    engine.start();
    await new Promise((resolve) => setImmediate(resolve));
    // the throw was contained by submitFieldTicket: row back to pending, marked client-error
    expect(store.get('gtr:devA:0:op-0')).toMatchObject({
      state: 'pending',
      lastTransientReason: 'client-error',
    });
    // and the loop re-armed a timer instead of dying silently
    expect(timers.length).toBeGreaterThan(0);
    engine.stop();
  });

  it('start() un-gates rows marked auth-failed from a previous run — no permanent starvation', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { lastTransientReason: 'auth-failed' }));
    const sub = queueSubmitter([{ outcome: 'accepted', duplicate: false }]);
    const engine = new RetryEngine({
      evidenceStore: store,
      submitter: sub,
      now: () => new Date(T0),
      random: () => 0.5,
      setTimer: () => 0,
      clearTimer: () => undefined,
    });
    engine.start();
    await new Promise((resolve) => setImmediate(resolve));
    expect(store.get('gtr:devA:0:op-0')?.state).toBe('accepted');
    engine.stop();
  });

  it('resumeAfterAuth clears the auth gate and retries the held-back rows', async () => {
    const store = new VolatileTicketEvidenceStore();
    store.save(evidence(0, 'pending', { lastTransientReason: 'auth-failed' }));
    const sub = queueSubmitter([{ outcome: 'accepted', duplicate: false }]);
    const engine = mkEngine(store, sub, {
      setTimer: () => 0,
      clearTimer: () => undefined,
    });
    expect(isAutoRetryable(store.get('gtr:devA:0:op-0')!)).toBe(false);
    engine.start(); // empty initial sweep (row gated)
    engine.resumeAfterAuth();
    await new Promise((resolve) => setImmediate(resolve));
    expect(store.get('gtr:devA:0:op-0')?.state).toBe('accepted');
  });
});
