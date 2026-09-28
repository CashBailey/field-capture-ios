/**
 * Accepted-evidence pruning against real SQL. The invariant under proof: pending, in-flight,
 * retry, blocked, failed, needs-review, externally-protected, corrupt, and young-accepted rows
 * are NEVER deleted — only old accepted rows go, and only while the table is over its ADR 002
 * byte budget. Pruned full-engine rows land in the committed-op ledger so dependency planning
 * still resolves them.
 */
import { sync } from '@fieldcapture/contracts';

import {
  migrate,
  pruneAcceptedSyncOutbox,
  pruneAcceptedTicketEvidence,
  SqliteSyncOutboxStore,
  SqliteTicketEvidenceStore,
} from '../src/data';
import type { DurableSyncOutboxItem, TicketEvidence } from '../src/domain';
import { betterSqliteDriver, type TestSqlDriver } from '../test-utils/betterSqliteDriver';

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-06-10T12:00:00.000Z');
const POLICY: sync.EvidencePrunePolicy = { retentionMs: 7 * DAY_MS, maxTotalBytes: 1 };

let db: TestSqlDriver;

beforeEach(() => {
  db = betterSqliteDriver();
  migrate(db);
});

afterEach(() => db.close());

function daysAgo(days: number): string {
  return new Date(NOW.getTime() - days * DAY_MS).toISOString();
}

function evidence(
  key: string,
  state: sync.OutboxItemState,
  outcomeAt: string,
  extra?: Partial<TicketEvidence>,
): TicketEvidence {
  return {
    envelope: {
      opId: key,
      kind: 'command',
      type: 'ticket.submit',
      idempotencyKey: `gtr:devA:1:${key}`,
      localSeq: 1,
      dependsOn: [],
      payload: {
        idempotencyKey: `gtr:devA:1:${key}`,
        serviceRequestId: 'sr-1',
        snapshotHash: 'h',
        ticketNo: 't',
        quantityBbl: 1,
        disposalTicketNo: 'd',
      },
    },
    state,
    attempts: 0,
    createdAt: daysAgo(60),
    updatedAt: outcomeAt,
    lastOutcomeAt: outcomeAt,
    ...extra,
  };
}

describe('pruneAcceptedTicketEvidence', () => {
  it('NEVER prunes unsynced/blocked/frozen work, no matter the byte pressure', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save(evidence('pend', 'pending', daysAgo(90)));
    store.save(
      evidence('retry', 'pending', daysAgo(90), { attempts: 4, lastTransientReason: 'network' }),
    );
    store.save(
      evidence('blocked', 'pending', daysAgo(90), { lastRejectionCode: 'not_clocked_in' }),
    );
    store.save(evidence('inflight', 'in-flight', daysAgo(90)));
    store.save(evidence('rejected', 'rejected', daysAgo(90), { lastRejectionCode: 'bad' }));
    store.save(evidence('review', 'needs-review', daysAgo(90)));

    const outcome = pruneAcceptedTicketEvidence({ db, policy: POLICY, now: () => NOW });

    expect(outcome.prunedIds).toEqual([]);
    expect(outcome.shortfallBytes).toBeGreaterThan(0); // honest: over budget, nothing safe to free
    expect(store.list()).toHaveLength(6);
  });

  it('prunes only old accepted rows; young accepted rows stay (retention window)', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save(evidence('old-accepted', 'accepted', daysAgo(30)));
    store.save(evidence('young-accepted', 'accepted', daysAgo(2)));
    store.save(evidence('pending', 'pending', daysAgo(30)));

    const outcome = pruneAcceptedTicketEvidence({ db, policy: POLICY, now: () => NOW });

    expect(outcome.prunedIds).toEqual(['gtr:devA:1:old-accepted']);
    expect(store.get('gtr:devA:1:old-accepted')).toBeUndefined();
    expect(store.get('gtr:devA:1:young-accepted')).toBeDefined();
    expect(store.get('gtr:devA:1:pending')).toBeDefined();
  });

  it('a generous budget prunes nothing — no pressure, no deletion', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save(evidence('old-accepted', 'accepted', daysAgo(30)));
    const outcome = pruneAcceptedTicketEvidence({
      db,
      policy: { retentionMs: 0, maxTotalBytes: 10_000_000 },
      now: () => NOW,
    });
    expect(outcome.prunedIds).toEqual([]);
    expect(store.get('gtr:devA:1:old-accepted')).toBeDefined();
  });

  it('externally-protected accepted rows survive (e.g. an attachment not yet uploaded+linked)', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save(evidence('with-photo', 'accepted', daysAgo(30)));
    store.save(evidence('plain', 'accepted', daysAgo(30)));

    const outcome = pruneAcceptedTicketEvidence({
      db,
      policy: POLICY,
      now: () => NOW,
      protectedReasons: (id) => (id === 'gtr:devA:1:with-photo' ? ['unlinked-attachment'] : []),
    });

    expect(outcome.prunedIds).toEqual(['gtr:devA:1:plain']);
    expect(store.get('gtr:devA:1:with-photo')).toBeDefined();
  });

  it('a corrupt accepted row is evidence of damage — kept, surfaced, never pruned', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save(evidence('corrupt', 'accepted', daysAgo(30)));
    db.run(
      `UPDATE ticket_evidence SET envelope_json = '{broken' WHERE idempotency_key = 'gtr:devA:1:corrupt'`,
    );

    const outcome = pruneAcceptedTicketEvidence({ db, policy: POLICY, now: () => NOW });

    expect(outcome.prunedIds).toEqual([]);
    expect(store.listCorruptKeys()).toEqual(['gtr:devA:1:corrupt']);
  });
});

