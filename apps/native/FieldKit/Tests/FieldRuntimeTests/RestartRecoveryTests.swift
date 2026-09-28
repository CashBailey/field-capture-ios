import FieldContracts
import FieldDomain
// Port of __tests__/runtime.test.ts (recoverEvidenceOnStartup describe block) — boot sweep:
// in-flight -> retry, pending -> retry, terminal stays.
import XCTest

@testable import FieldRuntime

let RUNTIME_TEST_T0 = ISO8601DateFormatter.parseUtc("2026-06-10T18:00:00Z")

func runtimeTestEvidence(
    _ localSeq: Int, _ state: OutboxItemState,
    lastRejectionCode: String? = nil, lastTransientReason: String? = nil,
    attempts: Int = 0, nextAttemptAtMs: Int64? = nil
) -> TicketEvidence {
    let idempotencyKey = try! buildIdempotencyKey("devA", localSeq, "op-\(localSeq)")
    let at = isoStamp(RUNTIME_TEST_T0)
    let envelope = OperationEnvelope<HubFieldTicketSubmission>(
        opId: "op-\(localSeq)", kind: .command, type: "ticket.submit", idempotencyKey: idempotencyKey,
        localSeq: localSeq, dependsOn: [],
        payload: HubFieldTicketSubmission(
            idempotencyKey: idempotencyKey, serviceRequestId: "sr-\(localSeq)", snapshotHash: "hash-\(localSeq)",
            ticketNo: "T-\(localSeq)", quantityBbl: 10, disposalTicketNo: "D-\(localSeq)"))
    return TicketEvidence(
        envelope: envelope, state: state, attempts: attempts, createdAt: at, updatedAt: at,
        lastRejectionCode: lastRejectionCode, lastTransientReason: lastTransientReason, nextAttemptAtMs: nextAttemptAtMs
    )
}

final class RestartRecoveryTests: XCTestCase {
    func testSweepsOrphanedInFlightRowsToPendingAndLeavesEverythingElseAlone() {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .inFlight, attempts: 2))
        store.save(runtimeTestEvidence(1, .pending))
        store.save(runtimeTestEvidence(2, .accepted))
        store.save(runtimeTestEvidence(3, .rejected))
        store.save(runtimeTestEvidence(4, .needsReview))

        let recovery = recoverEvidenceOnStartup(store) {
            Date(timeIntervalSince1970: RUNTIME_TEST_T0.timeIntervalSince1970 + 1)
        }

        XCTAssertEqual(recovery.recoveredKeys, ["gtr:devA:0:op-0"])
        let recovered = store.get("gtr:devA:0:op-0")
        XCTAssertEqual(recovered?.state, .pending)
        XCTAssertEqual(recovered?.attempts, 3)  // the interrupted attempt counts
        XCTAssertEqual(recovered?.lastTransientReason, "restart-interrupted")
        XCTAssertEqual(store.get("gtr:devA:1:op-1")?.state, .pending)
        XCTAssertEqual(store.get("gtr:devA:2:op-2")?.state, .accepted)
        XCTAssertEqual(store.get("gtr:devA:3:op-3")?.state, .rejected)
        XCTAssertEqual(store.get("gtr:devA:4:op-4")?.state, .needsReview)
    }

    func testUnblocksTheDoubleSubmitGuardARecoveredOpCanBeResubmittedWithTheSameKey() async throws {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .inFlight))
        _ = recoverEvidenceOnStartup(store)
        let submitter = QueueSubmitter([.accepted(duplicate: true, snapshotDrift: nil, ticketId: nil)])
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: submitter, evidenceStore: store),
            try inputFromEvidence(store.get("gtr:devA:0:op-0")!))
        guard case .accepted(let duplicate, _, _) = result else { return XCTFail("expected accepted, got \(result)") }
        XCTAssertTrue(duplicate)
        XCTAssertEqual(submitter.calls.items.first?.idempotencyKey, "gtr:devA:0:op-0")
    }

    func testKeepsABlockedRejectionCodeThroughTheSweepStillUserActionGatedAfterRestart() {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .inFlight, lastRejectionCode: "not_clocked_in"))
        _ = recoverEvidenceOnStartup(store)
        let swept = store.get("gtr:devA:0:op-0")
        XCTAssertEqual(swept?.state, .pending)
        XCTAssertEqual(swept?.lastRejectionCode, "not_clocked_in")
        XCTAssertFalse(isAutoRetryable(swept!))
    }
}
