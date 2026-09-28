import FieldContracts
import FieldDomain
// Port of __tests__/location-evidence-sync-service.test.ts
import XCTest

@testable import FieldRuntime

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

private let EVIDENCE = LocationEvidence(
    id: "loc-1", serviceRequestId: "sr-9", placeKind: .wellSite, evidenceType: "arrival",
    gps: LocationGpsPoint(lat: 31.5, lon: -102.1, accuracyM: 6, timestampMs: 1_750_000_000_000),
    state: .verified, createdAt: "2026-06-10T12:00:00.000Z")

private enum LocationOutboxFailure: Error, Equatable {
    case write
}

private func makeService(enqueueFailure: LocationOutboxFailure? = nil) -> (
    service: LocationEvidenceSyncService, enqueued: Box<OperationEnvelope<LocationEvidence>>
) {
    let enqueued = Box<OperationEnvelope<LocationEvidence>>()
    var seq = 0
    var uuid = 0
    let service = LocationEvidenceSyncService(
        LocationEvidenceSyncDeps(
            enqueueEvent: { envelope in
                if let enqueueFailure { throw enqueueFailure }
                enqueued.items.append(envelope)
            },
            identity: FakeWriteIdentity(
                deviceInstanceId: "devA",
                allocateLocalSeqImpl: {
                    defer { seq += 1 }
                    return seq
                },
                generateUuidImpl: {
                    defer { uuid += 1 }
                    return "op-\(uuid)"
                })))
    return (service, enqueued)
}

final class LocationEvidenceSyncServiceTests: XCTestCase {
    func testQueuesSavedLocationEvidenceAsAnImmutableLocationEvidenceEvent() throws {
        let (service, enqueued) = makeService()
        let result = try service.enqueue(EVIDENCE)

        guard case .ok(let envelope) = result else { return XCTFail("expected .ok, got \(result)") }
        XCTAssertEqual(enqueued.items.count, 1)
        XCTAssertEqual(envelope.opId, "op-0")
        XCTAssertEqual(envelope.kind, .event)
        XCTAssertEqual(envelope.type, "location.evidence")
        XCTAssertEqual(envelope.localSeq, 0)
        XCTAssertEqual(envelope.dependsOn, [])
        XCTAssertEqual(envelope.payload, EVIDENCE)
        XCTAssertNil(envelope.precondition)
        XCTAssertNoThrow(try assertEnvelopeConsistent(envelope))
    }

    func testRefusesAmbiguousEvidenceInsteadOfQueuingAnUnrouteableEvent() throws {
        let (service, enqueued) = makeService()
        var invalid = EVIDENCE
        invalid.id = " "
        invalid.serviceRequestId = ""
        invalid.evidenceType = ""
        let result = try service.enqueue(invalid)
        guard case .invalid(let errors) = result else { return XCTFail("expected .invalid, got \(result)") }
        XCTAssertEqual(
            errors,
            [
                "location evidence id is required",
                "service request is required",
                "evidence type is required",
            ])
        XCTAssertEqual(enqueued.items.count, 0)
    }

    func testOutboxWriteFailurePropagatesAndNeverReturnsOk() {
        let (service, enqueued) = makeService(enqueueFailure: .write)

        XCTAssertThrowsError(try service.enqueue(EVIDENCE)) { error in
            XCTAssertEqual(error as? LocationOutboxFailure, .write)
        }
        XCTAssertTrue(enqueued.items.isEmpty)
    }
}
