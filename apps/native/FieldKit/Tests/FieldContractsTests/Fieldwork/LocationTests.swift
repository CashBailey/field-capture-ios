// Port of test/location.test.ts
import XCTest

@testable import FieldContracts

final class LocationTests: XCTestCase {
    private func gps(_ lat: Double, _ lon: Double) -> LocationGpsPoint {
        LocationGpsPoint(lat: lat, lon: lon, accuracyM: 5, timestampMs: 1_750_000_000_000)
    }

    // ---- distanceMeters (haversine) ----

    func testDistanceMetersIsZeroForSamePointAndGrowsWithSeparation() {
        XCTAssertEqual(distanceMeters(gps(31.5, -102.1), gps(31.5, -102.1)), 0, accuracy: 0.000005)
        // ~111 km per degree of latitude.
        XCTAssertGreaterThan(distanceMeters(gps(31.5, -102.1), gps(32.5, -102.1)), 100_000)
    }

    // ---- classifyLocationEvidence (validation-only, never fabricates 'verified') ----

    private let expected = ExpectedArea(lat: 31.5, lon: -102.1, radiusM: 250)

    func testVerifiedWhenGpsIsInsideGeofenceRadius() {
        XCTAssertEqual(
            classifyLocationEvidence(LocationClassifyInput(gps: gps(31.5, -102.1), expected: expected)), .verified)
    }

    func testOutsideExpectedAreaWhenGpsIsBeyondRadius() {
        XCTAssertEqual(
            classifyLocationEvidence(LocationClassifyInput(gps: gps(31.6, -102.1), expected: expected)),
            .outsideExpectedArea
        )
    }

    func testUnverifiedWhenThereIsGpsButNoExpectedArea() {
        XCTAssertEqual(classifyLocationEvidence(LocationClassifyInput(gps: gps(31.5, -102.1))), .unverified)
    }

    func testGpsUnavailableWhenGpsIsMissingOrFixFailed() {
        XCTAssertEqual(classifyLocationEvidence(LocationClassifyInput(expected: expected)), .gpsUnavailable)
        XCTAssertEqual(
            classifyLocationEvidence(LocationClassifyInput(gps: gps(31.5, -102.1), gpsUnavailable: true)),
            .gpsUnavailable
        )
    }

    func testManualOnlyTakesPrecedence() {
        XCTAssertEqual(
            classifyLocationEvidence(
                LocationClassifyInput(gps: gps(31.5, -102.1), expected: expected, manualOnly: true)),
            .manualOnly
        )
    }
}
