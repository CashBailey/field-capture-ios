// Port of src/domain/assignmentInbox.ts — Assignment inbox logic (spec 7.5) — PURE, no
// UI/storage. Two concerns the AssignmentInboxScreen composes: (1) a per-SR "last sync state"
// rolled up from the durable outbox/form/blob work items, and (2) the seven inbox filters. Kept
// pure so every rule is unit-tested headlessly; the screen only renders the results. Surfacing
// needs-review (incl. Hub snapshot-drift rejections) on this read path is display-only — it never
// triggers an auto-refetch or wipes local work.
import FieldContracts

// ---- per-SR sync-state rollup ----

/// One unit of sync-tracked work tied to a Service Request (a ticket submit, a safety-form event,
/// a blob link…). The caller collects these from the outbox / form / blob stores — each already
/// knows its `serviceRequestId` (e.g. `TicketEvidence.envelope.payload.serviceRequestId`).
public struct SrSyncItem: Equatable, Sendable {
    public var serviceRequestId: String
    public var state: OutboxItemState

    public init(serviceRequestId: String, state: OutboxItemState) {
        self.serviceRequestId = serviceRequestId
        self.state = state
    }
}

/// The per-SR rollup shown as "Last sync state" and filtered on.
public enum SrSyncState: String, Equatable, Sendable, CaseIterable {
    case noLocalWork = "no-local-work"
    case synced
    case needsSync = "needs-sync"
    case needsReview = "needs-review"
}

public let SR_SYNC_STATE_LABELS: [SrSyncState: String] = [
    .noLocalWork: "Not started",
    .synced: "Synced",
    .needsSync: "Needs sync",
    .needsReview: "Needs review",
]

/**
 * Roll a set of work items for ONE SR into a single state, WORST-first so the most urgent state
 * wins: needs-review (Hub rejected / needs office review) > needs-sync (still owed to Hub) >
 * synced (everything Hub-accepted). No items → the SR has no local work yet.
 */
public func rollUpSrSyncState(_ items: [SrSyncItem]) -> SrSyncState {
    if items.isEmpty { return .noLocalWork }
    if items.contains(where: { $0.state == .needsReview || $0.state == .rejected }) {
        return .needsReview
    }
    if items.contains(where: { $0.state == .pending || $0.state == .inFlight }) {
        return .needsSync
    }
    return .synced
}

/// Group work items by SR and roll each up. SRs with no items are simply absent from the map.
public func perSrSyncState(_ items: [SrSyncItem]) -> [String: SrSyncState] {
    var grouped: [String: [SrSyncItem]] = [:]
    for item in items {
        grouped[item.serviceRequestId, default: []].append(item)
    }
    var out: [String: SrSyncState] = [:]
    for (srId, list) in grouped {
        out[srId] = rollUpSrSyncState(list)
    }
    return out
}

// ---- the 7 inbox filters (spec 7.5) ----

public enum InboxFilter: String, Equatable, Sendable, CaseIterable {
    case today
    case active
    case onHold = "on-hold"
    case completedLocally = "completed-locally"
    case needsSync = "needs-sync"
    case needsReview = "needs-review"
    case allCached = "all-cached"
}

public let INBOX_FILTERS: [InboxFilter] = [
    .today, .active, .onHold, .completedLocally, .needsSync, .needsReview, .allCached,
]

public let INBOX_FILTER_LABELS: [InboxFilter: String] = [
    .today: "Today",
    .active: "Active",
    .onHold: "On hold",
    .completedLocally: "Completed locally",
    .needsSync: "Needs sync",
    .needsReview: "Needs review",
    .allCached: "All cached",
]

/// Statuses that count as workable-now (drive Today/Active).
private let ACTIVE_STATUSES: [AssignmentStatus] = [.assigned, .inProgress]

/**
 * Today-dashboard priority (spec 7.4 priority ladder) — LOWER ranks first. Most-actionable first:
 * office-review needs, then work owed to Hub, then in-progress, then not-yet-started, then
 * on-hold.
 */
public func todayPriority(_ assignment: HubAssignment, _ syncState: SrSyncState) -> Int {
    if syncState == .needsReview { return 0 }
    if syncState == .needsSync { return 1 }
    let status = assignment.details?.status
    if status == .inProgress { return 2 }
    if status == .assigned || status == nil { return 3 }
    if status == .onHold { return 4 }
    return 5
}

/// Order the cached assignments by Today priority (ties break on serviceRequestId).
public func rankTodayAssignments(
    _ assignments: [HubAssignment],
    _ srStateById: [String: SrSyncState]
) -> [HubAssignment] {
    assignments.sorted { a, b in
        let rankA = todayPriority(a, srStateById[a.serviceRequestId] ?? .noLocalWork)
        let rankB = todayPriority(b, srStateById[b.serviceRequestId] ?? .noLocalWork)
        return rankA != rankB ? rankA < rankB : a.serviceRequestId < b.serviceRequestId
    }
}

private func syncStateOf(_ map: [String: SrSyncState], _ assignment: HubAssignment) -> SrSyncState {
    map[assignment.serviceRequestId] ?? .noLocalWork
}

/**
 * Filter the cached assignments for one inbox tab. The Hub only returns active assigned SRs, so:
 *  - Today / Active: workable now (status assigned|in_progress). Today == Active until the Hub
 *    surfaces a per-SR scheduled date; status-less legacy payloads stay visible (default active).
 *  - On hold: dispatcher-paused (status on_hold).
 *  - Completed locally: an accepted local submission exists with nothing still owed (sync 'synced').
 *  - Needs sync / Needs review: the per-SR rollup.
 *  - All cached: everything held on the device (offline view).
 */
public func filterAssignments(
    _ assignments: [HubAssignment],
    _ srStateById: [String: SrSyncState],
    _ filter: InboxFilter
) -> [HubAssignment] {
    switch filter {
    case .allCached:
        return assignments
    case .today, .active:
        return assignments.filter { a in
            guard let status = a.details?.status else { return true }
            return ACTIVE_STATUSES.contains(status)
        }
    case .onHold:
        return assignments.filter { $0.details?.status == .onHold }
    case .completedLocally:
        return assignments.filter { syncStateOf(srStateById, $0) == .synced }
    case .needsSync:
        return assignments.filter { syncStateOf(srStateById, $0) == .needsSync }
    case .needsReview:
        return assignments.filter { syncStateOf(srStateById, $0) == .needsReview }
    }
}
