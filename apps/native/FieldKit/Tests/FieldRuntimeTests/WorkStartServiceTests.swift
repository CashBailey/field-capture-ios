import FieldContracts
import FieldDomain
// Port of __tests__/work-start-service.test.ts
import XCTest

@testable import FieldRuntime

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

private let UNLOCKED = FieldWorkGate.unlocked(
    clockedInSince: "2026-06-10T06:00:00Z", source: "timeclock", employeeId: "emp-1")
private let LOCKED = FieldWorkGate.locked(reason: .notClockedIn, detail: nil)

private enum WorkStartOutboxFailure: Error, Equatable {
    case write
}

private func makeService(gate: FieldWorkGate = UNLOCKED, enqueueFailure: WorkStartOutboxFailure? = nil) -> (
    service: WorkStartService, enqueued: Box<OperationEnvelope<WorkStartEvent>>
) {
    let enqueued = Box<OperationEnvelope<WorkStartEvent>>()
    var seq = 0
    var uuid = 0
    let service = WorkStartService(
        WorkStartServiceDeps(
            gateState: { gate },
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
                }),
            now: { TEST_NOW_2026_06_10_12_00_00Z }))
    return (service, enqueued)
}

final class WorkStartServiceTests: XCTestCase {
    func testQueuesAnImmutableWorkStartEventWithCoherentWriteIdentity() throws {
        let (service, enqueued) = makeService()
        let result = try service.startWork(WorkStartInput(serviceRequestId: "sr-9", actorRef: "emp-1"))

        guard case .ok(let envelope) = result else { return XCTFail("expected .ok, got \(result)") }
        XCTAssertEqual(enqueued.items.count, 1)
        XCTAssertEqual(envelope.opId, "op-0")
        XCTAssertEqual(envelope.kind, .event)
        XCTAssertEqual(envelope.type, "work.start")
        XCTAssertEqual(envelope.localSeq, 0)
        XCTAssertEqual(envelope.dependsOn, [])
        XCTAssertEqual(envelope.payload.eventId, "op-0")
        XCTAssertEqual(envelope.payload.srId, "sr-9")
        XCTAssertEqual(envelope.payload.kind, .workEventSubmitted)
        XCTAssertEqual(envelope.payload.actorRef, "emp-1")
        XCTAssertEqual(envelope.payload.occurredAt, "2026-06-10T12:00:00.000Z")
        XCTAssertNil(envelope.precondition)
        XCTAssertNoThrow(try assertEnvelopeConsistent(envelope))
    }

    func testKeepsWorkStartNonActionableWhileTheClockGateIsLocked() throws {
        let (service, enqueued) = makeService(gate: LOCKED)
        let result = try service.startWork(WorkStartInput(serviceRequestId: "sr-9", actorRef: "emp-1"))
        guard case .locked(let reason) = result else { return XCTFail("expected .locked, got \(result)") }
        XCTAssertEqual(reason, "not-clocked-in")
        XCTAssertEqual(enqueued.items.count, 0)
    }

    func testRefusesEmptyIdsInsteadOfQueuingAmbiguousEvidence() throws {
        let (service, enqueued) = makeService()
        let result = try service.startWork(WorkStartInput(serviceRequestId: " ", actorRef: ""))
        guard case .invalid(let errors) = result else { return XCTFail("expected .invalid, got \(result)") }
        XCTAssertEqual(errors, ["service request is required", "actor is required"])
        XCTAssertEqual(enqueued.items.count, 0)
    }

    func testOutboxWriteFailurePropagatesAndNeverReturnsOk() {
        let (service, enqueued) = makeService(enqueueFailure: .write)

        XCTAssertThrowsError(
            try service.startWork(WorkStartInput(serviceRequestId: "sr-9", actorRef: "emp-1"))
        ) { error in
            XCTAssertEqual(error as? WorkStartOutboxFailure, .write)
        }
        XCTAssertTrue(enqueued.items.isEmpty)
    }
}
