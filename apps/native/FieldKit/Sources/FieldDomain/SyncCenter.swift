// Port of src/domain/syncCenter.ts — Sync Center rollup (spec 7.15) — PURE, no UI/storage. Turns
// the durable outbox/draft/blob state into the plain-language buckets a worker actually
// understands ("Saved on this phone", "Waiting to sync", "Needs office review", …) instead of raw
// 409/snapshot-drift codes. The screen renders these; the raw technical codes stay in an
// expandable developer section. Honest by construction: nothing is ever shown as "synced" that
// the Hub has not explicitly accepted.
import FieldContracts

public enum SyncCenterCategory: String, Equatable, Sendable, CaseIterable {
    case savedOnPhone = "saved-on-phone"
    case waitingToSync = "waiting-to-sync"
    case waitingOnYou = "waiting-on-you"
    case acceptedByHub = "accepted-by-hub"
    case needsReview = "needs-review"
    case rejectedByHub = "rejected-by-hub"
}

/// Plain-language, worker-facing labels (spec 7.15).
public let SYNC_CENTER_LABELS: [SyncCenterCategory: String] = [
    .savedOnPhone: "Saved on this phone",
    .waitingToSync: "Waiting to sync",
    .waitingOnYou: "Waiting on you",
    .acceptedByHub: "Accepted by Hub",
    .needsReview: "Needs office review",
    .rejectedByHub: "Rejected by Hub",
]

/// Display order, worst/most-actionable last so it reads top-to-bottom as a lifecycle.
public let SYNC_CENTER_ORDER: [SyncCenterCategory] = [
    .savedOnPhone, .waitingToSync, .acceptedByHub, .waitingOnYou, .needsReview, .rejectedByHub,
]

/// One outbox row, reduced to just what the rollup needs.
public struct SyncCenterEvidence: Equatable, Sendable {
    public var state: OutboxItemState
    /// Present on a 403/409 "blocked" row — it is waiting on the worker to act, not on the network.
    public var lastRejectionCode: String?

    public init(state: OutboxItemState, lastRejectionCode: String? = nil) {
        self.state = state
        self.lastRejectionCode = lastRejectionCode
    }
}

/// One blob/upload row, reduced.
public struct SyncCenterBlob: Equatable, Sendable {
    /// True once the Hub confirmed the attachment.link — the byte is durably owned by the Hub.
    public var linkConfirmed: Bool

    public init(linkConfirmed: Bool) {
        self.linkConfirmed = linkConfirmed
    }
}

public struct SyncCenterInput {
    /// Drafts saved locally but never submitted (FieldTicketDraft / ReceiptDraft count).
    public var draftCount: Int
    public var evidence: [SyncCenterEvidence]
    /// Live uploads; empty until the ADR-004 upload path is wired (Section 4e).
    public var blobs: [SyncCenterBlob]?

    public init(draftCount: Int, evidence: [SyncCenterEvidence], blobs: [SyncCenterBlob]? = nil) {
        self.draftCount = draftCount
        self.evidence = evidence
        self.blobs = blobs
    }
}

public struct SyncCenterSummary: Equatable, Sendable {
    public var counts: [SyncCenterCategory: Int]
    /// Total tracked items across every bucket.
    public var total: Int
    /// True when something is owed to the Hub or needs the worker/office (drives the badge).
    public var hasOutstanding: Bool

    public init(counts: [SyncCenterCategory: Int], total: Int, hasOutstanding: Bool) {
        self.counts = counts
        self.total = total
        self.hasOutstanding = hasOutstanding
    }
}

/**
 * Bucket the durable state into worker-facing categories:
 *  - saved-on-phone: local drafts not yet submitted.
 *  - waiting-to-sync: owed to Hub over the network (pending without a block, in-flight, unlinked
 *    blobs).
 *  - waiting-on-you: a 403/409 block the worker must clear (e.g. clock in, finish a required step).
 *  - accepted-by-hub: Hub-accepted submits + linked blobs (the only "durable on Hub" bucket).
 *  - needs-review / rejected-by-hub: office adjudication / hard rejection.
 */
public func summarizeSyncCenter(_ input: SyncCenterInput) -> SyncCenterSummary {
    let blobs = input.blobs ?? []
    var counts: [SyncCenterCategory: Int] = [:]
    counts[.savedOnPhone] = input.draftCount
    counts[.waitingToSync] =
        input.evidence.filter { ($0.state == .pending && $0.lastRejectionCode == nil) || $0.state == .inFlight }.count
        + blobs.filter { !$0.linkConfirmed }.count
    counts[.waitingOnYou] = input.evidence.filter { $0.state == .pending && $0.lastRejectionCode != nil }.count
    counts[.acceptedByHub] = input.evidence.filter { $0.state == .accepted }.count + blobs.filter(\.linkConfirmed).count
    counts[.needsReview] = input.evidence.filter { $0.state == .needsReview }.count
    counts[.rejectedByHub] = input.evidence.filter { $0.state == .rejected }.count

    let total = SYNC_CENTER_ORDER.reduce(0) { (sum: Int, key: SyncCenterCategory) -> Int in sum + (counts[key] ?? 0) }
    let outstandingCategories: [SyncCenterCategory] = [
        .savedOnPhone, .waitingToSync, .waitingOnYou, .needsReview, .rejectedByHub,
    ]
    let outstandingTotal = outstandingCategories.reduce(0) { (sum: Int, key: SyncCenterCategory) -> Int in
        sum + (counts[key] ?? 0)
    }
    let hasOutstanding = outstandingTotal > 0
    return SyncCenterSummary(counts: counts, total: total, hasOutstanding: hasOutstanding)
}
