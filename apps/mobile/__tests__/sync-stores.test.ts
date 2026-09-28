/**
 * Durable persistence for the full sync engine (migration v4): the generic operation outbox,
 * the down-sync frontier, the committed-op ledger, and the blob/upload records — all against
 * REAL SQL (better-sqlite3 over the same SqlDriver seam production uses).
 */
import { sync } from '@fieldcapture/contracts';

import { migrate, currentSchemaVersion } from '../src/data';
import { SqliteBlobUploadStore } from '../src/data/SqliteBlobUploadStore';
import { SqliteSyncFrontierStore } from '../src/data/SqliteSyncFrontierStore';
import { SqliteSyncOutboxStore } from '../src/data/SqliteSyncOutboxStore';
import type { BlobUploadRecord, DurableSyncOutboxItem } from '../src/domain';
import { betterSqliteDriver, type TestSqlDriver } from '../test-utils/betterSqliteDriver';

let db: TestSqlDriver;

beforeEach(() => {
  db = betterSqliteDriver();
  migrate(db);
});

afterEach(() => db.close());

function item(
  opId: string,
  localSeq: number,
  overrides?: Partial<DurableSyncOutboxItem>,
): DurableSyncOutboxItem {
  return {
    envelope: {
      opId,
      kind: 'event',
      type: 'test.op',
      idempotencyKey: `gtr:devA:${localSeq}:${opId}`,
      localSeq,
      dependsOn: [],
      payload: { opId },
    },
    state: 'pending',
    retryCount: 0,
    createdAt: '2026-06-10T10:00:00.000Z',
    updatedAt: '2026-06-10T10:00:00.000Z',
    ...overrides,
  };
}

describe('migration v4+', () => {
  it('brings a fresh database to the latest schema version', () => {
    expect(currentSchemaVersion(db)).toBeGreaterThanOrEqual(4);
  });

  it('upgrades a v3 database in place without touching existing evidence', () => {
    const old = betterSqliteDriver();
    // Apply only v1..v3, seed a row, then run the full migrate().
    old.transaction(() => {
      for (let v = 0; v < 3; v++) {
        const { MIGRATIONS } = jest.requireActual<typeof import('../src/data')>('../src/data');
        old.exec(MIGRATIONS[v]!);
      }
      old.exec('PRAGMA user_version = 3');
    });
    old.run(
      `INSERT INTO ticket_evidence (idempotency_key, envelope_json, state, attempts, created_at, updated_at)
       VALUES ('gtr:d:1:u', '{"opId":"u"}', 'pending', 0, '2026-01-01', '2026-01-01')`,
    );
    migrate(old);
    expect(currentSchemaVersion(old)).toBeGreaterThanOrEqual(4);
    expect(old.first<{ n: number }>('SELECT COUNT(*) AS n FROM ticket_evidence')?.n).toBe(1);
    expect(old.first('SELECT 1 AS ok FROM sync_outbox LIMIT 1')).toBeNull(); // table exists, empty
    old.close();
  });
});

