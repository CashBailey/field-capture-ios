import FieldData
// Port of __tests__/boot-failure.test.ts — the never-auto-wipe guarantee. Only a DB KEY mismatch
// may offer a destructive reset; a missing Hub URL or any other error keeps local data untouched.
import XCTest

@testable import FieldRuntime

/// ponytail: TS's "tolerates a non-Error throw" (`classifyBootFailure('boom')`) has no Swift
/// analog — every Swift `throw`/catch value must already conform to `Error`, so there is no
/// "thrown a bare string" case to port; dropped as unreachable (same pattern as the contracts
/// ports' "unknown wire outcome" cases).
private struct GenericTestError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class BootFailureTests: XCTestCase {
    func testDbKeyMismatchIsTheOnlyFailureThatMayOfferALocalReset() {
        let f = classifyBootFailure(DatabaseKeyMismatchError("cipher key no longer opens db"))
        XCTAssertEqual(f.reason, .dbKeyMismatch)
        XCTAssertTrue(f.canReset)
        XCTAssertTrue(f.detail.contains("cipher key"))
    }

    func testMissingHubUrlIsAConfigErrorDataUntouchedNoReset() {
        let f = classifyBootFailure(HubConfigError("OPS_HUB_URL_DEV is not set"))
        XCTAssertEqual(f.reason, .hubConfig)
        XCTAssertFalse(f.canReset)
        XCTAssertTrue(f.message.lowercased().contains("hub"))
    }

    func testAnyOtherErrorIsUnknownNeverAutoWipeLocalDataPreserved() {
        let f = classifyBootFailure(GenericTestError(message: "disk full"))
        XCTAssertEqual(f.reason, .unknown)
        XCTAssertFalse(f.canReset)
        XCTAssertTrue(f.message.lowercased().contains("preserved"))
        XCTAssertEqual(f.detail, "disk full")
    }

    func testOnlyTheKeyMismatchBranchIsEverResettableTheInvariant() {
        let candidates: [Error] = [
            DatabaseKeyMismatchError("x"),
            HubConfigError("y"),
            GenericTestError(message: "z"),
        ]
        let resettable = candidates.filter { classifyBootFailure($0).canReset }
        XCTAssertEqual(resettable.count, 1)
    }
}
