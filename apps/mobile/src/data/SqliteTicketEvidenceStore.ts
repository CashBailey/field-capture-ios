/**
 * Durable `TicketEvidenceStore` over the local SQLite database — the real outbox table.
 * Unsynced work survives restart: rows are keyed by idempotency key and carry the full
 * envelope (payload + write identity), submit status, rejection code/detail/http-status,
 * outcome timestamps, and retry metadata. Nothing is ever deleted here by the submit path —
 * accepted rows are kept as local proof of what was sent until a later pruning slice.
 */
import { sync } from '@fieldcapture/contracts';

import type {
  HubFieldTicketSubmission,
  StoreDurability,
  TicketEvidence,
  TicketEvidenceStore,
} from '../domain';
import type { SqlDriver, SqlValue } from './sqlDriver';

export type DurableOutboxStatus =
  | 'pending'
  | 'in-flight'
  | 'retry'
  | 'blocked'
  | 'failed'
  | 'accepted'
  | 'needs-review';

export interface DurableOutboxItem {
  id: string;
  type: string;
  payload: HubFieldTicketSubmission;
  idempotencyKey: string;
  status: DurableOutboxStatus;
  attempts: number;
  createdAt: string;
  updatedAt: string;
  lastError?: string;
  lastHttpStatus?: number;
  lastRejectionCode?: string;
}

interface EvidenceRow extends Record<string, unknown> {
  id: string;
  type: string;
  payload_json: string;
  idempotency_key: string;
  outbox_status: string;
  envelope_json: string;
  state: string;
  attempts: number;
  created_at: string;
  updated_at: string;
  last_rejection_code: string | null;
  last_detail: string | null;
  last_http_status: number | null;
  last_outcome_at: string | null;
  last_transient_reason: string | null;
  next_attempt_at_ms: number | null;
}

const COLUMNS =
  'id, type, payload_json, idempotency_key, outbox_status, envelope_json, state, ' +
  'attempts, created_at, updated_at, ' +
  'last_rejection_code, last_detail, last_http_status, last_outcome_at, ' +
  'last_transient_reason, next_attempt_at_ms';

function outboxStatusFromEvidence(evidence: TicketEvidence): DurableOutboxStatus {
  switch (evidence.state) {
    case 'pending':
      if (evidence.lastRejectionCode !== undefined) return 'blocked';
      if (
        evidence.attempts > 0 ||
        evidence.lastTransientReason !== undefined ||
        evidence.nextAttemptAtMs !== undefined
      ) {
        return 'retry';
      }
      return 'pending';
    case 'in-flight':
      return 'in-flight';
    case 'accepted':
      return 'accepted';
    case 'needs-review':
      return 'needs-review';
    case 'rejected':
      return 'failed';
    default: {
      const _exhaustive: never = evidence.state;
      void _exhaustive;
      return 'failed';
    }
  }
}

function toRowParams(evidence: TicketEvidence): SqlValue[] {
  return [
    evidence.envelope.idempotencyKey,
    evidence.envelope.type,
    JSON.stringify(evidence.envelope.payload),
    evidence.envelope.idempotencyKey,
    outboxStatusFromEvidence(evidence),
    JSON.stringify(evidence.envelope),
    evidence.state,
    evidence.attempts,
    evidence.createdAt,
    evidence.updatedAt,
    evidence.lastRejectionCode ?? null,
    evidence.lastDetail ?? null,
    evidence.lastHttpStatus ?? null,
    evidence.lastOutcomeAt ?? null,
    evidence.lastTransientReason ?? null,
    evidence.nextAttemptAtMs ?? null,
  ];
}

/**
 * Parse one row, or null when its envelope JSON is corrupted (out-of-band file damage). A
 * corrupt row must never take the whole store down — boot recovery and the retry engine keep
 * working on the healthy rows; corrupt keys stay visible via `listCorruptKeys()`.
 */
function fromRowSafe(row: EvidenceRow): TicketEvidence | null {
  try {
    return fromRow(row);
  } catch {
    return null;
  }
}

