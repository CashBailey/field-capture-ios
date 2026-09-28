/**
 * Down-sync applied-changes ledger (ADR-004 §4g). The apply MUST be idempotent and must never
 * silently drop a change — a no-op apply would advance the frontier past authoritative changes.
 */
import {
  parseSyncChange,
  recordChanges,
  VolatileSyncChangeLedger,
  type SyncChangeRow,
} from '../src/domain';

// The verbatim real-Hub change shape (from GET /sync/changes against local opshub).
const REAL_CHANGE = {
  authority_epoch: 1,
  commit_seq: 1,
  op_id: 'op-vtest-1',
  entity_type: 'sync_operation',
  entity_id: '2fa77824-e9c0-48d8-b707-c9482084cee9',
  change_type: 'field.note',
  payload: { service_request_id: '2fa77824-e9c0-48d8-b707-c9482084cee9', note: 'v2 verification' },
  created_at: '2026-06-15T02:56:55.549668',
};

describe('parseSyncChange', () => {
  it('normalizes the real Hub change row', () => {
    expect(parseSyncChange(REAL_CHANGE)).toEqual<SyncChangeRow>({
      authorityEpoch: 1,
      commitSeq: 1,
      opId: 'op-vtest-1',
      entityType: 'sync_operation',
      entityId: '2fa77824-e9c0-48d8-b707-c9482084cee9',
      changeType: 'field.note',
      payload: {
        service_request_id: '2fa77824-e9c0-48d8-b707-c9482084cee9',
        note: 'v2 verification',
      },
      createdAt: '2026-06-15T02:56:55.549668',
    });
  });

  it('returns undefined for an unkeyable change (missing epoch/seq/type)', () => {
    expect(parseSyncChange({ op_id: 'x' })).toBeUndefined();
    expect(
      parseSyncChange({ authority_epoch: 1, commit_seq: 'nope', change_type: 't' }),
    ).toBeUndefined();
    expect(parseSyncChange('garbage')).toBeUndefined();
  });
});

describe('recordChanges (idempotent, never silently drops)', () => {
  it('records new changes and reports counts', () => {
    const ledger = new VolatileSyncChangeLedger();
    const result = recordChanges(ledger, [
      REAL_CHANGE,
      { ...REAL_CHANGE, commit_seq: 2, change_type: 'jhajsa.submit' },
    ]);
    expect(result).toEqual({ recorded: 2, duplicates: 0, skipped: 0 });
    expect(ledger.count()).toBe(2);
    expect(ledger.has(1, 1)).toBe(true);
  });

  it('re-applying the same page is a no-op (idempotent across a crash-replay)', () => {
    const ledger = new VolatileSyncChangeLedger();
    recordChanges(ledger, [REAL_CHANGE]);
    const second = recordChanges(ledger, [REAL_CHANGE]);
    expect(second).toEqual({ recorded: 0, duplicates: 1, skipped: 0 });
    expect(ledger.count()).toBe(1);
  });

  it('counts unkeyable changes as skipped — surfaced, not silently dropped', () => {
    const ledger = new VolatileSyncChangeLedger();
    const result = recordChanges(ledger, [REAL_CHANGE, { junk: true }]);
    expect(result).toEqual({ recorded: 1, duplicates: 0, skipped: 1 });
  });

  it('lists in (epoch, seq) order', () => {
    const ledger = new VolatileSyncChangeLedger();
    recordChanges(ledger, [
      { ...REAL_CHANGE, commit_seq: 3 },
      { ...REAL_CHANGE, commit_seq: 1 },
      { ...REAL_CHANGE, commit_seq: 2 },
    ]);
    expect(ledger.list().map((c) => c.commitSeq)).toEqual([1, 2, 3]);
  });
});
