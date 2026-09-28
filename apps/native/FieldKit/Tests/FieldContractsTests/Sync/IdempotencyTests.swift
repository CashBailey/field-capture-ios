// Port of test/idempotency.test.ts
import XCTest

@testable import FieldContracts

final class IdempotencyTests: XCTestCase {
    // ---- idempotency key (gtr:<device>:<seq>:<uuid>) ----

    func testRoundTrips() throws {
        let key = try buildIdempotencyKey("device-abc", 42, "op-uuid-1")
        XCTAssertEqual(key, "gtr:device-abc:42:op-uuid-1")
        XCTAssertEqual(
            try parseIdempotencyKey(key),
            ParsedIdempotencyKey(deviceInstanceId: "device-abc", localSeq: 42, opUuid: "op-uuid-1")
        )
    }

    func testRejectsColonInSegmentsAndBadLocalSeq() {
        XCTAssertThrowsError(try buildIdempotencyKey("dev:ice", 1, "op")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        XCTAssertThrowsError(try buildIdempotencyKey("dev", 1, "op:1")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        XCTAssertThrowsError(try buildIdempotencyKey("dev", -1, "op")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        // ponytail: TS also checks `buildIdempotencyKey("dev", 1.5, "op")` throws — `localSeq` is
        // Swift `Int` here, so a fractional value is uncompilable and that case is dropped.
    }

    func testRejectsMalformedKeysOnParse() {
        XCTAssertThrowsError(try parseIdempotencyKey("nope")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        XCTAssertThrowsError(try parseIdempotencyKey("xyz:dev:1:op")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        XCTAssertThrowsError(try parseIdempotencyKey("gtr:dev:notnum:op")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
        XCTAssertThrowsError(try parseIdempotencyKey("gtr::1:op")) { error in
            XCTAssertTrue(error is IdempotencyKeyError)
        }
    }

    // ---- change token ordering ----

    func testOrdersByEpochFirstThenCommitSeq() {
        XCTAssertLessThan(
            compareChangeTokens(
                ChangeToken(authorityEpoch: 1, commitSeq: 9), ChangeToken(authorityEpoch: 2, commitSeq: 0)), 0)
        XCTAssertLessThan(
            compareChangeTokens(
                ChangeToken(authorityEpoch: 2, commitSeq: 1), ChangeToken(authorityEpoch: 2, commitSeq: 5)), 0)
        XCTAssertEqual(
            compareChangeTokens(
                ChangeToken(authorityEpoch: 2, commitSeq: 5), ChangeToken(authorityEpoch: 2, commitSeq: 5)), 0)
    }
}
