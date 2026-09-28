/**
 * Down-sync applied-changes ledger (ADR-004 / plan §4g, Section 4e item 4). `SyncEngine.pullOnce`
 * calls `applyChanges(page.changes)` and THEN persists the advanced frontier — so the apply MUST be
 * idempotent and must never silently drop a change (a no-op apply would advance the frontier past
 * authoritative changes, losing them forever). This ledger durably records each change keyed by its
 * server-issued `(authorityEpoch, commitSeq)`; re-applying the same page is a no-op (idempotent),
 * and a crash between apply and frontier-persist re-delivers the page harmlessly.
 *
 * This is the RECORD step. Per-entity application (patching a cached assignment, confirming an
 * accepted form, …) reads from this ledger and is layered on as those consumers land — recording
 * first guarantees the change is never lost in the meantime.
 */
import type { StoreDurability } from './hubGateway';

/** One down-synced change row (opshub `GET /sync/changes`), normalized. */
export interface SyncChangeRow {
  authorityEpoch: number;
  commitSeq: number;
  opId: string;
  entityType: string;
  entityId: string;
  changeType: string;
  payload: unknown;
  createdAt: string;
}

export interface SyncChangeLedger {
  readonly durability: StoreDurability;
  /** Record a change. Returns true if newly inserted, false if it was already applied (idempotent). */
  record(change: SyncChangeRow): boolean;
  has(authorityEpoch: number, commitSeq: number): boolean;
  count(): number;
  list(): SyncChangeRow[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/**
 * Tolerantly normalize one raw change from the Hub. Returns undefined ONLY when the server-issued
 * key fields (`authority_epoch`, `commit_seq`, `change_type`) are missing/malformed — that change
 * cannot be keyed or deduped, so the caller counts it as skipped rather than guessing a key.
 */
export function parseSyncChange(value: unknown): SyncChangeRow | undefined {
  if (!isRecord(value)) return undefined;
  const authorityEpoch = value.authority_epoch ?? value.authorityEpoch;
  const commitSeq = value.commit_seq ?? value.commitSeq;
  const changeType = value.change_type ?? value.changeType;
  if (
    typeof authorityEpoch !== 'number' ||
    !Number.isInteger(authorityEpoch) ||
    typeof commitSeq !== 'number' ||
    !Number.isInteger(commitSeq) ||
    typeof changeType !== 'string' ||
    changeType.length === 0
  ) {
    return undefined;
  }
  return {
    authorityEpoch,
    commitSeq,
    opId: str(value.op_id ?? value.opId),
    entityType: str(value.entity_type ?? value.entityType),
    entityId: str(value.entity_id ?? value.entityId),
    changeType,
    payload: value.payload ?? null,
    createdAt: str(value.created_at ?? value.createdAt),
  };
}

export interface RecordChangesResult {
  /** Newly recorded (not previously applied). */
  recorded: number;
  /** Already-applied duplicates (idempotent re-delivery). */
  duplicates: number;
  /** Unkeyable/malformed changes — a Hub contract violation; surfaced, never silently dropped. */
  skipped: number;
}

/**
 * Idempotently record a page of raw changes into the ledger. Safe to wire directly as the
 * `SyncEngine` `applyChanges` callback (its return is void; this returns counts for callers/tests).
 */
export function recordChanges(
  ledger: SyncChangeLedger,
  changes: readonly unknown[],
): RecordChangesResult {
  let recorded = 0;
  let duplicates = 0;
  let skipped = 0;
  for (const raw of changes) {
    const change = parseSyncChange(raw);
    if (change === undefined) {
      skipped += 1;
      continue;
    }
    if (ledger.record(change)) recorded += 1;
    else duplicates += 1;
  }
  return { recorded, duplicates, skipped };
}

/** In-memory test seam — explicitly volatile. */
export class VolatileSyncChangeLedger implements SyncChangeLedger {
  readonly durability = 'volatile-memory' as const;
  private readonly rows = new Map<string, SyncChangeRow>();

  private key(epoch: number, seq: number): string {
    return `${epoch}:${seq}`;
  }

  record(change: SyncChangeRow): boolean {
    const key = this.key(change.authorityEpoch, change.commitSeq);
    if (this.rows.has(key)) return false;
    this.rows.set(key, { ...change });
    return true;
  }

  has(authorityEpoch: number, commitSeq: number): boolean {
    return this.rows.has(this.key(authorityEpoch, commitSeq));
  }

  count(): number {
    return this.rows.size;
  }

  list(): SyncChangeRow[] {
    return [...this.rows.values()]
      .map((row) => ({ ...row }))
      .sort((a, b) => a.authorityEpoch - b.authorityEpoch || a.commitSeq - b.commitSeq);
  }
}
