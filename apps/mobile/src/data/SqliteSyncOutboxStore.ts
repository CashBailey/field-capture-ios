/**
 * Durable `SyncOutboxStore` over SQLite — the generic ADR 004 operation outbox behind the full
 * sync engine. Rows are keyed by opId, carry the full envelope (write identity included), the
 * contracts state machine state, retry metadata, the committed change token, and timestamps.
 * The submit/dispatch path never deletes rows; pruning accepted rows moves their opIds into the
 * `committed_ops` ledger so dependency planning still resolves them (`planDispatch`'s
 * `committedOpIds`).
 */
import { sync } from '@fieldcapture/contracts';

import type { DurableSyncOutboxItem, StoreDurability, SyncOutboxStore } from '../domain';
import type { SqlDriver, SqlValue } from './sqlDriver';

interface OutboxRow extends Record<string, unknown> {
  op_id: string;
  idempotency_key: string;
  envelope_json: string;
  state: string;
  retry_count: number;
  committed_epoch: number | null;
  committed_seq: number | null;
  rejection_code: string | null;
  last_error: string | null;
  next_attempt_at_ms: number | null;
  created_at: string;
  updated_at: string;
}

const COLUMNS =
  'op_id, idempotency_key, envelope_json, state, retry_count, committed_epoch, committed_seq, ' +
  'rejection_code, last_error, next_attempt_at_ms, created_at, updated_at';

function toRowParams(item: DurableSyncOutboxItem): SqlValue[] {
  return [
    item.envelope.opId,
    item.envelope.idempotencyKey,
    JSON.stringify(item.envelope),
    item.state,
    item.retryCount,
    item.committedToken?.authorityEpoch ?? null,
    item.committedToken?.commitSeq ?? null,
    item.rejectionCode ?? null,
    item.lastError ?? null,
    item.nextAttemptAtMs ?? null,
    item.createdAt,
    item.updatedAt,
  ];
}

function fromRow(row: OutboxRow): DurableSyncOutboxItem {
  const envelope = JSON.parse(row.envelope_json) as sync.OperationEnvelope;
  return {
    envelope,
    state: row.state as sync.OutboxItemState,
    retryCount: row.retry_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.committed_epoch !== null && row.committed_seq !== null
      ? { committedToken: { authorityEpoch: row.committed_epoch, commitSeq: row.committed_seq } }
      : {}),
    ...(row.rejection_code !== null ? { rejectionCode: row.rejection_code } : {}),
    ...(row.last_error !== null ? { lastError: row.last_error } : {}),
    ...(row.next_attempt_at_ms !== null ? { nextAttemptAtMs: row.next_attempt_at_ms } : {}),
  };
}

/** Parse one row, or null when its envelope JSON is corrupted — a corrupt row must never take
 *  the whole outbox down; corrupt opIds stay visible via `listCorruptOpIds()`. */
function fromRowSafe(row: OutboxRow): DurableSyncOutboxItem | null {
  try {
    return fromRow(row);
  } catch {
    return null;
  }
}

export class SqliteSyncOutboxStore implements SyncOutboxStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(item: DurableSyncOutboxItem): void {
    this.db.run(
      `INSERT OR REPLACE INTO sync_outbox (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      toRowParams(item),
    );
  }

  get(opId: string): DurableSyncOutboxItem | undefined {
    const row = this.db.first<OutboxRow>(`SELECT ${COLUMNS} FROM sync_outbox WHERE op_id = ?`, [
      opId,
    ]);
    return row === null ? undefined : (fromRowSafe(row) ?? undefined);
  }

  list(): DurableSyncOutboxItem[] {
    return this.db
      .all<OutboxRow>(`SELECT ${COLUMNS} FROM sync_outbox ORDER BY created_at, op_id`)
      .map(fromRowSafe)
      .filter((item): item is DurableSyncOutboxItem => item !== null);
  }

  listByState(state: sync.OutboxItemState): DurableSyncOutboxItem[] {
    return this.db
      .all<OutboxRow>(
        `SELECT ${COLUMNS} FROM sync_outbox WHERE state = ? ORDER BY created_at, op_id`,
        [state],
      )
      .map(fromRowSafe)
      .filter((item): item is DurableSyncOutboxItem => item !== null);
  }

  committedOpIds(): Set<string> {
    return new Set(
      this.db.all<{ op_id: string }>('SELECT op_id FROM committed_ops').map((r) => r.op_id),
    );
  }

  /** opIds of rows whose stored envelope no longer parses — surfaced, not hidden. */
  listCorruptOpIds(): string[] {
    return this.db
      .all<OutboxRow>(`SELECT ${COLUMNS} FROM sync_outbox`)
      .filter((row) => fromRowSafe(row) === null)
      .map((row) => row.op_id);
  }

  /**
   * Prune ONE accepted row: delete it and record its opId in the committed-op ledger, in a
   * single transaction. Refuses (throws) for any non-accepted state — the pruning policy layer
   * decides WHAT to prune; this guard makes "prune unsynced work" unrepresentable at the store.
   */
  pruneAcceptedToLedger(opId: string, committedAt: string): void {
    this.db.transaction(() => {
      const row = this.db.first<{ state: string }>(
        'SELECT state FROM sync_outbox WHERE op_id = ?',
        [opId],
      );
      if (row === null) throw new Error(`cannot prune ${opId}: not in the outbox`);
      if (row.state !== 'accepted') {
        throw new Error(
          `cannot prune ${opId}: state is '${row.state}', only 'accepted' may be pruned`,
        );
      }
      this.db.run('DELETE FROM sync_outbox WHERE op_id = ?', [opId]);
      this.db.run('INSERT OR REPLACE INTO committed_ops (op_id, committed_at) VALUES (?, ?)', [
        opId,
        committedAt,
      ]);
    });
  }
}
