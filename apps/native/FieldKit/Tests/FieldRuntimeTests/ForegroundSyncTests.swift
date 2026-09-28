// Port of __tests__/foreground-sync.test.ts — fires a sync kick only on a real
// background/inactive -> active transition, once per return, never on subscribe-while-active.
// Platform-agnostic (fake AppStateLike seam).
import XCTest

@testable import FieldRuntime

private final class FakeAppState: AppStateLike {
    private var handler: ((String) -> Void)?
    private(set) var removed = false

    func addEventListener(_ handler: @escaping (String) -> Void) -> AppStateSubscription {
        self.handler = handler
        return AppStateSubscription { [weak self] in self?.removed = true }
    }

    func emit(_ state: String) {
        handler?(state)
    }
}

final class ForegroundSyncTests: XCTestCase {
    func testFiresWhenTheAppReturnsToTheForegroundBackgroundToActive() {
        let f = FakeAppState()
        var calls = 0
        _ = subscribeForegroundSync(f, { calls += 1 }, "active")
        f.emit("inactive")
        f.emit("background")
        XCTAssertEqual(calls, 0)
        f.emit("active")
        XCTAssertEqual(calls, 1)
    }

    func testDoesNotFireOnSubscribeWhileActiveNorOnARedundantActiveToActive() {
        let f = FakeAppState()
        var calls = 0
        _ = subscribeForegroundSync(f, { calls += 1 }, "active")
        f.emit("active")
        XCTAssertEqual(calls, 0)
    }

    func testFiresOncePerForegroundReturnAcrossMultipleCycles() {
        let f = FakeAppState()
        var calls = 0
        _ = subscribeForegroundSync(f, { calls += 1 }, "active")
        f.emit("background")
        f.emit("active")  // return 1
        f.emit("inactive")
        f.emit("active")  // return 2
        XCTAssertEqual(calls, 2)
    }

    func testAColdStartInTheBackgroundFiresOnTheFirstActivation() {
        let f = FakeAppState()
        var calls = 0
        _ = subscribeForegroundSync(f, { calls += 1 }, "background")
        f.emit("active")
        XCTAssertEqual(calls, 1)
    }

    func testUnsubscribeRemovesTheNativeListener() {
        let f = FakeAppState()
        let unsubscribe = subscribeForegroundSync(f, {}, "active")
        unsubscribe()
        XCTAssertTrue(f.removed)
    }
}