function fromRow(row: EvidenceRow): TicketEvidence {
  const envelope = JSON.parse(
    row.envelope_json,
  ) as sync.OperationEnvelope<HubFieldTicketSubmission>;
  return {
    envelope,
    state: row.state as sync.OutboxItemState,
    attempts: row.attempts,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.last_rejection_code !== null ? { lastRejectionCode: row.last_rejection_code } : {}),
    ...(row.last_detail !== null ? { lastDetail: row.last_detail } : {}),
    ...(row.last_http_status !== null ? { lastHttpStatus: row.last_http_status } : {}),
    ...(row.last_outcome_at !== null ? { lastOutcomeAt: row.last_outcome_at } : {}),
    ...(row.last_transient_reason !== null
      ? { lastTransientReason: row.last_transient_reason }
      : {}),
    ...(row.next_attempt_at_ms !== null ? { nextAttemptAtMs: row.next_attempt_at_ms } : {}),
  };
}

function outboxItemFromRow(row: EvidenceRow): DurableOutboxItem {
  const evidence = fromRow(row);
  return {
    id: row.id.length > 0 ? row.id : evidence.envelope.idempotencyKey,
    type: row.type.length > 0 ? row.type : evidence.envelope.type,
    payload: evidence.envelope.payload,
    idempotencyKey: evidence.envelope.idempotencyKey,
    status: outboxStatusFromEvidence(evidence),
    attempts: evidence.attempts,
    createdAt: evidence.createdAt,
    updatedAt: evidence.updatedAt,
    ...(evidence.lastDetail !== undefined
      ? { lastError: evidence.lastDetail }
      : evidence.lastTransientReason !== undefined
        ? { lastError: evidence.lastTransientReason }
        : {}),
    ...(evidence.lastHttpStatus !== undefined ? { lastHttpStatus: evidence.lastHttpStatus } : {}),
    ...(evidence.lastRejectionCode !== undefined
      ? { lastRejectionCode: evidence.lastRejectionCode }
      : {}),
  };
}

export class SqliteTicketEvidenceStore implements TicketEvidenceStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(evidence: TicketEvidence): void {
    this.db.run(
      `INSERT OR REPLACE INTO ticket_evidence (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      toRowParams(evidence),
    );
  }

  get(idempotencyKey: string): TicketEvidence | undefined {
    const row = this.db.first<EvidenceRow>(
      `SELECT ${COLUMNS} FROM ticket_evidence WHERE idempotency_key = ?`,
      [idempotencyKey],
    );
    return row === null ? undefined : (fromRowSafe(row) ?? undefined);
  }

  list(): TicketEvidence[] {
    return this.db
      .all<EvidenceRow>(
        `SELECT ${COLUMNS} FROM ticket_evidence ORDER BY created_at, idempotency_key`,
      )
      .map(fromRowSafe)
      .filter((e): e is TicketEvidence => e !== null);
  }

  /**
   * Durable outbox projection required by the Mobile/Hub integration: explicit row identity,
   * operation type, payload, idempotency key, operational status, attempts, last error/status,
   * rejection code, and timestamps. This is a read projection over the evidence table so the
   * domain can keep using the tested contracts state machine internally.
   */
  listOutboxItems(): DurableOutboxItem[] {
    return this.db
      .all<EvidenceRow>(
        `SELECT ${COLUMNS} FROM ticket_evidence ORDER BY created_at, idempotency_key`,
      )
      .map((row) => {
        try {
          return outboxItemFromRow(row);
        } catch {
          return null;
        }
      })
      .filter((item): item is DurableOutboxItem => item !== null);
  }

  /** Rows in a given state — the retry engine's sweep query. */
  listByState(state: sync.OutboxItemState): TicketEvidence[] {
    return this.db
      .all<EvidenceRow>(
        `SELECT ${COLUMNS} FROM ticket_evidence WHERE state = ? ORDER BY created_at, idempotency_key`,
        [state],
      )
      .map(fromRowSafe)
      .filter((e): e is TicketEvidence => e !== null);
  }

  /** Idempotency keys of rows whose stored envelope no longer parses — surfaced, not hidden. */
  listCorruptKeys(): string[] {
    return this.db
      .all<EvidenceRow>(`SELECT ${COLUMNS} FROM ticket_evidence`)
      .filter((row) => fromRowSafe(row) === null)
      .map((row) => row.idempotency_key);
  }
}
