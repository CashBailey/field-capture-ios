import FieldContracts
import FieldDomain
// Port of __tests__/dvir-push-e2e.test.ts — ADR-004 first slice (Hub<->Mobile push): a completed
// pre-trip DVIR syncs END TO END through a real FieldWorkflowService -> a durable outbox -> a
// scripted transport, proving:
//   - submitForm() enqueues exactly one append-only `dvir.submit` EVENT op (no precondition);
//   - the transport receives it in the expected shape;
//   - an accepted outcome folds back so the form becomes durable (`accepted`);
//   - a Hub clock-gate rejection (`not_clocked_in`) is recorded as a `rejected` form verbatim,
//     never a crash — even when the client gate was open.
//
// ponytail: the TS original drives this through the REAL `OpsHubSyncTransport` against a scripted
// HTTP `fetch`, to also pin the wire encoding. `OpsHubSyncTransport` lives in `adapters/sync` (App
// target per PORTING.md's module table), out of this port's scope. This is the flagship in-memory
// e2e the task calls out — it is ported here driving the SAME real `FieldWorkflowService`, with a
// harness-local durable outbox playing the `SyncEngine`'s push/fold-back role at the concrete
// `FieldForm` payload the service actually produces (mirroring why `FieldWorkflowService`'s
// `enqueueEvidence` stays concrete instead of re-encoding to `JSONValue` — see that file's header).
import XCTest

@testable import FieldRuntime

private let UNLOCKED = FieldWorkGate.unlocked(
    clockedInSince: "2026-06-10T06:00:00Z", source: "timeclock", employeeId: nil)

private func preTripDvir() -> FieldForm {
    .dvir(
        DvirForm(
            formId: "dvir-1", kind: .preTripDvir, vehicleRef: "truck-7",
            items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)], signatureBlobIds: ["sig-1"]))
}

private func jhaForm() -> FieldForm {
    .jha(
        JhaForm(
            formId: "jha-1", serviceRequestId: "sr-9",
            hazards: [JhaHazard(hazardId: "h1", description: "H2S", mitigation: "monitor")], signatureBlobIds: ["sig-2"]
        ))
}

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

/// Minimal in-memory outbox keyed on opId, fixed at the `FieldForm` payload — the harness-local
/// stand-in for the real `SyncEngine`'s outbox (which is fixed at `JSONValue`), so this e2e proves
/// the SAME state machine (`OutboxItemState`) without a payload re-encode.
private final class VolatileOutboxForForms {
    private(set) var byOpId:
        [String: (
            envelope: OperationEnvelope<FieldForm>, state: OutboxItemState, lastError: String?, rejectionCode: String?
        )] = [:]

    func enqueue(_ envelope: OperationEnvelope<FieldForm>) {
        byOpId[envelope.opId] = (envelope, .pending, nil, nil)
    }

    func duePending() -> [OperationEnvelope<FieldForm>] {
        byOpId.values.filter { $0.state == .pending }.map(\.envelope)
    }

    func markInFlight(_ envelopes: [OperationEnvelope<FieldForm>]) {
        for e in envelopes { byOpId[e.opId]?.state = .inFlight }
    }

    func fold(_ results: [CommandResult<FieldForm>]) {
        for result in results {
            guard var row = byOpId[result.opId] else { continue }
            switch result {
            case .accepted:
                row.state = .accepted
            case .rejected(_, let code, let detail, _):
                row.state = .rejected
                row.rejectionCode = code
                row.lastError = detail ?? code
            case .needsReview(_, let reason):
                row.state = .needsReview
                row.lastError = reason
            }
            byOpId[result.opId] = row
        }
    }

    func item(for opId: String) -> FieldWorkflowOutboxItem? {
        guard let row = byOpId[opId] else { return nil }
        return FieldWorkflowOutboxItem(state: row.state, rejectionCode: row.rejectionCode, lastError: row.lastError)
    }
}

/// Real `FieldWorkflowService` wired to the harness outbox above — the "real service, scripted
/// transport" composition the TS e2e uses, minus the HTTP layer (see file header).
private final class DvirPushHarness {
    let forms = VolatileFieldFormStore()
    let outbox = VolatileOutboxForForms()
    let service: FieldWorkflowService
    let onSubmit: ([OperationEnvelope<FieldForm>]) -> [CommandResult<FieldForm>]
    private(set) var pushedBatches: [[OperationEnvelope<FieldForm>]] = []

    init(onSubmit: @escaping ([OperationEnvelope<FieldForm>]) -> [CommandResult<FieldForm>]) {
        self.onSubmit = onSubmit
        let outbox = self.outbox
        let forms = self.forms
        var seq = 0
        var uuid = 0
        self.service = FieldWorkflowService(
            FieldWorkflowDeps(
                forms: forms, gateState: { UNLOCKED },
                enqueueEvidence: { outbox.enqueue($0) },
                outboxItem: { outbox.item(for: $0) },
                requirements: { WorkflowRequirements(clockInRequired: true, requiredSteps: []) },
                identity: FakeWriteIdentity(
                    deviceInstanceId: "devA",
                    allocateLocalSeqImpl: {
                        defer { seq += 1 }
                        return seq
                    },
                    generateUuidImpl: {
                        defer { uuid += 1 }
                        return "uuid-\(uuid)"
                    }),
                now: { TEST_NOW_2026_06_10_12_00_00Z }))
    }

