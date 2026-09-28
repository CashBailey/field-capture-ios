/**
 * Accepted-evidence pruning against the ADR 002 SQLite byte budgets, using the pure contracts
 * planner (`sync.planEvidencePrune`). Two tables participate:
 *
 *  - `ticket_evidence` (V1 submit outbox): accepted rows past the retention window may be
 *    DELETED when the table is over budget. Everything else — pending / in-flight / retry /
 *    blocked / failed / needs-review, rows the caller flags as externally protected (an
 *    attachment not yet uploaded+linked, an unprinted record, …), corrupt rows (their envelope
 *    no longer parses — they are evidence of damage), and accepted rows with no outcome
 *    stamp — is NEVER touched, regardless of pressure.
 *
 *  - `sync_outbox` (full-engine outbox): same policy, but pruned opIds move into the
 *    `committed_ops` ledger (a row delete must never turn a satisfied dependency into a dead
 *    one — `planDispatch` resolves pruned parents through the ledger).
 *
 * Row size is measured as the stored JSON text length — the dominant, stable share of the row.
 */
import { sync } from '@fieldcapture/contracts';

import type { SqlDriver } from './sqlDriver';
import { SqliteSyncOutboxStore } from './SqliteSyncOutboxStore';

export interface EvidencePruneOutcome {
  prunedIds: string[];
  freedBytes: number;
  /** Bytes still over budget after every eligible row was freed (protected rows kept). */
  shortfallBytes: number;
}

export interface PruneDeps {
  db: SqlDriver;
  policy: sync.EvidencePrunePolicy;
  now?: () => Date;
  /**
   * External protection reasons per row id (e.g. "unlinked-attachment" while a photo of that
   * ticket is not yet uploaded+linked). Any non-empty answer protects the row unconditionally.
   */
  protectedReasons?: (id: string) => readonly string[];
}

function parseMs(iso: string | null): number | undefined {
  if (iso === null) return undefined;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? undefined : ms;
}

function envelopeParses(json: string): boolean {
  try {
    JSON.parse(json);
    return true;
  } catch {
    return false;
  }
}

/** Prune old accepted `ticket_evidence` rows. Protected work is never deleted. */
export function pruneAcceptedTicketEvidence(deps: PruneDeps): EvidencePruneOutcome {
  const nowMs = (deps.now ?? (() => new Date()))().getTime();
  const rows = deps.db.all<{
    idempotency_key: string;
    outbox_status: string;
    envelope_json: string;
    size_bytes: number;
    last_outcome_at: string | null;
    updated_at: string;
  }>(
    `SELECT idempotency_key, outbox_status, envelope_json,
            length(envelope_json) + length(payload_json) AS size_bytes,
            last_outcome_at, updated_at
       FROM ticket_evidence`,
  );

  const candidates: sync.EvidencePruneCandidate[] = rows.map((row) => {
    const reasons = [...(deps.protectedReasons?.(row.idempotency_key) ?? [])];
    // A corrupt envelope is evidence of out-of-band damage — keep it visible, never prune it.
    if (!envelopeParses(row.envelope_json)) reasons.push('corrupt-envelope');
    const acceptedAtMs = parseMs(row.last_outcome_at) ?? parseMs(row.updated_at);
    return {
      id: row.idempotency_key,
      status: row.outbox_status as sync.EvidenceRowStatus,
      sizeBytes: row.size_bytes,
      ...(acceptedAtMs !== undefined ? { acceptedAtMs } : {}),
      ...(reasons.length > 0 ? { protectedReasons: reasons } : {}),
    };
  });

  const plan = sync.planEvidencePrune(candidates, deps.policy, nowMs);
  deps.db.transaction(() => {
    for (const id of plan.pruneIds) {
      // Belt-and-suspenders: the WHERE clause re-checks acceptance at delete time.
      deps.db.run(`DELETE FROM ticket_evidence WHERE idempotency_key = ? AND state = 'accepted'`, [
        id,
      ]);
    }
  });
  return {
    prunedIds: plan.pruneIds,
    freedBytes: plan.freedBytes,
    shortfallBytes: plan.shortfallBytes,
  };
}

/** Prune old accepted `sync_outbox` rows into the committed-op ledger. */
export function pruneAcceptedSyncOutbox(deps: PruneDeps): EvidencePruneOutcome {
  const nowMs = (deps.now ?? (() => new Date()))().getTime();
  const rows = deps.db.all<{
    op_id: string;
    state: string;
    envelope_json: string;
    size_bytes: number;
    updated_at: string;
  }>(
    `SELECT op_id, state, envelope_json, length(envelope_json) AS size_bytes, updated_at
       FROM sync_outbox`,
  );

  const candidates: sync.EvidencePruneCandidate[] = rows.map((row) => {
    const reasons = [...(deps.protectedReasons?.(row.op_id) ?? [])];
    if (!envelopeParses(row.envelope_json)) reasons.push('corrupt-envelope');
    // The full-engine outbox maps its five machine states onto the planner's status surface:
    // accepted stays accepted; rejected is terminal "failed"; the rest map by name.
    const status: sync.EvidenceRowStatus =
      row.state === 'rejected' ? 'failed' : (row.state as sync.EvidenceRowStatus);
    const acceptedAtMs = parseMs(row.updated_at);
    return {
      id: row.op_id,
      status,
      sizeBytes: row.size_bytes,
      ...(acceptedAtMs !== undefined ? { acceptedAtMs } : {}),
      ...(reasons.length > 0 ? { protectedReasons: reasons } : {}),
    };
  });

  const plan = sync.planEvidencePrune(candidates, deps.policy, nowMs);
  const store = new SqliteSyncOutboxStore(deps.db, 'durable-plain');
  const committedAt = (deps.now ?? (() => new Date()))().toISOString();
  for (const opId of plan.pruneIds) {
    // Throws on any non-accepted state — the store guard makes unsafe pruning unrepresentable.
    store.pruneAcceptedToLedger(opId, committedAt);
  }
  return {
    prunedIds: plan.pruneIds,
    freedBytes: plan.freedBytes,
    shortfallBytes: plan.shortfallBytes,
  };
}
