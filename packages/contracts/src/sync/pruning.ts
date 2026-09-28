/**
 * Accepted-evidence pruning policy (ADR 002 SQLite byte budgets × ADR 004 outbox). Pure planner —
 * takes row metadata, returns ids to delete; persistence is the caller's job.
 *
 * THE invariant (cross-cutting #2, "never silently lose work"): only `accepted` rows are ever
 * candidates. Everything still owed to Hub or to a human is protected unconditionally:
 * pending / in-flight / retry / blocked / failed / needs-review rows, accepted rows younger than
 * the retention window, accepted rows whose age is unknowable (no acceptance stamp), and accepted
 * rows carrying an external protection reason (an attachment not yet uploaded+linked, an
 * unprinted record, an unacknowledged print event, …). Pressure NEVER overrides protection — the
 * planner reports a shortfall instead.
 */

/** Operational status of a durable evidence row (matches the app's outbox projection). */
export type EvidenceRowStatus =
  | "pending"
  | "in-flight"
  | "retry"
  | "blocked"
  | "failed"
  | "accepted"
  | "needs-review";

export interface EvidencePruneCandidate {
  id: string;
  status: EvidenceRowStatus;
  sizeBytes: number;
  /** When Hub's accept landed (epoch ms). Absent = age unknowable = protected. */
  acceptedAtMs?: number;
  /**
   * External reasons this row must outlive plain acceptance (e.g. "unlinked-attachment",
   * "unprinted-record", "unacked-print-event"). Any entry protects the row unconditionally.
   */
  protectedReasons?: readonly string[];
}

export interface EvidencePrunePolicy {
  /** Accepted rows younger than this are never pruned (retention window). */
  retentionMs: number;
  /** Prune only while the table's total bytes exceed this budget (ADR 002). */
  maxTotalBytes: number;
  /** Always keep at least this many of the most recently accepted rows (default 0). */
  minKeepAccepted?: number;
}

export interface EvidencePrunePlan {
  /** Row ids safe to delete, oldest accepted first. */
  pruneIds: string[];
  freedBytes: number;
  /** Total bytes that remain after the plan executes. */
  remainingBytes: number;
  /** Bytes still over budget after exhausting every eligible row (0 when the budget is met). */
  shortfallBytes: number;
}

export class PruningError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PruningError";
  }
}

/**
 * Plan which accepted evidence rows to prune. Deterministic: oldest acceptance first, stopping
 * as soon as the total is back under `maxTotalBytes`. Protected rows count toward pressure but
 * are never freed.
 */
export function planEvidencePrune(
  rows: readonly EvidencePruneCandidate[],
  policy: EvidencePrunePolicy,
  nowMs: number,
): EvidencePrunePlan {
  if (!Number.isInteger(policy.retentionMs) || policy.retentionMs < 0) {
    throw new PruningError(`retentionMs must be a non-negative integer (got ${policy.retentionMs})`);
  }
  if (!Number.isInteger(policy.maxTotalBytes) || policy.maxTotalBytes < 0) {
    throw new PruningError(
      `maxTotalBytes must be a non-negative integer (got ${policy.maxTotalBytes})`,
    );
  }
  const minKeep = policy.minKeepAccepted ?? 0;
  if (!Number.isInteger(minKeep) || minKeep < 0) {
    throw new PruningError(`minKeepAccepted must be a non-negative integer (got ${minKeep})`);
  }

  const seen = new Set<string>();
  let totalBytes = 0;
  for (const row of rows) {
    if (seen.has(row.id)) throw new PruningError(`duplicate evidence row id: ${row.id}`);
    seen.add(row.id);
    if (!Number.isInteger(row.sizeBytes) || row.sizeBytes < 0) {
      throw new PruningError(`row ${row.id} has a malformed sizeBytes (${row.sizeBytes})`);
    }
    totalBytes += row.sizeBytes;
  }

  if (totalBytes <= policy.maxTotalBytes) {
    return { pruneIds: [], freedBytes: 0, remainingBytes: totalBytes, shortfallBytes: 0 };
  }

  // Eligibility gate — every condition is a protection, not an optimization.
  const acceptedByRecency = rows
    .filter((r) => r.status === "accepted" && r.acceptedAtMs !== undefined)
    .sort((a, b) => (b.acceptedAtMs as number) - (a.acceptedAtMs as number));
  const keepNewest = new Set(acceptedByRecency.slice(0, minKeep).map((r) => r.id));

  const eligible = acceptedByRecency
    .filter(
      (r) =>
        !keepNewest.has(r.id) &&
        nowMs - (r.acceptedAtMs as number) >= policy.retentionMs &&
        (r.protectedReasons === undefined || r.protectedReasons.length === 0),
    )
    .reverse(); // oldest acceptance first

  const pruneIds: string[] = [];
  let freedBytes = 0;
  for (const row of eligible) {
    if (totalBytes - freedBytes <= policy.maxTotalBytes) break;
    pruneIds.push(row.id);
    freedBytes += row.sizeBytes;
  }

  const remainingBytes = totalBytes - freedBytes;
  return {
    pruneIds,
    freedBytes,
    remainingBytes,
    shortfallBytes: Math.max(0, remainingBytes - policy.maxTotalBytes),
  };
}
