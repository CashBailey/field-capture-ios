// Port of test/tus.test.ts
import XCTest

@testable import FieldContracts

final class TusTests: XCTestCase {
    // ---- planNextChunk (resumable upload chunking) ----

    func testPlansSequentialChunksUntilTheFileIsExhausted() throws {
        XCTAssertEqual(try planNextChunk(0, 10, 4), .chunk(offset: 0, length: 4))
        XCTAssertEqual(try planNextChunk(4, 10, 4), .chunk(offset: 4, length: 4))
        XCTAssertEqual(try planNextChunk(8, 10, 4), .chunk(offset: 8, length: 2))  // final partial chunk
    }

    func testReturnsCompleteOnceEveryByteIsAcknowledged() throws {
        XCTAssertEqual(try planNextChunk(10, 10, 4), .complete)
    }

    func testAZeroByteBlobIsCompleteImmediately() throws {
        XCTAssertEqual(try planNextChunk(0, 0, 4), .complete)
    }

    func testRejectsBadInputsLoudly() {
        XCTAssertThrowsError(try planNextChunk(-1, 10, 4)) { error in XCTAssertTrue(error is UploadProtocolError) }
        XCTAssertThrowsError(try planNextChunk(0, -1, 4)) { error in XCTAssertTrue(error is UploadProtocolError) }
        XCTAssertThrowsError(try planNextChunk(0, 10, 0)) { error in XCTAssertTrue(error is UploadProtocolError) }
        // ponytail: TS also checks `planNextChunk(0.5, 10, 4)` throws — all three params are Swift
        // `Int` here, so a fractional value is uncompilable and that case is dropped.
        // acked beyond the file means local bookkeeping is corrupt — never "round down" silently
        XCTAssertThrowsError(try planNextChunk(11, 10, 4)) { error in XCTAssertTrue(error is UploadProtocolError) }
    }

    // ---- reconcileOffset (server offset is the truth on resume) ----

    func testAdoptsTheServerOffsetWhenItIsAheadOfLocalBookkeeping() throws {
        // We sent bytes the app never recorded (crash after a PATCH landed): server wins.
        XCTAssertEqual(try reconcileOffset(4, 8, 10), 8)
    }

    func testAdoptsTheServerOffsetWhenItIsBehindLocalBookkeeping() throws {
        // The session lost bytes server-side; re-send from the server's offset.
        XCTAssertEqual(try reconcileOffset(8, 4, 10), 4)
    }

    func testAcceptsAServerOffsetEqualToTheFullLength() throws {
        XCTAssertEqual(try reconcileOffset(4, 10, 10), 10)
    }

    func testThrowsWhenTheServerClaimsMoreBytesThanTheBlobHas() {
        XCTAssertThrowsError(try reconcileOffset(4, 11, 10)) { error in XCTAssertTrue(error is UploadProtocolError) }
    }

    func testRejectsMalformedOffsetsLoudly() {
        XCTAssertThrowsError(try reconcileOffset(-1, 4, 10)) { error in XCTAssertTrue(error is UploadProtocolError) }
        XCTAssertThrowsError(try reconcileOffset(0, -4, 10)) { error in XCTAssertTrue(error is UploadProtocolError) }
        // ponytail: TS also checks `reconcileOffset(0, 4.5, 10)` throws — all three params are
        // Swift `Int` here, so a fractional value is uncompilable and that case is dropped.
    }

    // ---- verifyUploadHash (whole-file integrity gate) ----

    func testPassesWhenTheServerComputedHashMatches() throws {
        XCTAssertTrue(try verifyUploadHash("AB12", "ab12"))
        XCTAssertTrue(try verifyUploadHash("ab12", "ab12"))
    }

    func testFailsOnAMismatch() throws {
        XCTAssertFalse(try verifyUploadHash("ab12", "ab13"))
    }

    func testAnAbsentOrEmptyServerHashNeverVerifies() throws {
        XCTAssertFalse(try verifyUploadHash("ab12", nil))
        XCTAssertFalse(try verifyUploadHash("ab12", ""))
    }

    func testRejectsAnEmptyLocalHashLoudly() {
        XCTAssertThrowsError(try verifyUploadHash("", "ab12")) { error in XCTAssertTrue(error is UploadProtocolError) }
    }
}
