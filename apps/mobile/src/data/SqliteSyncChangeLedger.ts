/**
 * Durable down-sync applied-changes ledger over SQLite (ADR-004 §4g). Idempotent on the
 * server-issued (authority_epoch, commit_seq) primary key, so re-applying a change page after a
 * crash-between-apply-and-frontier-persist records each change exactly once.
 */
import type { SyncChangeLedger, SyncChangeRow, StoreDurability } from '../domain';
import type { SqlDriver } from './sqlDriver';

interface ChangeRow extends Record<string, unknown> {
  authority_epoch: number;
  commit_seq: number;
  op_id: string;
  entity_type: string;
  entity_id: string;
  change_type: string;
  payload_json: string;
  created_at: string;
}

const COLUMNS =
  'authority_epoch, commit_seq, op_id, entity_type, entity_id, change_type, payload_json, created_at';

function fromRow(row: ChangeRow): SyncChangeRow {
  return {
    authorityEpoch: row.authority_epoch,
    commitSeq: row.commit_seq,
    opId: row.op_id,
    entityType: row.entity_type,
    entityId: row.entity_id,
    changeType: row.change_type,
    payload: JSON.parse(row.payload_json) as unknown,
    createdAt: row.created_at,
  };
}

export class SqliteSyncChangeLedger implements SyncChangeLedger {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
    private readonly now: () => Date = () => new Date(),
  ) {}

  record(change: SyncChangeRow): boolean {
    if (this.has(change.authorityEpoch, change.commitSeq)) return false;
    this.db.run(
      `INSERT OR IGNORE INTO sync_changes (${COLUMNS}, applied_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        change.authorityEpoch,
        change.commitSeq,
        change.opId,
        change.entityType,
        change.entityId,
        change.changeType,
        JSON.stringify(change.payload ?? null),
        change.createdAt,
        this.now().toISOString(),
      ],
    );
    return true;
  }

  has(authorityEpoch: number, commitSeq: number): boolean {
    return (
      this.db.first<{ one: number }>(
        'SELECT 1 AS one FROM sync_changes WHERE authority_epoch = ? AND commit_seq = ?',
        [authorityEpoch, commitSeq],
      ) !== null
    );
  }

  count(): number {
    return this.db.first<{ n: number }>('SELECT COUNT(*) AS n FROM sync_changes')?.n ?? 0;
  }

  list(): SyncChangeRow[] {
    return this.db
      .all<ChangeRow>(`SELECT ${COLUMNS} FROM sync_changes ORDER BY authority_epoch, commit_seq`)
      .map(fromRow);
  }
}
