import FieldContracts
// Port of __tests__/assignment-inbox.test.ts — pure assignment-inbox logic (spec 7.5): per-SR
// sync rollup + the 7 filters.
import XCTest

@testable import FieldDomain

final class AssignmentInboxTests: XCTestCase {
    private func sr(_ id: String) -> HubAssignment {
        HubAssignment(serviceRequestId: id, snapshotHash: "h-\(id)")
    }
    private func srWith(_ id: String, _ status: AssignmentStatus) -> HubAssignment {
        HubAssignment(serviceRequestId: id, snapshotHash: "h-\(id)", details: AssignmentDetails(status: status))
    }
    private func item(_ serviceRequestId: String, _ state: OutboxItemState) -> SrSyncItem {
        SrSyncItem(serviceRequestId: serviceRequestId, state: state)
    }

    // ---- rollUpSrSyncState (worst-first) ----

    func testNoItemsReturnsNoLocalWork() {
        XCTAssertEqual(rollUpSrSyncState([]), .noLocalWork)
    }

    func testNeedsReviewWinsOverEverythingElse() {
        XCTAssertEqual(
            rollUpSrSyncState([item("a", .accepted), item("a", .pending), item("a", .needsReview)]),
            .needsReview
        )
        XCTAssertEqual(rollUpSrSyncState([item("a", .rejected), item("a", .accepted)]), .needsReview)
    }

    func testNeedsSyncWhenSomethingStillOwedButNothingRejected() {
        XCTAssertEqual(rollUpSrSyncState([item("a", .accepted), item("a", .inFlight)]), .needsSync)
        XCTAssertEqual(rollUpSrSyncState([item("a", .pending)]), .needsSync)
    }

    func testSyncedOnlyWhenEveryItemIsAccepted() {
        XCTAssertEqual(rollUpSrSyncState([item("a", .accepted), item("a", .accepted)]), .synced)
    }

    // ---- perSrSyncState ----

    func testGroupsBySrAndRollsEachUpIndependently() {
        let map = perSrSyncState([
            item("sr-1", .accepted), item("sr-1", .needsReview),
            item("sr-2", .pending), item("sr-3", .accepted),
        ])
        XCTAssertEqual(map["sr-1"], .needsReview)
        XCTAssertEqual(map["sr-2"], .needsSync)
        XCTAssertEqual(map["sr-3"], .synced)
        XCTAssertNil(map["sr-4"])
    }

    // ---- filterAssignments (the 7 inbox filters) ----

    private var assignments: [HubAssignment] {
        [
            srWith("sr-assigned", .assigned),
            srWith("sr-progress", .inProgress),
            srWith("sr-hold", .onHold),
            sr("sr-legacy"),  // no status → defaults to active/visible
        ]
    }
    private var srState: [String: SrSyncState] {
        ["sr-assigned": .needsSync, "sr-progress": .needsReview, "sr-hold": .synced]
    }
    private func ids(_ filter: InboxFilter) -> [String] {
        filterAssignments(assignments, srState, filter).map(\.serviceRequestId)
    }

    func testExposesExactlyTheSevenSpec75Filters() {
        XCTAssertEqual(
            INBOX_FILTERS,
            [.today, .active, .onHold, .completedLocally, .needsSync, .needsReview, .allCached]
        )
    }

    func testAllCachedReturnsEverythingHeldOnDevice() {
        XCTAssertEqual(ids(.allCached), ["sr-assigned", "sr-progress", "sr-hold", "sr-legacy"])
    }

    func testActiveAndTodayIncludeAssignedInProgressAndStatusLessLegacyNeverOnHold() {
        XCTAssertEqual(ids(.active), ["sr-assigned", "sr-progress", "sr-legacy"])
        XCTAssertEqual(ids(.today), ids(.active))
    }

    func testOnHoldOnlyDispatcherPausedSrs() {
        XCTAssertEqual(ids(.onHold), ["sr-hold"])
    }

    func testNeedsSyncNeedsReviewCompletedLocallyDeriveFromThePerSrRollup() {
        XCTAssertEqual(ids(.needsSync), ["sr-assigned"])
        XCTAssertEqual(ids(.needsReview), ["sr-progress"])
        XCTAssertEqual(ids(.completedLocally), ["sr-hold"])  // synced = accepted, nothing owed
    }

    func testAnSrWithNoLocalWorkAppearsOnlyInAllCachedAndActiveNotTheSyncFilters() {
        XCTAssertFalse(ids(.needsSync).contains("sr-legacy"))
        XCTAssertFalse(ids(.completedLocally).contains("sr-legacy"))
        XCTAssertTrue(ids(.allCached).contains("sr-legacy"))
    }

    // ---- Today priority ladder (spec 7.4) ----

    func testRanksMostActionableFirstNeedsReviewThenNeedsSyncThenInProgressThenAssignedThenOnHold() {
        XCTAssertLessThan(
            todayPriority(srWith("a", .onHold), .needsReview),
            todayPriority(srWith("b", .inProgress), .needsSync)
        )
        XCTAssertLessThan(
            todayPriority(srWith("c", .inProgress), .noLocalWork),
            todayPriority(srWith("d", .assigned), .noLocalWork)
        )
        XCTAssertLessThan(
            todayPriority(srWith("e", .assigned), .noLocalWork),
            todayPriority(srWith("f", .onHold), .noLocalWork)
        )
    }

    func testOrdersAMixedSetAndBreaksTiesStablyByServiceRequestId() {
        let list = [
            srWith("sr-hold", .onHold),
            srWith("sr-assigned", .assigned),
            srWith("sr-progress", .inProgress),
            srWith("sr-review", .inProgress),
            srWith("sr-sync", .assigned),
        ]
        let state: [String: SrSyncState] = ["sr-review": .needsReview, "sr-sync": .needsSync]
        XCTAssertEqual(
            rankTodayAssignments(list, state).map(\.serviceRequestId),
            ["sr-review", "sr-sync", "sr-progress", "sr-assigned", "sr-hold"]
        )
    }
}
