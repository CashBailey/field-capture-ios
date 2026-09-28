// Port of src/data/evidencePruning.ts — Accepted-evidence pruning against the ADR 002 SQLite byte
// budgets, using the pure contracts planner (`planEvidencePrune`). Two tables participate:
//
//  - `ticket_evidence` (V1 submit outbox): accepted rows past the retention window may be
//    DELETED when the table is over budget. Everything else — pending / in-flight / retry /
//    blocked / failed / needs-review, rows the caller flags as externally protected (an
//    attachment not yet uploaded+linked, an unprinted record, …), corrupt rows (their envelope no
//    longer parses — they are evidence of damage), and accepted rows with no outcome stamp — is
//    NEVER touched, regardless of pressure.
//
//  - `sync_outbox` (full-engine outbox): same policy, but pruned opIds move into the
//    `committed_ops` ledger (a row delete must never turn a satisfied dependency into a dead one
//    — `planDispatch` resolves pruned parents through the ledger).
//
// Row size is measured as the stored JSON text length — the dominant, stable share of the row.
import Foundation
import FieldContracts
import FieldDomain

public struct EvidencePruneOutcome: Equatable, Sendable {
    public var prunedIds: [String]
    public var freedBytes: Int
    /// Bytes still over budget after every eligible row was freed (protected rows kept).
    public var shortfallBytes: Int

    public init(prunedIds: [String], freedBytes: Int, shortfallBytes: Int) {
        self.prunedIds = prunedIds
        self.freedBytes = freedBytes
        self.shortfallBytes = shortfallBytes
    }
}

public struct PruneDeps {
    public var db: SqlDriver
    public var policy: EvidencePrunePolicy
    public var now: (() -> Date)?
    /// External protection reasons per row id (e.g. "unlinked-attachment" while a photo of that
    /// ticket is not yet uploaded+linked). Any non-empty answer protects the row unconditionally.
    public var protectedReasons: ((String) -> [String])?

    public init(
        db: SqlDriver, policy: EvidencePrunePolicy, now: (() -> Date)? = nil,
        protectedReasons: ((String) -> [String])? = nil
    ) {
        self.db = db
        self.policy = policy
        self.now = now
        self.protectedReasons = protectedReasons
    }
}

private func parseMs(_ iso: String?) -> Int64? {
    guard let iso else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: iso) { return Int64(date.timeIntervalSince1970 * 1000) }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    if let date = whole.date(from: iso) { return Int64(date.timeIntervalSince1970 * 1000) }
    return nil
}

private func envelopeParses(_ json: String) -> Bool {
    (try? jsonParse(json)) != nil
}

private func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Prune old accepted `ticket_evidence` rows. Protected work is never deleted.
public func pruneAcceptedTicketEvidence(_ deps: PruneDeps) throws -> EvidencePruneOutcome {
    let nowMs = Int64((deps.now ?? { Date() })().timeIntervalSince1970 * 1000)
    let rows = try deps.db.all(
        """
        SELECT idempotency_key, outbox_status, envelope_json,
               length(envelope_json) + length(payload_json) AS size_bytes,
               last_outcome_at, updated_at
          FROM ticket_evidence
        """)

    let candidates: [EvidencePruneCandidate] = rows.map { row in
        let id = row.string("idempotency_key") ?? ""
        var reasons = deps.protectedReasons?(id) ?? []
        // A corrupt envelope is evidence of out-of-band damage — keep it visible, never prune it.
        if !envelopeParses(row.string("envelope_json") ?? "") { reasons.append("corrupt-envelope") }
        let acceptedAtMs = parseMs(row.string("last_outcome_at")) ?? parseMs(row.string("updated_at"))
        return EvidencePruneCandidate(
            id: id,
            status: EvidenceRowStatus(rawValue: row.string("outbox_status") ?? "") ?? .pending,
            sizeBytes: Int(row.int("size_bytes") ?? 0),
            acceptedAtMs: acceptedAtMs,
            protectedReasons: reasons.isEmpty ? nil : reasons)
    }

    let plan = try planEvidencePrune(candidates, deps.policy, nowMs)
    try deps.db.transaction {
        for id in plan.pruneIds {
            // Belt-and-suspenders: the WHERE clause re-checks acceptance at delete time.
            try deps.db.run(
                "DELETE FROM ticket_evidence WHERE idempotency_key = ? AND state = 'accepted'", [.text(id)])
        }
    }
    return EvidencePruneOutcome(
        prunedIds: plan.pruneIds, freedBytes: plan.freedBytes, shortfallBytes: plan.shortfallBytes)
}

/// Prune old accepted `sync_outbox` rows into the committed-op ledger.
public func pruneAcceptedSyncOutbox(_ deps: PruneDeps) throws -> EvidencePruneOutcome {
    let nowMs = Int64((deps.now ?? { Date() })().timeIntervalSince1970 * 1000)
    let rows = try deps.db.all(
        "SELECT op_id, state, envelope_json, length(envelope_json) AS size_bytes, updated_at FROM sync_outbox")

    let candidates: [EvidencePruneCandidate] = rows.map { row in
        let opId = row.string("op_id") ?? ""
        var reasons = deps.protectedReasons?(opId) ?? []
        if !envelopeParses(row.string("envelope_json") ?? "") { reasons.append("corrupt-envelope") }
        // The full-engine outbox maps its five machine states onto the planner's status surface:
        // accepted stays accepted; rejected is terminal "failed"; the rest map by name.
        let stateStr = row.string("state") ?? ""
        let status: EvidenceRowStatus =
            stateStr == "rejected" ? .failed : (EvidenceRowStatus(rawValue: stateStr) ?? .pending)
        let acceptedAtMs = parseMs(row.string("updated_at"))
        return EvidencePruneCandidate(
            id: opId, status: status, sizeBytes: Int(row.int("size_bytes") ?? 0),
            acceptedAtMs: acceptedAtMs, protectedReasons: reasons.isEmpty ? nil : reasons)
    }

    let plan = try planEvidencePrune(candidates, deps.policy, nowMs)
    let store = SqliteSyncOutboxStore(deps.db, .durablePlain)
    let committedAt = isoStamp((deps.now ?? { Date() })())
    for opId in plan.pruneIds {
        // Throws on any non-accepted state — the store guard makes unsafe pruning unrepresentable.
        try store.pruneAcceptedToLedger(opId, committedAt)
    }
    return EvidencePruneOutcome(
        prunedIds: plan.pruneIds, freedBytes: plan.freedBytes, shortfallBytes: plan.shortfallBytes)
}
