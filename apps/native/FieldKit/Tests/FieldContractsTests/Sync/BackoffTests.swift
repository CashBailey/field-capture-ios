// Port of test/backoff.test.ts
import XCTest

@testable import FieldContracts

final class BackoffTests: XCTestCase {
    private let POLICY = RetryPolicy(baseDelayMs: 1_000, maxDelayMs: 8_000)

    // ---- backoff window (exponential, capped) ----

    func testDoublesPerRetryAndCapsAtMaxDelayMs() throws {
        XCTAssertEqual(try backoffWindowMs(0, POLICY), 1_000)
        XCTAssertEqual(try backoffWindowMs(1, POLICY), 2_000)
        XCTAssertEqual(try backoffWindowMs(2, POLICY), 4_000)
        XCTAssertEqual(try backoffWindowMs(3, POLICY), 8_000)
        XCTAssertEqual(try backoffWindowMs(4, POLICY), 8_000)  // capped
        XCTAssertEqual(try backoffWindowMs(1_000, POLICY), 8_000)  // huge counts stay finite at the cap
    }

    func testHonorsACustomMultiplier() throws {
        XCTAssertEqual(try backoffWindowMs(2, RetryPolicy(baseDelayMs: 100, maxDelayMs: 100_000, multiplier: 3)), 900)
    }

    func testDefaultPolicyFiveSecondBaseFiveMinuteCap() throws {
        XCTAssertEqual(try backoffWindowMs(0), 5_000)
        XCTAssertEqual(try backoffWindowMs(10), 300_000)
        XCTAssertEqual(DEFAULT_RETRY_POLICY.maxDelayMs, 300_000)
    }

    func testRejectsBadInputsLoudly() {
        XCTAssertThrowsError(try backoffWindowMs(-1, POLICY)) { error in XCTAssertTrue(error is BackoffError) }
        // ponytail: TS also checks `backoffWindowMs(0.5, POLICY)` throws — `retryCount` is Swift
        // `Int` here, so a fractional value is uncompilable and that case is dropped.
        XCTAssertThrowsError(try backoffWindowMs(0, RetryPolicy(baseDelayMs: 0, maxDelayMs: 10))) { error in
            XCTAssertTrue(error is BackoffError)
        }
        XCTAssertThrowsError(try backoffWindowMs(0, RetryPolicy(baseDelayMs: 100, maxDelayMs: 50))) { error in
            XCTAssertTrue(error is BackoffError)
        }
        var custom = POLICY
        custom.multiplier = 0.5
        XCTAssertThrowsError(try backoffWindowMs(0, custom)) { error in XCTAssertTrue(error is BackoffError) }
    }

    // ---- full jitter (deterministic via injected random) ----

    func testSpreadsUniformlyAcrossZeroToWindow() throws {
        XCTAssertEqual(try computeBackoffDelayMs(3, { 0 }, POLICY), 0)
        XCTAssertEqual(try computeBackoffDelayMs(3, { 0.5 }, POLICY), 4_000)
        XCTAssertEqual(try computeBackoffDelayMs(3, { 0.999 }, POLICY), 7_992)
    }

    func testRejectsABrokenRandomSourceInsteadOfSchedulingGarbage() {
        XCTAssertThrowsError(try computeBackoffDelayMs(0, { 1.5 }, POLICY)) { error in
            XCTAssertTrue(error is BackoffError)
        }
        XCTAssertThrowsError(try computeBackoffDelayMs(0, { -0.1 }, POLICY)) { error in
            XCTAssertTrue(error is BackoffError)
        }
        XCTAssertThrowsError(try computeBackoffDelayMs(0, { .nan }, POLICY)) { error in
            XCTAssertTrue(error is BackoffError)
        }
    }

    func testComputeNextAttemptAtMsIsNowPlusJitteredDelay() throws {
        let now: Int64 = 1_750_000_000_000
        XCTAssertEqual(try computeNextAttemptAtMs(now, 1, { 0.5 }, POLICY), now + 1_000)
        // ponytail: TS also checks `computeNextAttemptAtMs(NaN, ...)` throws — `nowMs` is Swift
        // `Int64` here (epoch-ms, per PORTING.md), so NaN is uncompilable and that case is dropped.
    }
}