describe('SqliteSyncOutboxStore', () => {
  it('round-trips every field including committed token and backoff stamp', () => {
    const store = new SqliteSyncOutboxStore(db, 'durable-plain');
    store.save(
      item('op-1', 1, {
        state: 'accepted',
        retryCount: 3,
        committedToken: { authorityEpoch: 1, commitSeq: 42 },
        rejectionCode: 'was_cleared',
        lastError: 'earlier transient',
        nextAttemptAtMs: 123456,
      }),
    );
    expect(store.get('op-1')).toEqual(
      item('op-1', 1, {
        state: 'accepted',
        retryCount: 3,
        committedToken: { authorityEpoch: 1, commitSeq: 42 },
        rejectionCode: 'was_cleared',
        lastError: 'earlier transient',
        nextAttemptAtMs: 123456,
      }),
    );
  });

  it('lists by state and surfaces corrupt envelopes instead of hiding them', () => {
    const store = new SqliteSyncOutboxStore(db, 'durable-plain');
    store.save(item('op-1', 1));
    store.save(item('op-2', 2, { state: 'accepted' }));
    db.run(`UPDATE sync_outbox SET envelope_json = '{broken' WHERE op_id = 'op-1'`);

    expect(store.listByState('accepted').map((i) => i.envelope.opId)).toEqual(['op-2']);
    expect(store.list().map((i) => i.envelope.opId)).toEqual(['op-2']);
    expect(store.listCorruptOpIds()).toEqual(['op-1']);
  });

  it('pruneAcceptedToLedger moves accepted rows into committed_ops; refuses everything else', () => {
    const store = new SqliteSyncOutboxStore(db, 'durable-plain');
    store.save(item('op-1', 1, { state: 'accepted' }));
    store.save(item('op-2', 2, { state: 'pending' }));

    store.pruneAcceptedToLedger('op-1', '2026-06-10T12:00:00Z');
    expect(store.get('op-1')).toBeUndefined();
    expect(store.committedOpIds()).toEqual(new Set(['op-1']));

    expect(() => store.pruneAcceptedToLedger('op-2', '2026-06-10T12:00:00Z')).toThrow(
      /only 'accepted' may be pruned/,
    );
    expect(store.get('op-2')).toBeDefined();
  });
});

describe('SqliteSyncFrontierStore', () => {
  it('starts undefined, persists, and overwrites the single frontier row', () => {
    const store = new SqliteSyncFrontierStore(db, 'durable-plain');
    expect(store.get()).toBeUndefined();
    store.set({ authorityEpoch: 1, commitSeq: 10 });
    expect(store.get()).toEqual({ authorityEpoch: 1, commitSeq: 10 });
    store.set({ authorityEpoch: 2, commitSeq: 0 });
    expect(store.get()).toEqual({ authorityEpoch: 2, commitSeq: 0 });
  });
});

describe('SqliteBlobUploadStore', () => {
  const RECORD: BlobUploadRecord = {
    blobId: 'blob-1',
    sha256: 'aa11',
    byteLength: 10,
    mimeType: 'image/jpeg',
    localUri: 'file:///photos/blob-1.jpg',
    attachmentId: 'att-1',
    parentType: 'field-ticket',
    parentId: 'ft-1',
    attachmentKind: 'field-ticket-photo',
    state: 'uploading',
    uploadConfirmed: false,
    linkConfirmed: false,
    bytesAcked: 4,
    sessionIdempotencyKey: 'gtr:devA:9:up-1',
    parentOpId: 'op-parent',
    uploadSessionId: 'sess-1',
    uploadUrl: 'http://hub.test/uploads/blob-1',
    linkOpId: 'op-link',
    createdAt: '2026-06-10T10:00:00.000Z',
    updatedAt: '2026-06-10T10:05:00.000Z',
  };

  it('round-trips the full record including resume point and confirmations', () => {
    const store = new SqliteBlobUploadStore(db, 'durable-plain');
    store.save(RECORD);
    expect(store.get('blob-1')).toEqual(RECORD);

    store.save({
      ...RECORD,
      state: 'linked',
      uploadConfirmed: true,
      linkConfirmed: true,
      purgedAt: '2026-06-11T00:00:00Z',
    });
    const updated = store.get('blob-1');
    expect(updated).toMatchObject({ state: 'linked', uploadConfirmed: true, linkConfirmed: true });
    expect(sync.isBlobPurgeable(updated as BlobUploadRecord)).toBe(true);
  });

  it('looks up by attachmentId and lists by state', () => {
    const store = new SqliteBlobUploadStore(db, 'durable-plain');
    store.save(RECORD);
    store.save({ ...RECORD, blobId: 'blob-2', attachmentId: 'att-2', state: 'local-only' });
    expect(store.getByAttachmentId('att-2')?.blobId).toBe('blob-2');
    expect(store.listByState('uploading').map((r) => r.blobId)).toEqual(['blob-1']);
  });
});
