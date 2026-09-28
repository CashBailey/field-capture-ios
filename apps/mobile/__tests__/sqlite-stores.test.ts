/**
 * Durable-store slice: the spec's core demand is that unsynced work SURVIVES RESTART. These
 * tests run the real store logic against real SQL (better-sqlite3 behind the same SqlDriver
 * seam as native SQLite), including genuine close-and-reopen restart cycles on a file database.
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DeviceIdentity,
  MIGRATIONS,
  SqliteAssignmentStore,
  SqliteFieldTicketDraftStore,
  SqliteOfflinePolicyStore,
  SqliteDiagnosticLogStore,
  SqliteLocationEvidenceStore,
  SqliteReceiptDraftStore,
  SqliteSyncChangeLedger,
  SqliteTicketEvidenceStore,
  currentSchemaVersion,
  migrate,
} from '../src/data';
import {
  evaluateOfflinePolicy,
  submitFieldTicket,
  type FieldTicketInput,
  type HubAssignment,
} from '../src/domain';
import { betterSqliteDriver, type TestSqlDriver } from '../test-utils/betterSqliteDriver';

const ASSIGNMENTS: HubAssignment[] = [
  { serviceRequestId: 'sr-1', snapshotHash: 'h1', snapshot: { srId: 'sr-1', site: 'pad-3' } },
  { serviceRequestId: 'sr-2', snapshotHash: 'h2', snapshot: null },
];

const INPUT: FieldTicketInput = {
  serviceRequestId: 'sr-1',
  snapshotHash: 'h1',
  ticketNo: 'T-77',
  quantityBbl: 80,
  disposalTicketNo: 'D-9',
  deviceInstanceId: 'devA',
  localSeq: 0,
  opUuid: 'op-1',
};

describe('migrations', () => {
  it('brings a fresh database to the latest schema and is idempotent', () => {
    const db = betterSqliteDriver();
    expect(currentSchemaVersion(db)).toBe(0);
    migrate(db);
    expect(currentSchemaVersion(db)).toBe(MIGRATIONS.length);
    migrate(db); // re-running must be a no-op, not a crash
    expect(currentSchemaVersion(db)).toBe(MIGRATIONS.length);
    db.close();
  });
});

describe('SqliteAssignmentStore', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  it('stores assignments with snapshots + hashes and reads them back verbatim', () => {
    const store = new SqliteAssignmentStore(db, 'durable-plain');
    store.putAssignments(ASSIGNMENTS);
    expect(store.listAssignments()).toEqual(ASSIGNMENTS);
    expect(store.getSnapshotHash('sr-1')).toBe('h1');
    expect(store.getSnapshotHash('sr-unknown')).toBeUndefined();
  });

  it('persists rich assignment fields plus latest server version in SQLite', () => {
    const rich: HubAssignment = {
      serviceRequestId: 'sr-rich',
      snapshotHash: 'hash-rich',
      latestServerVersion: 'hash-rich',
      snapshot: { srId: 'sr-rich', snapshotCustomer: 'legacy' },
      details: {
        requestNo: '2026-000042',
        status: 'in_progress',
        customer: { id: 'cust-1', name: 'ACME Oil' },
        lease: { id: 'lease-1', name: 'North Lease' },
        wells: [{ id: 'well-12', leaseId: 'lease-1', name: 'Well 12H' }],
        material: 'Produced water',
        disposalSite: { id: 'disp-1', name: 'SWD 8' },
        vehicle: { id: 'truck-7', name: 'Truck 7' },
        trailer: { id: 'trl-3', name: 'Trailer 3' },
        jobType: { id: 'jt-1', name: 'water-haul' },
        coordinates: {
          primary: { lat: 31.5, lon: -102.1 },
          wells: [{ lat: 31.5, lon: -102.1, wellId: 'well-12' }],
        },
        geofenceHints: { required: true, radiusM: 250 },
        workflowRequirements: {
          clockInRequired: true,
          requiredSteps: ['pre_trip_dvir', 'jha'],
        },
      },
    };
    const store = new SqliteAssignmentStore(db, 'durable-plain');
    store.putAssignments([rich]);

    expect(store.listAssignments()).toEqual([rich]);
    expect(
      db.first<{ latest_server_version: string | null; rich_json: string }>(
        'SELECT latest_server_version, rich_json FROM assignments WHERE service_request_id = ?',
        ['sr-rich'],
      ),
    ).toEqual({
      latest_server_version: 'hash-rich',
      rich_json: JSON.stringify(rich.details),
    });
  });

  it('wholesale-replaces the set on each pull (Hub is the authority on assignment)', () => {
    const store = new SqliteAssignmentStore(db, 'durable-plain');
    store.putAssignments(ASSIGNMENTS);
    store.putAssignments([ASSIGNMENTS[1]!]);
    expect(store.listAssignments().map((a) => a.serviceRequestId)).toEqual(['sr-2']);
    expect(store.getSnapshotHash('sr-1')).toBeUndefined();
  });

  it('declares the durability it was constructed with — never volatile', () => {
    expect(new SqliteAssignmentStore(db, 'durable-encrypted').durability).toBe('durable-encrypted');
  });

  it('tolerates a duplicated SR in one Hub payload (last wins) instead of aborting the refresh', () => {
    const store = new SqliteAssignmentStore(db, 'durable-plain');
    store.putAssignments([
      { serviceRequestId: 'sr-1', snapshotHash: 'h-old', snapshot: null },
      { serviceRequestId: 'sr-1', snapshotHash: 'h-new', snapshot: null },
    ]);
    expect(store.listAssignments()).toHaveLength(1);
    expect(store.getSnapshotHash('sr-1')).toBe('h-new');
  });
});

describe('SqliteOfflinePolicyStore (the offline clock cannot be reset)', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  it('starts with no recorded contact', () => {
    expect(new SqliteOfflinePolicyStore(db, 'durable-plain').getState()).toEqual({
      lastHubContactAtMs: null,
    });
  });

  it('records Hub contact and a Hub-seeded window, round-tripping both', () => {
    const store = new SqliteOfflinePolicyStore(db, 'durable-plain');
    store.recordHubContact(1_000);
    store.setWindowHours(4);
    expect(store.getState()).toEqual({ lastHubContactAtMs: 1_000, windowHours: 4 });
  });

  it('recordHubContact is monotonic-forward — an OLDER timestamp never wins', () => {
    const store = new SqliteOfflinePolicyStore(db, 'durable-plain');
    store.recordHubContact(5_000);
    store.recordHubContact(2_000); // stale/clock-skewed earlier value: ignored
    expect(store.getState().lastHubContactAtMs).toBe(5_000);
    store.recordHubContact(9_000); // a genuinely later contact advances it
    expect(store.getState().lastHubContactAtMs).toBe(9_000);
  });

  it('the durable timestamp survives close-and-reopen — a restart cannot reset the 24h clock', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fieldcapture-offline-'));
    try {
      const file = join(dir, 'offline.db');
      const HOUR = 60 * 60 * 1000;
      const contactAt = 100 * HOUR;

      let fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      new SqliteOfflinePolicyStore(fileDb, 'durable-plain').recordHubContact(contactAt);
      fileDb.close();

      // Restart, then evaluate the policy 30h later: still over-limit, NOT reset to "online".
      fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      const reopened = new SqliteOfflinePolicyStore(fileDb, 'durable-plain');
      expect(reopened.getState().lastHubContactAtMs).toBe(contactAt);
      const policy = evaluateOfflinePolicy({
        lastHubContactAtMs: reopened.getState().lastHubContactAtMs,
        nowMs: contactAt + 30 * HOUR,
      });
      expect(policy.state).toBe('offline-over-limit');
      fileDb.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('SqliteReceiptDraftStore (local receipts preserved until submit/delete)', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  const receipt = {
    id: 'rcpt-1',
    serviceRequestId: 'sr-1',
    receiptType: 'disposal' as const,
    vendor: 'SWD 8',
    receiptNo: 'R-100',
    amount: 42.5,
    notes: 'half load',
    ticketDraftId: 'draft-9',
    createdAt: '2026-06-15T10:00:00.000Z',
    updatedAt: '2026-06-15T10:00:00.000Z',
  };

  it('round-trips a receipt draft including the optional ticket link', () => {
    const store = new SqliteReceiptDraftStore(db, 'durable-plain');
    store.save(receipt);
    expect(store.get('rcpt-1')).toEqual(receipt);
    expect(store.list()).toEqual([receipt]);
  });

  it('omits ticketDraftId when there is no linked ticket', () => {
    const store = new SqliteReceiptDraftStore(db, 'durable-plain');
    const noLink = { ...receipt, id: 'rcpt-2' };
    delete (noLink as Partial<typeof noLink>).ticketDraftId;
    store.save(noLink);
    expect(store.get('rcpt-2')).toEqual(noLink);
    expect('ticketDraftId' in store.get('rcpt-2')!).toBe(false);
  });

  it('upserts on id and deletes', () => {
    const store = new SqliteReceiptDraftStore(db, 'durable-plain');
    store.save(receipt);
    store.save({ ...receipt, amount: 99 });
    expect(store.list()).toHaveLength(1);
    expect(store.get('rcpt-1')?.amount).toBe(99);
    store.delete('rcpt-1');
    expect(store.get('rcpt-1')).toBeUndefined();
  });

  it('rejects an out-of-domain receipt type at the schema boundary', () => {
    const store = new SqliteReceiptDraftStore(db, 'durable-plain');
    expect(() => store.save({ ...receipt, receiptType: 'bribe' as never })).toThrow();
  });

  it('survives close-and-reopen (a receipt is never silently lost)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fieldcapture-receipt-'));
    try {
      const file = join(dir, 'receipts.db');
      let fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      new SqliteReceiptDraftStore(fileDb, 'durable-plain').save(receipt);
      fileDb.close();

      fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      expect(new SqliteReceiptDraftStore(fileDb, 'durable-plain').get('rcpt-1')).toEqual(receipt);
      fileDb.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('SqliteSyncChangeLedger (idempotent down-sync ledger)', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  const change = {
    authorityEpoch: 1,
    commitSeq: 1,
    opId: 'op-1',
    entityType: 'sync_operation',
    entityId: 'sr-1',
    changeType: 'field.note',
    payload: { note: 'hi' },
    createdAt: '2026-06-15T02:56:55.549668',
  };

  it('records a change and round-trips it (payload JSON preserved)', () => {
    const ledger = new SqliteSyncChangeLedger(db, 'durable-plain');
    expect(ledger.record(change)).toBe(true);
    expect(ledger.has(1, 1)).toBe(true);
    expect(ledger.count()).toBe(1);
    expect(ledger.list()).toEqual([change]);
  });

  it('is idempotent on (authority_epoch, commit_seq) — re-record is a no-op', () => {
    const ledger = new SqliteSyncChangeLedger(db, 'durable-plain');
    expect(ledger.record(change)).toBe(true);
    expect(ledger.record({ ...change, payload: { note: 'replay' } })).toBe(false);
    expect(ledger.count()).toBe(1);
    expect(ledger.list()[0]?.payload).toEqual({ note: 'hi' }); // first write wins
  });

  it('recorded changes survive close-and-reopen', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fieldcapture-changes-'));
    try {
      const file = join(dir, 'changes.db');
      let fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      new SqliteSyncChangeLedger(fileDb, 'durable-plain').record(change);
      fileDb.close();

      fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      expect(new SqliteSyncChangeLedger(fileDb, 'durable-plain').has(1, 1)).toBe(true);
      fileDb.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('SqliteLocationEvidenceStore (validation-only, append-only, non-evictable)', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  const withGps = {
    id: 'loc-1',
    serviceRequestId: 'sr-1',
    placeKind: 'well-site' as const,
    evidenceType: 'arrival',
    gps: { lat: 31.5, lon: -102.1, accuracyM: 5, timestampMs: 1_750_000_000_000 },
    notes: 'at the pad',
    state: 'verified' as const,
    createdAt: '2026-06-15T03:00:00.000Z',
  };
  const manual = {
    id: 'loc-2',
    serviceRequestId: 'sr-1',
    placeKind: 'other' as const,
    evidenceType: 'unknown-well',
    state: 'manual-only' as const,
    createdAt: '2026-06-15T03:05:00.000Z',
  };

  it('round-trips GPS-bearing and manual (no-GPS) evidence', () => {
    const store = new SqliteLocationEvidenceStore(db, 'durable-plain');
    store.record(withGps);
    store.record(manual);
    expect(store.get('loc-1')).toEqual(withGps);
    expect(store.get('loc-2')).toEqual(manual); // no gps/notes keys materialized
    expect('gps' in store.get('loc-2')!).toBe(false);
    expect(store.listByServiceRequest('sr-1').map((e) => e.id)).toEqual(['loc-1', 'loc-2']);
  });

  it('rejects an out-of-domain state / placeKind at the schema boundary', () => {
    const store = new SqliteLocationEvidenceStore(db, 'durable-plain');
    expect(() => store.record({ ...withGps, id: 'x', state: 'made-up' as never })).toThrow();
    expect(() => store.record({ ...withGps, id: 'y', placeKind: 'moon' as never })).toThrow();
  });

  it('is append-only: a duplicate evidence id cannot overwrite the original row', () => {
    const store = new SqliteLocationEvidenceStore(db, 'durable-plain');
    store.record(withGps);

    expect(() => store.record({ ...withGps, state: 'rejected' })).toThrow();
    expect(store.get('loc-1')).toEqual(withGps);
  });

  it('survives close-and-reopen (location evidence is never silently lost)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fieldcapture-loc-'));
    try {
      const file = join(dir, 'loc.db');
      let fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      new SqliteLocationEvidenceStore(fileDb, 'durable-plain').record(withGps);
      fileDb.close();

      fileDb = betterSqliteDriver(file);
      migrate(fileDb);
      expect(new SqliteLocationEvidenceStore(fileDb, 'durable-plain').get('loc-1')).toEqual(
        withGps,
      );
      fileDb.close();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('SqliteDiagnosticLogStore', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  it('records logs (context round-trips) and returns the most recent first', () => {
    const store = new SqliteDiagnosticLogStore(db, 'durable-plain');
    store.record({
      id: 'log-1',
      level: 'info',
      message: 'boot ok',
      createdAt: '2026-06-15T03:00:00.000Z',
    });
    store.record({
      id: 'log-2',
      level: 'error',
      message: 'submit failed',
      context: { httpStatus: 409, code: 'workflow_blocked' },
      createdAt: '2026-06-15T03:01:00.000Z',
    });
    expect(store.count()).toBe(2);
    const recent = store.recent(10);
    expect(recent.map((l) => l.id)).toEqual(['log-2', 'log-1']);
    expect(recent[0]).toMatchObject({
      level: 'error',
      context: { httpStatus: 409, code: 'workflow_blocked' },
    });
  });

  it('rejects an out-of-domain level at the schema boundary', () => {
    const store = new SqliteDiagnosticLogStore(db, 'durable-plain');
    expect(() =>
      store.record({
        id: 'log-x',
        level: 'debug' as never,
        message: 'nope',
        createdAt: '2026-06-15T03:00:00.000Z',
      }),
    ).toThrow();
  });
});

describe('SqliteTicketEvidenceStore (the durable outbox)', () => {
  let db: TestSqlDriver;
  beforeEach(() => {
    db = betterSqliteDriver();
    migrate(db);
  });
  afterEach(() => db.close());

  it('round-trips full evidence including every rejection/retry field', async () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    await submitFieldTicket(
      {
        submitter: {
          submitFieldTicket: async () => ({
            outcome: 'rejected' as const,
            kind: 'needs-review' as const,
            httpStatus: 412,
            rejectionCode: 'stale_version',
            detail: 'snapshot drifted',
          }),
        },
        evidenceStore: store,
        now: () => new Date('2026-06-10T16:00:00.000Z'),
      },
      INPUT,
    );
    const evidence = store.get('gtr:devA:0:op-1');
    expect(evidence).toMatchObject({
      state: 'needs-review',
      attempts: 0,
      lastRejectionCode: 'stale_version',
      lastDetail: 'snapshot drifted',
      lastHttpStatus: 412,
      lastOutcomeAt: '2026-06-10T16:00:00.000Z',
      createdAt: '2026-06-10T16:00:00.000Z',
    });
    expect(evidence?.envelope.payload).toEqual({
      idempotencyKey: 'gtr:devA:0:op-1',
      serviceRequestId: 'sr-1',
      snapshotHash: 'h1',
      ticketNo: 'T-77',
      quantityBbl: 80,
      disposalTicketNo: 'D-9',
    });
    expect(store.listByState('needs-review')).toHaveLength(1);
    expect(store.listByState('pending')).toHaveLength(0);
  });

  it('persists an explicit outbox row shape separate from UI state', async () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    await submitFieldTicket(
      {
        submitter: {
          submitFieldTicket: async () => ({
            outcome: 'transient' as const,
            reason: 'network' as const,
            detail: 'offline',
          }),
        },
        evidenceStore: store,
        now: () => new Date('2026-06-10T16:04:00.000Z'),
      },
      INPUT,
    );

    const row = db.first<{
      id: string;
      type: string;
      payload_json: string;
      idempotency_key: string;
      outbox_status: string;
      attempts: number;
      last_detail: string | null;
    }>(
      `SELECT id, type, payload_json, idempotency_key, outbox_status, attempts, last_detail
       FROM ticket_evidence WHERE idempotency_key = ?`,
      ['gtr:devA:0:op-1'],
    );
    expect(row).toMatchObject({
      id: 'gtr:devA:0:op-1',
      type: 'ticket.submit',
      idempotency_key: 'gtr:devA:0:op-1',
      outbox_status: 'retry',
      attempts: 1,
      last_detail: 'offline',
    });
    expect(JSON.parse(row!.payload_json)).toMatchObject({
      idempotencyKey: 'gtr:devA:0:op-1',
      serviceRequestId: 'sr-1',
      snapshotHash: 'h1',
    });
    expect(store.listOutboxItems()).toEqual([
      expect.objectContaining({
        id: 'gtr:devA:0:op-1',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:devA:0:op-1',
        status: 'retry',
        attempts: 1,
        lastError: 'offline',
        createdAt: '2026-06-10T16:04:00.000Z',
        updatedAt: '2026-06-10T16:04:00.000Z',
      }),
    ]);
  });

  it('projects a blocked 403/409 row as blocked, not failed or retry', async () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    await submitFieldTicket(
      {
        submitter: {
          submitFieldTicket: async () => ({
            outcome: 'rejected' as const,
            kind: 'blocked' as const,
            httpStatus: 403,
            rejectionCode: 'not_clocked_in',
            detail: 'no open TimeClock punch',
          }),
        },
        evidenceStore: store,
        now: () => new Date('2026-06-10T16:05:00.000Z'),
      },
      INPUT,
    );

    const row = db.first<{ outbox_status: string; last_rejection_code: string | null }>(
      `SELECT outbox_status, last_rejection_code
       FROM ticket_evidence WHERE idempotency_key = ?`,
      ['gtr:devA:0:op-1'],
    );
    expect(row).toEqual({ outbox_status: 'blocked', last_rejection_code: 'not_clocked_in' });
    expect(store.listOutboxItems()).toEqual([
      expect.objectContaining({
        idempotencyKey: 'gtr:devA:0:op-1',
        status: 'blocked',
        lastError: 'no open TimeClock punch',
        lastHttpStatus: 403,
        lastRejectionCode: 'not_clocked_in',
      }),
    ]);
  });

  it('omits optional fields cleanly when they were never set', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save({
      envelope: {
        opId: 'op-2',
        kind: 'command',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:devA:1:op-2',
        localSeq: 1,
        dependsOn: [],
        payload: {
          idempotencyKey: 'gtr:devA:1:op-2',
          serviceRequestId: 'sr-2',
          snapshotHash: 'h2',
          ticketNo: 'T-78',
          quantityBbl: 10,
          disposalTicketNo: 'D-10',
        },
      },
      state: 'pending',
      attempts: 0,
      createdAt: '2026-06-10T16:01:00.000Z',
      updatedAt: '2026-06-10T16:01:00.000Z',
    });
    const evidence = store.get('gtr:devA:1:op-2');
    expect(evidence).toBeDefined();
    expect(evidence).not.toHaveProperty('lastRejectionCode');
    expect(evidence).not.toHaveProperty('lastDetail');
    expect(evidence).not.toHaveProperty('nextAttemptAtMs');
  });

  it('quarantines a corrupt envelope row instead of taking the whole store down', () => {
    const store = new SqliteTicketEvidenceStore(db, 'durable-plain');
    store.save({
      envelope: {
        opId: 'op-ok',
        kind: 'command',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:devA:3:op-ok',
        localSeq: 3,
        dependsOn: [],
        payload: {
          idempotencyKey: 'gtr:devA:3:op-ok',
          serviceRequestId: 'sr-1',
          snapshotHash: 'h1',
          ticketNo: 'T-ok',
          quantityBbl: 1,
          disposalTicketNo: 'D-ok',
        },
      },
      state: 'pending',
      attempts: 0,
      createdAt: '2026-06-10T16:02:00.000Z',
      updatedAt: '2026-06-10T16:02:00.000Z',
    });
    // out-of-band corruption of a second row
    db.run(
      `INSERT INTO ticket_evidence (idempotency_key, envelope_json, state, attempts, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [
        'gtr:devA:4:op-bad',
        '{corrupt!!',
        'pending',
        0,
        '2026-06-10T16:03:00.000Z',
        '2026-06-10T16:03:00.000Z',
      ],
    );
    // healthy rows keep flowing — boot recovery and the retry engine stay alive
    expect(store.list().map((e) => e.envelope.opId)).toEqual(['op-ok']);
    expect(store.listByState('pending')).toHaveLength(1);
    expect(store.get('gtr:devA:4:op-bad')).toBeUndefined();
    // and the damage is visible, not hidden
    expect(store.listCorruptKeys()).toEqual(['gtr:devA:4:op-bad']);
  });
});

describe('DeviceIdentity (durable write identity)', () => {
  it('creates the device id once and allocates strictly monotonic local_seq values', () => {
    const db = betterSqliteDriver();
    migrate(db);
    const identity = new DeviceIdentity(db);
    const id = identity.ensureDeviceInstanceId(() => 'uuid-1');
    expect(id).toBe('uuid-1');
    // second ensure must NOT regenerate
    expect(identity.ensureDeviceInstanceId(() => 'uuid-2')).toBe('uuid-1');
    expect(identity.allocateLocalSeq()).toBe(0);
    expect(identity.allocateLocalSeq()).toBe(1);
    expect(identity.allocateLocalSeq()).toBe(2);
    db.close();
  });

  it('refuses a generated id that would corrupt idempotency keys', () => {
    const db = betterSqliteDriver();
    migrate(db);
    expect(() => new DeviceIdentity(db).ensureDeviceInstanceId(() => 'bad:uuid')).toThrow(
      /unusable/,
    );
    db.close();
  });
});

describe('SqliteFieldTicketDraftStore', () => {
  it('persists field ticket drafts with timestamps until explicitly deleted', () => {
    const db = betterSqliteDriver();
    migrate(db);
    const store = new SqliteFieldTicketDraftStore(db, 'durable-plain');
    store.save({
      id: 'draft-1',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-77',
      quantityBbl: 80,
      disposalTicketNo: 'D-9',
      createdAt: '2026-06-10T16:06:00.000Z',
      updatedAt: '2026-06-10T16:06:00.000Z',
    });
    expect(store.get('draft-1')).toEqual({
      id: 'draft-1',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-77',
      quantityBbl: 80,
      disposalTicketNo: 'D-9',
      createdAt: '2026-06-10T16:06:00.000Z',
      updatedAt: '2026-06-10T16:06:00.000Z',
    });
    expect(store.list().map((draft) => draft.id)).toEqual(['draft-1']);
    store.delete('draft-1');
    expect(store.get('draft-1')).toBeUndefined();
    db.close();
  });

  it('round-trips the optional hauling fields + capture method (v10), omitting absent ones', () => {
    const db = betterSqliteDriver();
    migrate(db);
    const store = new SqliteFieldTicketDraftStore(db, 'durable-plain');
    const full = {
      id: 'draft-2',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-88',
      quantityBbl: 120,
      disposalTicketNo: 'D-2',
      truck: 'Truck 7',
      trailer: 'Trailer 3',
      driver: 'A. Rivera',
      notes: 'gate code 4821',
      captureMethod: 'paper' as const,
      createdAt: '2026-06-15T10:00:00.000Z',
      updatedAt: '2026-06-15T10:00:00.000Z',
    };
    store.save(full);
    expect(store.get('draft-2')).toEqual(full);

    // A draft with no hauling detail must not grow null keys on read.
    store.save({
      id: 'draft-3',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-1',
      quantityBbl: 10,
      disposalTicketNo: 'D-1',
      createdAt: '2026-06-15T10:00:00.000Z',
      updatedAt: '2026-06-15T10:00:00.000Z',
    });
    const minimal = store.get('draft-3')!;
    expect('truck' in minimal).toBe(false);
    expect('captureMethod' in minimal).toBe(false);
    db.close();
  });
});

describe('restart survival (the point of the slice)', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'fieldcapture-db-'));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('unsynced evidence, assignments, and write identity all survive close-and-reopen', async () => {
    const file = join(dir, 'field.db');

    // --- session 1: pull assignments, submit fails transiently, app dies ---
    let db = betterSqliteDriver(file);
    migrate(db);
    new SqliteAssignmentStore(db, 'durable-plain').putAssignments(ASSIGNMENTS);
    const identity1 = new DeviceIdentity(db);
    identity1.ensureDeviceInstanceId(() => 'dev-uuid');
    expect(identity1.allocateLocalSeq()).toBe(0);
    await submitFieldTicket(
      {
        submitter: {
          submitFieldTicket: async () => ({
            outcome: 'transient' as const,
            reason: 'network' as const,
            detail: 'offline',
          }),
        },
        evidenceStore: new SqliteTicketEvidenceStore(db, 'durable-plain'),
      },
      { ...INPUT, deviceInstanceId: 'dev-uuid', localSeq: 0 },
    );
    db.close();

    // --- session 2: restart ---
    db = betterSqliteDriver(file);
    migrate(db); // no-op on an up-to-date schema
    const assignments = new SqliteAssignmentStore(db, 'durable-plain');
    expect(assignments.getSnapshotHash('sr-1')).toBe('h1');
    const evidence = new SqliteTicketEvidenceStore(db, 'durable-plain');
    const pending = evidence.listByState('pending');
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({
      state: 'pending',
      attempts: 1,
      lastTransientReason: 'network',
      lastDetail: 'offline',
    });
    expect(pending[0]?.envelope.payload).toMatchObject({ ticketNo: 'T-77', quantityBbl: 80 });
    // identity survives: same device id, sequence continues (no reuse)
    const identity2 = new DeviceIdentity(db);
    expect(identity2.ensureDeviceInstanceId(() => 'MUST-NOT-REGENERATE')).toBe('dev-uuid');
    expect(identity2.allocateLocalSeq()).toBe(1);
    db.close();
  });

  it('field ticket drafts survive close-and-reopen until submitted or explicitly deleted', () => {
    const file = join(dir, 'drafts.db');

    let db = betterSqliteDriver(file);
    migrate(db);
    new SqliteFieldTicketDraftStore(db, 'durable-plain').save({
      id: 'draft-restart-1',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-88',
      quantityBbl: 90,
      disposalTicketNo: 'D-11',
      createdAt: '2026-06-10T16:07:00.000Z',
      updatedAt: '2026-06-10T16:08:00.000Z',
    });
    db.close();

    db = betterSqliteDriver(file);
    migrate(db);
    const drafts = new SqliteFieldTicketDraftStore(db, 'durable-plain');
    expect(drafts.list()).toEqual([
      {
        id: 'draft-restart-1',
        serviceRequestId: 'sr-1',
        ticketNo: 'T-88',
        quantityBbl: 90,
        disposalTicketNo: 'D-11',
        createdAt: '2026-06-10T16:07:00.000Z',
        updatedAt: '2026-06-10T16:08:00.000Z',
      },
    ]);
    db.close();
  });
});
