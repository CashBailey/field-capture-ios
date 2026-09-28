// Port of sync/conflict.ts — Conflict-resolution contract (ADR 004). Conflict resolution lives in
// exactly one place — Hub — and the phone never auto-merges. This module names the
// machine-readable outcomes and maps each Hub `CommandResult` to the local follow-up the phone
// must take.
//
// The governing rules (report 03):
// - accepted     → commit locally, record the change token.
// - rejected     → mark the local draft conflicted, pull a fresh snapshot, let the user re-apply or
//                  abandon. NEVER silently merge or overwrite.
// - needs-review → preserve the work as evidence, freeze the record, flag for manual review. The
//                  phone never "wins" authority retroactively, but evidence is never discarded
//                  (cross-cutting invariant #2).

/// Machine-readable rejection codes Hub returns (report 03 — race/lock/stale containment).
public enum RejectionCode: String, Equatable, Sendable, CaseIterable {
    case missingPrecondition = "missing_precondition"  // 428: a mutable edit arrived with no base_version / If-Match
    case staleVersion = "stale_version"  // 412: base_version is behind the authoritative row
    case lockedSr = "locked_sr"  // edit attempted on an SR locked by an accepted work-start
    case assignmentChanged = "assignment_changed"  // owner/assistant changed before this edit committed
    case revokedActor = "revoked_actor"  // actor was revoked/inactive by validation time
    case duplicate  // idempotency-key replay of an already-committed op
}

public let REJECTION_CODES: [String] = RejectionCode.allCases.map(\.rawValue)

/// Cases that must escalate to manual review rather than auto-resolve (report 03).
public enum ReviewTrigger: String, Equatable, Sendable, CaseIterable {
    case offlineWorkStartAfterReassignment = "offline-work-start-after-reassignment"
    case competingWorkStartEvidence = "competing-work-start-evidence"
    case signatureFromRevokedActor = "signature-from-revoked-actor"
    case staleFinalization = "stale-finalization"
    case dependencyNeverCommitted = "dependency-never-committed"
}

public let REVIEW_TRIGGERS: [String] = ReviewTrigger.allCases.map(\.rawValue)

public func isRejectionCode(_ code: String) -> Bool {
    RejectionCode(rawValue: code) != nil
}

/**
 * The local follow-up for a Hub outcome. `.markConflicted` always pulls a fresh snapshot (the
 * phone has no authority to resolve). `.preserveEvidenceAndFlag` freezes the record but keeps the
 * work.
 */
public enum LocalSyncAction: Equatable, Sendable {
    case commit(token: ChangeToken)
    case markConflicted(rejectionCode: String, pullSnapshot: Bool)
    case preserveEvidenceAndFlag(reviewReason: String, freeze: Bool)
}

/// ponytail: TS has a `default` branch that throws on an unrecognized `.outcome` string (defense
/// against a wire-deserialized value escaping the type system). `CommandResult` is a real Swift
/// enum, so that case cannot be constructed — the switch below is exhaustive at compile time and
/// that branch (and its ported test) is dropped as unreachable.
public func localActionFor<Payload>(_ result: CommandResult<Payload>) -> LocalSyncAction {
    switch result {
    case .accepted(_, let token):
        return .commit(token: token)
    case .rejected(_, let rejectionCode, _, _):
        return .markConflicted(rejectionCode: rejectionCode, pullSnapshot: true)
    case .needsReview(_, let reviewReason):
        return .preserveEvidenceAndFlag(reviewReason: reviewReason, freeze: true)
    }
}
