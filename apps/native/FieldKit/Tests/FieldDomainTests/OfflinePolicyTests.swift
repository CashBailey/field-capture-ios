// Port of __tests__/offline-policy.test.ts — pure 24-hour offline-policy state machine (Phase 8).
import XCTest

@testable import FieldDomain

final class OfflinePolicyTests: XCTestCase {
    private let HOUR: Int64 = 60 * 60 * 1000
    private let T0: Int64 = 1_000_000_000_000  // arbitrary fixed epoch ms, kept pure

    func testOnlineWindowIsIrrelevantFullWindowReportedAsRemaining() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 - 50 * HOUR, nowMs: T0, online: true))
        XCTAssertEqual(p.state, .online)
        XCTAssertEqual(p.elapsedMs, 0)
        XCTAssertEqual(p.remainingMs, 24 * HOUR)
    }

    func testOfflineWithinThe24hWindowCaptureStaysAllowedRemainingCountsDown() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 - 5 * HOUR, nowMs: T0))
        XCTAssertEqual(p.state, .offlineWithinLimit)
        XCTAssertEqual(p.elapsedMs, 5 * HOUR)
        XCTAssertEqual(p.remainingMs, 19 * HOUR)
    }

    func testOfflinePast24hOverLimitNoRemaining() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 - 25 * HOUR, nowMs: T0))
        XCTAssertEqual(p.state, .offlineOverLimit)
        XCTAssertEqual(p.elapsedMs, 25 * HOUR)
        XCTAssertEqual(p.remainingMs, 0)
    }

    func testExactlyAtTheBoundaryIsOverLimit() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 - 24 * HOUR, nowMs: T0))
        XCTAssertEqual(p.state, .offlineOverLimit)
        XCTAssertEqual(p.remainingMs, 0)
    }

    func testNeverContactedWhileOfflineIsConservativelyOverLimit() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: nil, nowMs: T0))
        XCTAssertEqual(p.state, .offlineOverLimit)
        XCTAssertEqual(p.elapsedMs, 0)
        XCTAssertEqual(p.remainingMs, 0)
    }

    func testAFutureLastContactClockSkewClampsElapsedToZeroNotNegative() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 + 2 * HOUR, nowMs: T0))
        XCTAssertEqual(p.elapsedMs, 0)
        XCTAssertEqual(p.state, .offlineWithinLimit)
        XCTAssertEqual(p.remainingMs, 24 * HOUR)
    }

    func testHonorsAHubSeededWindowOtherThan24h() {
        let p = evaluateOfflinePolicy(OfflinePolicyInput(lastHubContactAtMs: T0 - 5 * HOUR, nowMs: T0, windowHours: 4))
        XCTAssertEqual(p.windowMs, 4 * HOUR)
        XCTAssertEqual(p.state, .offlineOverLimit)
    }

    func testARestartCannotResetTheClockSameDurableTimestampYieldsTheSameVerdict() {
        let input = OfflinePolicyInput(lastHubContactAtMs: T0 - 30 * HOUR, nowMs: T0)
        XCTAssertEqual(evaluateOfflinePolicy(input), evaluateOfflinePolicy(input))
        XCTAssertEqual(evaluateOfflinePolicy(input).state, .offlineOverLimit)
    }

    func testBlocksNewWorkOnlyWhenOverLimit() {
        XCTAssertTrue(offlineAllowsNewWork(.online))
        XCTAssertTrue(offlineAllowsNewWork(.offlineWithinLimit))
        XCTAssertFalse(offlineAllowsNewWork(.offlineOverLimit))
    }

    func testExposesADistinctOverLimitReviewReasonForCapturedEvidence() {
        XCTAssertEqual(OFFLINE_OVER_LIMIT_REVIEW_REASON, "offline-over-limit-evidence")
    }
}
