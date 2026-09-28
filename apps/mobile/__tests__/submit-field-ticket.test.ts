import { sync } from '@fieldcapture/contracts';
import {
  VolatileTicketEvidenceStore,
  submitFieldTicket,
  type FieldTicketInput,
  type HubFieldTicketSubmission,
  type HubSubmitOutcome,
} from '../src/domain';

const INPUT: FieldTicketInput = {
  serviceRequestId: 'sr-9',
  snapshotHash: 'hash-abc',
  ticketNo: '12345',
  quantityBbl: 120,
  disposalTicketNo: 'D-123',
  deviceInstanceId: 'devA',
  localSeq: 1,
  opUuid: 'op-uuid-1',
};

const EXPECTED_KEY = 'gtr:devA:1:op-uuid-1';

function submitter(outcome: HubSubmitOutcome) {
  const calls: HubFieldTicketSubmission[] = [];
  return {
    calls,
    submitFieldTicket: async (s: HubFieldTicketSubmission) => {
      calls.push(s);
      return outcome;
    },
  };
}

describe('submitFieldTicket (minimal submit path)', () => {
  it('builds the idempotency key with the contracts helper and sends the full payload', async () => {
    const store = new VolatileTicketEvidenceStore();
    const sub = submitter({ outcome: 'accepted', duplicate: false, ticketId: 'ft-1' });
    await submitFieldTicket({ submitter: sub, evidenceStore: store }, INPUT);
    expect(sub.calls).toHaveLength(1);
    expect(sub.calls[0]).toEqual({
      idempotencyKey: EXPECTED_KEY,
      serviceRequestId: 'sr-9',
      snapshotHash: 'hash-abc',
      ticketNo: '12345',
      quantityBbl: 120,
      disposalTicketNo: 'D-123',
    });
    // sanity: the key really is the contracts format
    expect(sync.parseIdempotencyKey(EXPECTED_KEY)).toEqual({
      deviceInstanceId: 'devA',
      localSeq: 1,
      opUuid: 'op-uuid-1',
    });
  });

  it('marks the evidence accepted only after Hub accepts', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      { submitter: submitter({ outcome: 'accepted', duplicate: false }), evidenceStore: store },
      INPUT,
    );
    expect(result).toEqual({ status: 'accepted', duplicate: false, idempotencyKey: EXPECTED_KEY });
    expect(store.get(EXPECTED_KEY)?.state).toBe('accepted');
  });

  it('treats duplicate-accepted (idempotent replay) as durable success', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      { submitter: submitter({ outcome: 'accepted', duplicate: true }), evidenceStore: store },
      INPUT,
    );
    expect(result).toEqual({ status: 'accepted', duplicate: true, idempotencyKey: EXPECTED_KEY });
    expect(store.get(EXPECTED_KEY)?.state).toBe('accepted');
  });

  it('preserves local evidence as pending on network failure — work is NOT lost, NOT durable', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: submitter({ outcome: 'transient', reason: 'network', detail: 'offline' }),
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result).toEqual({
      status: 'pending-retry',
      reason: 'network',
      idempotencyKey: EXPECTED_KEY,
    });
    const evidence = store.get(EXPECTED_KEY);
    expect(evidence?.state).toBe('pending');
    expect(evidence?.attempts).toBe(1);
    // the full payload survives for the retry
    expect(evidence?.envelope.payload).toMatchObject({ ticketNo: '12345', quantityBbl: 120 });
  });

  it('preserves evidence on 5xx the same way (retryable, never silently dropped)', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: submitter({ outcome: 'transient', reason: 'server', httpStatus: 503 }),
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result).toMatchObject({ status: 'pending-retry', reason: 'server' });
    expect(store.get(EXPECTED_KEY)?.state).toBe('pending');
  });

  it('refuses to submit without a snapshot hash — drift protection is never disarmed', async () => {
    const store = new VolatileTicketEvidenceStore();
    const sub = submitter({ outcome: 'accepted', duplicate: false });
    for (const snapshotHash of ['', '   ']) {
      const result = await submitFieldTicket(
        { submitter: sub, evidenceStore: store },
        { ...INPUT, snapshotHash },
      );
      expect(result).toEqual({
        status: 'not-submitted',
        reason: 'missing-snapshot-hash',
        idempotencyKey: EXPECTED_KEY,
      });
    }
    expect(sub.calls).toHaveLength(0); // nothing went on the wire
    expect(store.list()).toHaveLength(0); // and no evidence was created for a refused input
  });

  it('preserves full rejection detail (code, detail, http status, timestamp) on the evidence', async () => {
    const store = new VolatileTicketEvidenceStore();
    const now = () => new Date('2026-06-10T15:30:00.000Z');
    await submitFieldTicket(
      {
        submitter: submitter({
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: 422,
          rejectionCode: 'idempotency_mismatch',
          detail: 'key reused with a different payload',
        }),
        evidenceStore: store,
        now,
      },
      INPUT,
    );
    expect(store.get(EXPECTED_KEY)).toMatchObject({
      state: 'needs-review',
      lastRejectionCode: 'idempotency_mismatch',
      lastDetail: 'key reused with a different payload',
      lastHttpStatus: 422,
      lastOutcomeAt: '2026-06-10T15:30:00.000Z',
      updatedAt: '2026-06-10T15:30:00.000Z',
    });
  });

  it('stamps created/updated timestamps and replaces stale failure detail on each new outcome', async () => {
    const store = new VolatileTicketEvidenceStore();
    let tick = 0;
    const now = () => new Date(1_750_000_000_000 + ++tick * 1_000);
    // First attempt: blocked (403). lastRejectionCode marks it user-action-gated.
    await submitFieldTicket(
      {
        submitter: submitter({
          outcome: 'rejected',
          kind: 'blocked',
          httpStatus: 403,
          rejectionCode: 'not_clocked_in',
        }),
        evidenceStore: store,
        now,
      },
      INPUT,
    );
    const afterBlock = store.get(EXPECTED_KEY);
    expect(afterBlock?.lastRejectionCode).toBe('not_clocked_in');
    const createdAt = afterBlock?.createdAt;
    expect(createdAt).toBeDefined();
    // Second attempt (user clocked in, taps retry): transient network failure. The stale
    // rejection code must NOT linger — the item is now retryable by the engine again.
    await submitFieldTicket(
      {
        submitter: submitter({ outcome: 'transient', reason: 'network', detail: 'offline' }),
        evidenceStore: store,
        now,
      },
      INPUT,
    );
    const afterTransient = store.get(EXPECTED_KEY);
    expect(afterTransient?.lastRejectionCode).toBeUndefined();
    expect(afterTransient?.lastTransientReason).toBe('network');
    expect(afterTransient?.lastDetail).toBe('offline');
    expect(afterTransient?.createdAt).toBe(createdAt); // creation time never changes
    expect(afterTransient?.attempts).toBe(2);
    expect(Date.parse(afterTransient!.updatedAt)).toBeGreaterThan(Date.parse(createdAt!));
  });

  it('marks auth failures distinctly so the retry engine can pause for re-auth', async () => {
    const store = new VolatileTicketEvidenceStore();
    await submitFieldTicket(
      { submitter: submitter({ outcome: 'auth-failed', httpStatus: 401 }), evidenceStore: store },
      INPUT,
    );
    expect(store.get(EXPECTED_KEY)).toMatchObject({
      state: 'pending',
      lastTransientReason: 'auth-failed',
      lastHttpStatus: 401,
    });
  });

  it('contains a THROWING submitter: evidence returns to pending (never stranded in-flight)', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: {
          submitFieldTicket: async () => {
            throw new Error('keystore unavailable');
          },
        },
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result).toEqual({
      status: 'pending-retry',
      reason: 'client-error',
      idempotencyKey: EXPECTED_KEY,
    });
    const evidence = store.get(EXPECTED_KEY);
    expect(evidence).toMatchObject({
      state: 'pending', // NOT in-flight — the double-submit guard must not deadlock
      attempts: 1,
      lastTransientReason: 'client-error',
    });
    expect(evidence?.lastDetail).toContain('keystore unavailable');
    // and the operation is retryable with the SAME key afterwards
    const retry = await submitFieldTicket(
      { submitter: submitter({ outcome: 'accepted', duplicate: false }), evidenceStore: store },
      INPUT,
    );
    expect(retry).toMatchObject({ status: 'accepted' });
  });

  it('maps a blocked Hub rejection (403 not clocked in) to a user-visible blocked state, evidence kept pending', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: submitter({
          outcome: 'rejected',
          kind: 'blocked',
          httpStatus: 403,
          rejectionCode: 'not_clocked_in',
          detail: 'no open punch',
        }),
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result).toEqual({
      status: 'blocked',
      rejectionCode: 'not_clocked_in',
      httpStatus: 403,
      detail: 'no open punch',
      idempotencyKey: EXPECTED_KEY,
    });
    const evidence = store.get(EXPECTED_KEY);
    expect(evidence?.state).toBe('pending'); // retryable after the driver clocks in
    expect(evidence?.lastRejectionCode).toBe('not_clocked_in');
  });

  it('maps a 412-style snapshot-drift rejection to needs-review and freezes the evidence', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: submitter({
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: 412,
          rejectionCode: 'stale_version',
        }),
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result).toMatchObject({
      status: 'needs-review',
      rejectionCode: 'stale_version',
      httpStatus: 412,
    });
    const evidence = store.get(EXPECTED_KEY);
    expect(evidence?.state).toBe('needs-review'); // frozen, preserved as evidence
    expect(evidence?.envelope.payload).toMatchObject({ serviceRequestId: 'sr-9' });
  });

  it('maps auth failure to auth-required and keeps the evidence pending', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      { submitter: submitter({ outcome: 'auth-failed', httpStatus: 401 }), evidenceStore: store },
      INPUT,
    );
    expect(result).toEqual({ status: 'auth-required', idempotencyKey: EXPECTED_KEY });
    expect(store.get(EXPECTED_KEY)?.state).toBe('pending');
  });

  it('never reports durable success on any non-accepted outcome', async () => {
    const outcomes: HubSubmitOutcome[] = [
      { outcome: 'transient', reason: 'network' },
      { outcome: 'rejected', kind: 'blocked', httpStatus: 403, rejectionCode: 'forbidden' },
      {
        outcome: 'rejected',
        kind: 'needs-review',
        httpStatus: 412,
        rejectionCode: 'stale_version',
      },
      { outcome: 'auth-failed', httpStatus: 401 },
    ];
    for (const [i, outcome] of outcomes.entries()) {
      const store = new VolatileTicketEvidenceStore();
      const result = await submitFieldTicket(
        { submitter: submitter(outcome), evidenceStore: store },
        { ...INPUT, localSeq: i, opUuid: `op-${i}` },
      );
      expect(result.status).not.toBe('accepted');
      const key = sync.buildIdempotencyKey('devA', i, `op-${i}`);
      expect(store.get(key)?.state).not.toBe('accepted');
      expect(store.get(key)).toBeDefined(); // evidence always preserved
    }
  });

  it('reuses the same idempotency key when retrying the same operation (no duplicate tickets)', async () => {
    const store = new VolatileTicketEvidenceStore();
    const offline = submitter({ outcome: 'transient', reason: 'network' });
    await submitFieldTicket({ submitter: offline, evidenceStore: store }, INPUT);
    const online = submitter({ outcome: 'accepted', duplicate: false });
    await submitFieldTicket({ submitter: online, evidenceStore: store }, INPUT);
    expect(offline.calls[0].idempotencyKey).toBe(online.calls[0].idempotencyKey);
    expect(store.get(EXPECTED_KEY)?.state).toBe('accepted');
    expect(store.list()).toHaveLength(1); // one evidence record, not two
  });

  it('propagates idempotency-key construction errors (bad device id) before any network call', async () => {
    const store = new VolatileTicketEvidenceStore();
    const sub = submitter({ outcome: 'accepted', duplicate: false });
    await expect(
      submitFieldTicket(
        { submitter: sub, evidenceStore: store },
        { ...INPUT, deviceInstanceId: 'bad:device' },
      ),
    ).rejects.toBeInstanceOf(sync.IdempotencyKeyError);
    expect(sub.calls).toHaveLength(0);
  });

  it('a concurrent submit with the same key (double-tap) never fires a second network call', async () => {
    const store = new VolatileTicketEvidenceStore();
    let release!: (outcome: HubSubmitOutcome) => void;
    const gate = new Promise<HubSubmitOutcome>((resolve) => {
      release = resolve;
    });
    let calls = 0;
    const slowSubmitter = {
      submitFieldTicket: async () => {
        calls += 1;
        return gate;
      },
    };
    // First call suspends awaiting Hub; its evidence is in-flight.
    const first = submitFieldTicket({ submitter: slowSubmitter, evidenceStore: store }, INPUT);
    expect(store.get(EXPECTED_KEY)?.state).toBe('in-flight');
    // Second call with the same operation must back off gracefully, not crash or double-submit.
    const second = await submitFieldTicket(
      { submitter: slowSubmitter, evidenceStore: store },
      INPUT,
    );
    expect(second).toEqual({
      status: 'pending-retry',
      reason: 'already-in-flight',
      idempotencyKey: EXPECTED_KEY,
    });
    expect(calls).toBe(1);
    release({ outcome: 'accepted', duplicate: false });
    await expect(first).resolves.toMatchObject({ status: 'accepted' });
    expect(store.get(EXPECTED_KEY)?.state).toBe('accepted');
  });

  it('declares the evidence store volatile — durability honesty until the SQLCipher slice lands', () => {
    expect(new VolatileTicketEvidenceStore().durability).toBe('volatile-memory');
  });
});