describe('pruneAcceptedSyncOutbox', () => {
  function outboxItem(
    opId: string,
    state: sync.OutboxItemState,
    updatedAt: string,
  ): DurableSyncOutboxItem {
    return {
      envelope: {
        opId,
        kind: 'event',
        type: 'test.op',
        idempotencyKey: `gtr:devA:2:${opId}`,
        localSeq: 2,
        dependsOn: [],
        payload: { opId },
      },
      state,
      retryCount: 0,
      createdAt: daysAgo(60),
      updatedAt,
    };
  }

  it('prunes old accepted ops into the ledger; protected states stay put', () => {
    const store = new SqliteSyncOutboxStore(db, 'durable-plain');
    store.save(outboxItem('done-old', 'accepted', daysAgo(30)));
    store.save(outboxItem('done-young', 'accepted', daysAgo(1)));
    store.save(outboxItem('pending', 'pending', daysAgo(30)));
    store.save(outboxItem('inflight', 'in-flight', daysAgo(30)));
    store.save(outboxItem('review', 'needs-review', daysAgo(30)));
    store.save(outboxItem('rejected', 'rejected', daysAgo(30)));

    const outcome = pruneAcceptedSyncOutbox({ db, policy: POLICY, now: () => NOW });

    expect(outcome.prunedIds).toEqual(['done-old']);
    expect(store.get('done-old')).toBeUndefined();
    expect(store.committedOpIds()).toEqual(new Set(['done-old']));
    expect(
      store
        .list()
        .map((i) => i.envelope.opId)
        .sort(),
    ).toEqual(['done-young', 'inflight', 'pending', 'rejected', 'review']);
  });

  it('a dependent of a pruned parent still plans as ready (ledger keeps the commit visible)', () => {
    const store = new SqliteSyncOutboxStore(db, 'durable-plain');
    store.save(outboxItem('parent', 'accepted', daysAgo(30)));
    pruneAcceptedSyncOutbox({ db, policy: POLICY, now: () => NOW });

    const child: DurableSyncOutboxItem = {
      ...outboxItem('child', 'pending', daysAgo(0)),
      envelope: { ...outboxItem('child', 'pending', daysAgo(0)).envelope, dependsOn: ['parent'] },
    };
    store.save(child);

    const plan = sync.planDispatch(store.list(), store.committedOpIds());
    expect(plan.ready.map((i) => i.envelope.opId)).toEqual(['child']);
    expect(plan.blocked).toEqual([]);
  });
});
