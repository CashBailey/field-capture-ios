// Port of test/pruning.test.ts
import XCTest

@testable import FieldContracts

private let DAY_MS: Int64 = 24 * 60 * 60 * 1000
private let NOW: Int64 = 100 * DAY_MS

final class PruningTests: XCTestCase {
    private let POLICY = EvidencePrunePolicy(retentionMs: 7 * 24 * 60 * 60 * 1000, maxTotalBytes: 1_000)

    private func accepted(
        _ id: String,
        _ sizeBytes: Int,
        _ ageDays: Int,
        protectedReasons: [String]? = nil
    ) -> EvidencePruneCandidate {
        EvidencePruneCandidate(
            id: id, status: .accepted, sizeBytes: sizeBytes,
            acceptedAtMs: NOW - Int64(ageDays) * DAY_MS, protectedReasons: protectedReasons
        )
    }

    // ---- planEvidencePrune — safety invariants ----

    func testPrunesNothingWhileTotalBytesAreWithinBudget() throws {
        let rows = [accepted("a", 400, 30), accepted("b", 400, 30)]
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, [])
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertEqual(plan.remainingBytes, 800)
    }

    func testNeverPrunesNonAcceptedWorkNoMatterThePressure() throws {
        let protectedStatuses: [EvidenceRowStatus] = [.pending, .inFlight, .retry, .blocked, .failed, .needsReview]
        let rows: [EvidencePruneCandidate] = protectedStatuses.enumerated().map { i, status in
            EvidencePruneCandidate(id: "p\(i)", status: status, sizeBytes: 10_000, acceptedAtMs: NOW - 90 * DAY_MS)
        }
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, [])
        // The planner reports it could not reach the budget rather than touching protected rows.
        XCTAssertEqual(plan.shortfallBytes, 60_000 - POLICY.maxTotalBytes)
    }

    func testNeverPrunesAcceptedRowsStillInsideTheRetentionWindow() throws {
        let rows = [accepted("old", 600, 30), accepted("young", 600, 2)]
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, ["old"])
    }

    func testNeverPrunesAnAcceptedRowCarryingAnExternalProtectionReason() throws {
        let rows = [
            accepted("linked-pending", 900, 30, protectedReasons: ["unlinked-attachment"]),
            accepted("unprinted", 900, 30, protectedReasons: ["unprinted-record"]),
            accepted("free", 900, 30),
        ]
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, ["free"])
        XCTAssertEqual(plan.shortfallBytes, 1_800 - POLICY.maxTotalBytes)
    }

    func testNeverPrunesAnAcceptedRowWithNoAcceptedAtMs() throws {
        let rows: [EvidencePruneCandidate] = [
            EvidencePruneCandidate(id: "no-stamp", status: .accepted, sizeBytes: 5_000)
        ]
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, [])
    }

    // ---- planEvidencePrune — eviction order and budget targeting ----

    func testPrunesOldestAcceptedFirstOnlyUntilBackUnderBudget() throws {
        let rows = [accepted("newest", 400, 10), accepted("oldest", 400, 50), accepted("middle", 400, 30)]
        // total 1200 > 1000; freeing the single oldest row reaches 800 <= 1000.
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, ["oldest"])
        XCTAssertEqual(plan.freedBytes, 400)
        XCTAssertEqual(plan.remainingBytes, 800)
        XCTAssertEqual(plan.shortfallBytes, 0)
    }

    func testKeepsTheNMostRecentAcceptedRowsWhenMinKeepAcceptedIsSet() throws {
        let rows = [accepted("a", 600, 50), accepted("b", 600, 40), accepted("c", 600, 30)]
        var policy = POLICY
        policy.minKeepAccepted = 2
        let plan = try planEvidencePrune(rows, policy, NOW)
        XCTAssertEqual(plan.pruneIds, ["a"])
    }

    func testCountsProtectedRowsTowardTotalPressureButOnlyFreesEligibleOnes() throws {
        let rows: [EvidencePruneCandidate] = [
            EvidencePruneCandidate(id: "pending-heavy", status: .pending, sizeBytes: 900),
            accepted("a", 300, 30),
            accepted("b", 300, 20),
        ]
        // total 1500; pruning both accepted rows gets to 900 <= 1000 — pending row untouched.
        let plan = try planEvidencePrune(rows, POLICY, NOW)
        XCTAssertEqual(plan.pruneIds, ["a", "b"])
        XCTAssertEqual(plan.remainingBytes, 900)
    }

    func testRejectsMalformedPoliciesAndRowsLoudly() {
        XCTAssertThrowsError(try planEvidencePrune([], EvidencePrunePolicy(retentionMs: -1, maxTotalBytes: 10), NOW)) {
            error in
            XCTAssertTrue(error is PruningError)
        }
        XCTAssertThrowsError(try planEvidencePrune([], EvidencePrunePolicy(retentionMs: 0, maxTotalBytes: -1), NOW)) {
            error in
            XCTAssertTrue(error is PruningError)
        }
        XCTAssertThrowsError(
            try planEvidencePrune(
                [EvidencePruneCandidate(id: "x", status: .accepted, sizeBytes: -5, acceptedAtMs: 0)], POLICY, NOW)
        ) { error in
            XCTAssertTrue(error is PruningError)
        }
        XCTAssertThrowsError(
            try planEvidencePrune([accepted("dup", 1, 1), accepted("dup", 1, 1)], POLICY, NOW)
        ) { error in
            XCTAssertTrue(error is PruningError)
        }
    }
}