    /// Mirrors `SyncEngine.pushOnce()`'s submit leg: dispatch every due-pending item as one batch,
    /// mark in-flight, fold the scripted result back.
    @discardableResult
    func pushOnce() -> Int {
        let due = outbox.duePending()
        guard !due.isEmpty else { return 0 }
        outbox.markInFlight(due)
        pushedBatches.append(due)
        outbox.fold(onSubmit(due))
        return due.count
    }
}

final class DvirPushE2ETests: XCTestCase {
    func testACompletedPreTripDvirReachesTheTransportAndReconcilesToAccepted() throws {
        let harness = DvirPushHarness(onSubmit: { batch in
            batch.enumerated().map { i, e in
                .accepted(opId: e.opId, token: ChangeToken(authorityEpoch: 1, commitSeq: i + 1))
            }
        })

        guard case .ok = try harness.service.saveDraft(preTripDvir()) else { return XCTFail() }
        guard case .ok = try harness.service.completeForm("dvir-1") else { return XCTFail() }
        guard case .ok = try harness.service.submitForm("dvir-1") else { return XCTFail() }
        XCTAssertEqual(try harness.forms.get("dvir-1")?.status, .enqueued)

        let submittedCount = harness.pushOnce()
        XCTAssertEqual(submittedCount, 1)

        // Wire contract: exactly one append-only dvir.submit event, no precondition, DvirForm payload.
        XCTAssertEqual(harness.pushedBatches.count, 1)
        XCTAssertEqual(harness.pushedBatches[0].count, 1)
        let op = harness.pushedBatches[0][0]
        XCTAssertEqual(op.type, "dvir.submit")
        XCTAssertEqual(op.kind, .event)
        XCTAssertNil(op.precondition)
        guard case .dvir(let dvir) = op.payload else { return XCTFail("expected dvir payload") }
        XCTAssertEqual(dvir.formId, "dvir-1")
        XCTAssertEqual(dvir.kind, .preTripDvir)
        XCTAssertEqual(dvir.vehicleRef, "truck-7")
        XCTAssertFalse(op.idempotencyKey.isEmpty)

        // Accepted outcome folds back onto the form record: now durable.
        XCTAssertEqual(try harness.service.reconcileOutcomes().accepted, ["dvir-1"])
        XCTAssertEqual(try harness.forms.get("dvir-1")?.status, .accepted)
    }

    func testAHubClockGateRejectionNotClockedInIsRecordedAsARejectedFormNotACrash() throws {
        let harness = DvirPushHarness(onSubmit: { batch in
            batch.map { .rejected(opId: $0.opId, rejectionCode: "not_clocked_in") }
        })

        _ = try harness.service.saveDraft(preTripDvir())
        _ = try harness.service.completeForm("dvir-1")
        _ = try harness.service.submitForm("dvir-1")

        let submittedCount = harness.pushOnce()
        XCTAssertEqual(submittedCount, 1)

        // Server-side rejection is data, not an exception — the form freezes with Hub's verbatim code.
        XCTAssertEqual(try harness.service.reconcileOutcomes().rejected, ["dvir-1"])
        let record = try harness.forms.get("dvir-1")
        XCTAssertEqual(record?.status, .rejected)
        XCTAssertEqual(record?.lastError, "not_clocked_in")
    }

    func testAJhaRidesTheIdenticalPathAndReachesTheTransportAsJhajsaSubmit() throws {
        let harness = DvirPushHarness(onSubmit: { batch in
            batch.enumerated().map { i, e in
                .accepted(opId: e.opId, token: ChangeToken(authorityEpoch: 1, commitSeq: i + 1))
            }
        })

        guard case .ok = try harness.service.saveDraft(jhaForm()) else { return XCTFail() }
        guard case .ok = try harness.service.completeForm("jha-1") else { return XCTFail() }
        guard case .ok = try harness.service.submitForm("jha-1") else { return XCTFail() }
        harness.pushOnce()

        XCTAssertEqual(harness.pushedBatches[0][0].type, "jhajsa.submit")
        XCTAssertEqual(harness.pushedBatches[0][0].kind, .event)
        XCTAssertEqual(try harness.service.reconcileOutcomes().accepted, ["jha-1"])
        XCTAssertEqual(try harness.forms.get("jha-1")?.status, .accepted)
    }

    func testANeedsReviewOutcomeFreezesTheFormWithTheHubReasonNotAccepted() throws {
        let harness = DvirPushHarness(onSubmit: { batch in
            batch.map { .needsReview(opId: $0.opId, reviewReason: "assignment_changed") }
        })

        _ = try harness.service.saveDraft(preTripDvir())
        _ = try harness.service.completeForm("dvir-1")
        _ = try harness.service.submitForm("dvir-1")
        harness.pushOnce()

        let reconciled = try harness.service.reconcileOutcomes()
        XCTAssertEqual(reconciled.needsReview, ["dvir-1"])
        XCTAssertEqual(reconciled.accepted, [])
        let record = try harness.forms.get("dvir-1")
        XCTAssertEqual(record?.status, .needsReview)
        XCTAssertEqual(record?.lastError, "assignment_changed")
    }
}
