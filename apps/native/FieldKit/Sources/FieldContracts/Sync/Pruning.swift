// Port of sync/pruning.ts — Accepted-evidence pruning policy (ADR 002 SQLite byte budgets × ADR
// 004 outbox). Pure planner — takes row metadata, returns ids to delete; persistence is the
// caller's job.
//
// THE invariant (cross-cutting #2, "never silently lose work"): only `accepted` rows are ever
// candidates. Everything still owed to Hub or to a human is protected unconditionally:
// pending / in-flight / retry / blocked / failed / needs-review rows, accepted rows younger than
// the retention window, accepted rows whose age is unknowable (no acceptance stamp), and accepted
// rows carrying an external protection reason (an attachment not yet uploaded+linked, an
// unprinted record, an unacknowledged print event, …). Pressure NEVER overrides protection — the
// planner reports a shortfall instead.

/// Operational status of a durable evidence row (matches the app's outbox projection).
public enum EvidenceRowStatus: String, Equatable, Sendable, Codable {
    case pending
    case inFlight = "in-flight"
    case retry
    case blocked
    case failed
    case accepted
    case needsReview = "needs-review"
}

public struct EvidencePruneCandidate: Equatable, Sendable {
    public var id: String
    public var status: EvidenceRowStatus
    public var sizeBytes: Int
    /// When Hub's accept landed (epoch ms). Absent = age unknowable = protected.
    public var acceptedAtMs: Int64?
    /**
     * External reasons this row must outlive plain acceptance (e.g. "unlinked-attachment",
     * "unprinted-record", "unacked-print-event"). Any entry protects the row unconditionally.
     */
    public var protectedReasons: [String]?

    public init(
        id: String, status: EvidenceRowStatus, sizeBytes: Int, acceptedAtMs: Int64? = nil,
        protectedReasons: [String]? = nil
    ) {
        self.id = id
        self.status = status
        self.sizeBytes = sizeBytes
        self.acceptedAtMs = acceptedAtMs
        self.protectedReasons = protectedReasons
    }
}

public struct EvidencePrunePolicy: Equatable, Sendable {
    /// Accepted rows younger than this are never pruned (retention window).
    public var retentionMs: Int
    /// Prune only while the table's total bytes exceed this budget (ADR 002).
    public var maxTotalBytes: Int
    /// Always keep at least this many of the most recently accepted rows (default 0).
    public var minKeepAccepted: Int?

    public init(retentionMs: Int, maxTotalBytes: Int, minKeepAccepted: Int? = nil) {
        self.retentionMs = retentionMs
        self.maxTotalBytes = maxTotalBytes
        self.minKeepAccepted = minKeepAccepted
    }
}

public struct EvidencePrunePlan: Equatable, Sendable {
    /// Row ids safe to delete, oldest accepted first.
    public var pruneIds: [String]
    public var freedBytes: Int
    /// Total bytes that remain after the plan executes.
    public var remainingBytes: Int
    /// Bytes still over budget after exhausting every eligible row (0 when the budget is met).
    public var shortfallBytes: Int
}

public struct PruningError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/**
 * Plan which accepted evidence rows to prune. Deterministic: oldest acceptance first, stopping
 * as soon as the total is back under `maxTotalBytes`. Protected rows count toward pressure but
 * are never freed.
 */
public func planEvidencePrune(
    _ rows: [EvidencePruneCandidate],
    _ policy: EvidencePrunePolicy,
    _ nowMs: Int64
) throws -> EvidencePrunePlan {
    guard policy.retentionMs >= 0 else {
        throw PruningError("retentionMs must be a non-negative integer (got \(policy.retentionMs))")
    }
    guard policy.maxTotalBytes >= 0 else {
        throw PruningError("maxTotalBytes must be a non-negative integer (got \(policy.maxTotalBytes))")
    }
    let minKeep = policy.minKeepAccepted ?? 0
    guard minKeep >= 0 else {
        throw PruningError("minKeepAccepted must be a non-negative integer (got \(minKeep))")
    }

    var seen = Set<String>()
    var totalBytes = 0
    for row in rows {
        guard !seen.contains(row.id) else {
            throw PruningError("duplicate evidence row id: \(row.id)")
        }
        seen.insert(row.id)
        guard row.sizeBytes >= 0 else {
            throw PruningError("row \(row.id) has a malformed sizeBytes (\(row.sizeBytes))")
        }
        totalBytes += row.sizeBytes
    }

    if totalBytes <= policy.maxTotalBytes {
        return EvidencePrunePlan(pruneIds: [], freedBytes: 0, remainingBytes: totalBytes, shortfallBytes: 0)
    }

    // Eligibility gate — every condition is a protection, not an optimization.
    let acceptedByRecency =
        rows
        .compactMap { row -> (row: EvidencePruneCandidate, acceptedAtMs: Int64)? in
            guard row.status == .accepted, let acceptedAtMs = row.acceptedAtMs else { return nil }
            return (row, acceptedAtMs)
        }
        .sorted { $0.acceptedAtMs > $1.acceptedAtMs }
    let keepNewest = Set(acceptedByRecency.prefix(minKeep).map(\.row.id))

    let eligible =
        acceptedByRecency
        .filter { candidate in
            !keepNewest.contains(candidate.row.id)
                && nowMs - candidate.acceptedAtMs >= Int64(policy.retentionMs)
                && (candidate.row.protectedReasons?.isEmpty ?? true)
        }
        .map(\.row)
        .reversed()  // oldest acceptance first

    var pruneIds: [String] = []
    var freedBytes = 0
    for row in eligible {
        if totalBytes - freedBytes <= policy.maxTotalBytes { break }
        pruneIds.append(row.id)
        freedBytes += row.sizeBytes
    }

    let remainingBytes = totalBytes - freedBytes
    return EvidencePrunePlan(
        pruneIds: pruneIds,
        freedBytes: freedBytes,
        remainingBytes: remainingBytes,
        shortfallBytes: max(0, remainingBytes - policy.maxTotalBytes)
    )
}
