import FieldContracts
// Port of apps/mobile/__tests__/native-location-capture.test.ts — captureValidationGps's pure
// mapping (permission gate, raw-fix → LocationGpsPoint mapping, never fabricating a fix).
import XCTest

@testable import FieldAdapters

private final class FakeLocationSource: LocationCaptureSource {
    var authorizationGranted = true
    var fix: RawLocationFix?
    var failFix = false
    private(set) var currentFixCallCount = 0

    func requestForegroundAuthorization() async -> Bool { authorizationGranted }

    func currentFix(timeoutMs: Int) async throws -> RawLocationFix {
        currentFixCallCount += 1
        if failFix { throw LocationCaptureError("location unavailable") }
        guard let fix else { throw LocationCaptureError("no fix configured") }
        return fix
    }
}

final class NativeLocationCaptureTests: XCTestCase {
    func test_capturesOneForegroundGpsFixForValidationEvidence() async throws {
        let source = FakeLocationSource()
        source.fix = RawLocationFix(latitude: 31.5, longitude: -102.1, accuracy: 8, timestampMs: 1_782_223_600_000)

        let result = await captureValidationGps(source)
        XCTAssertEqual(result, LocationGpsPoint(lat: 31.5, lon: -102.1, accuracyM: 8, timestampMs: 1_782_223_600_000))
    }

    func test_returnsNilWhenForegroundPermissionIsDenied() async throws {
        let source = FakeLocationSource()
        source.authorizationGranted = false

        let result = await captureValidationGps(source)
        XCTAssertNil(result)
        XCTAssertEqual(source.currentFixCallCount, 0)
    }

    func test_returnsNilInsteadOfFabricatingGpsWhenTheNativeFixFails() async throws {
        let source = FakeLocationSource()
        source.failFix = true

        let result = await captureValidationGps(source)
        XCTAssertNil(result)
    }

    func test_requestCoordinatorTimesOutWithoutWaitingForTheNativeCallback() async throws {
        let coordinator = LocationRequestCoordinator()

        do {
            _ = try await coordinator.wait(timeoutMs: 5) {}
            XCTFail("expected timeout")
        } catch let error as BoundedFetchTimeoutError {
            XCTAssertEqual(error, BoundedFetchTimeoutError(timeoutMs: 5))
        }
    }

    func test_requestCoordinatorRejectsAConcurrentRequestWithoutReplacingTheFirst() async throws {
        let coordinator = LocationRequestCoordinator()
        let started = expectation(description: "first request started")
        let fix = RawLocationFix(latitude: 31.5, longitude: -102.1, accuracy: 8, timestampMs: 1_782_223_600_000)
        let first = Task {
            try await coordinator.wait(timeoutMs: 1_000) {
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 1)

        do {
            _ = try await coordinator.wait(timeoutMs: 1_000) {}
            XCTFail("expected the concurrent request to fail")
        } catch let error as LocationCaptureError {
            XCTAssertEqual(error.message, "a location request is already in progress")
        }

        coordinator.succeed(fix)
        let result = try await first.value
        XCTAssertEqual(result, fix)
    }

    func test_requestCoordinatorCancellationFinishesThePendingRequest() async throws {
        let coordinator = LocationRequestCoordinator()
        let started = expectation(description: "request started")
        let task = Task {
            try await coordinator.wait(timeoutMs: 1_000) {
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 1)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }
}
