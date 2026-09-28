import Foundation
import FieldContracts
import FieldDomain
// Port of __tests__/field-workflow.test.ts — DVIR / JHA-JSA workflow runtime: drafts durable,
// completion validated, completed forms synced as append-only evidence through the durable outbox,
// Hub-required steps gate ticket submission, the clock gate locks every field action, and
// needs-review outcomes are preserved frozen with Hub's verbatim reason.
//
// ponytail: the TS "persists a draft durably (real SQLite)" sub-test exercises `SqliteFieldFormStore`
// (FieldData) — not yet ported to Swift at the time of this port (owned by a concurrent agent).
// `VolatileFieldFormStore` (FieldDomain) satisfies the SAME `FieldFormStore` protocol the service
// depends on, so it stands in here; what this test actually asserts (saveDraft round-trips through
// the store) is unaffected by which conforming store backs it.
import XCTest

@testable import FieldRuntime

private let UNLOCKED = FieldWorkGate.unlocked(
    clockedInSince: "2026-06-10T06:00:00Z", source: "timeclock", employeeId: nil)
private let LOCKED = FieldWorkGate.locked(reason: .notClockedIn, detail: nil)

private let ALL_REQUIRED = WorkflowRequirements(
    clockInRequired: true, requiredSteps: [.preTripDvir, .jha, .postTripDvir])

private func dvirForm(
    formId: String = "dvir-1", kind: DvirKind = .preTripDvir, vehicleRef: String = "truck-7",
    items: [InspectionItem] = [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
    defectsCertifiedSafe: Bool? = nil, signatureBlobIds: [String] = ["sig-1"],
    completedAt: String? = nil
) -> FieldForm {
    .dvir(
        DvirForm(
            formId: formId, kind: kind, vehicleRef: vehicleRef, items: items,
            defectsCertifiedSafe: defectsCertifiedSafe, signatureBlobIds: signatureBlobIds,
            completedAt: completedAt))
}

private func jhaForm(
    formId: String = "jha-1", serviceRequestId: String = "sr-9",
    hazards: [JhaHazard] = [JhaHazard(hazardId: "h1", description: "H2S", mitigation: "monitor")],
    signatureBlobIds: [String] = ["sig-2"], completedAt: String? = nil
) -> FieldForm {
    .jha(
        JhaForm(
            formId: formId, serviceRequestId: serviceRequestId, hazards: hazards,
            signatureBlobIds: signatureBlobIds, completedAt: completedAt))
}

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

private final class Outcomes {
    var byOpId: [String: FieldWorkflowOutboxItem] = [:]
}

private enum TestEnqueueError: Error {
    case writeFailed
}

private struct TestStorageError: Error, Equatable {
    let operation: String
}

private extension FieldForm {
    var testFormId: String {
        switch self {
        case .dvir(let dvir): return dvir.formId
        case .jha(let jha): return jha.formId
        }
    }
}

/// A transaction-aware failure seam. Its outbox array participates in the same snapshot as the
/// form records, mirroring production's shared SQLite transaction.
private final class InjectedFailureFieldFormStore: FieldFormStore {
    let durability: StoreDurability = .durablePlain
    private var records: [String: FieldFormRecord] = [:]
    private(set) var outbox: [OperationEnvelope<FieldForm>] = []
    var failNextOperation: String?

    private func checkFailure(_ operation: String) throws {
        guard failNextOperation == operation else { return }
        failNextOperation = nil
        throw TestStorageError(operation: operation)
    }

    func transaction(_ body: () throws -> Void) throws {
        try checkFailure("transaction")
        let recordsSnapshot = records
        let outboxSnapshot = outbox
        do {
            try body()
        } catch {
            records = recordsSnapshot
            outbox = outboxSnapshot
            throw error
        }
    }

    func save(_ record: FieldFormRecord) throws {
        try checkFailure("save-\(record.status.rawValue)")
        records[record.form.testFormId] = record
    }

    func get(_ formId: String) throws -> FieldFormRecord? {
        try checkFailure("get")
        return records[formId]
    }

    func list() throws -> [FieldFormRecord] {
        try checkFailure("list")
        return Array(records.values)
    }

    func listByStatus(_ status: FieldFormStatus) throws -> [FieldFormRecord] {
        try checkFailure("list-by-status")
        return records.values.filter { $0.status == status }
    }

    func enqueue(_ envelope: OperationEnvelope<FieldForm>) {
        outbox.append(envelope)
    }
}

private func saveSatisfyingForm(_ form: FieldForm, to store: FieldFormStore) throws {
    try store.save(
        FieldFormRecord(
            form: form, status: .completed,
            createdAt: "2026-06-10T00:00:00Z", updatedAt: "2026-06-10T00:00:00Z"))
}

private func assertStorageFailure(
    _ error: Error,
    operation: FieldWorkflowStorageOperation,
    formId: String?
) {
    guard let workflowError = error as? FieldWorkflowError,
        case .storage(let actualOperation, let actualFormId, let detail) = workflowError
    else {
        return XCTFail("expected a field-workflow storage error, got \(error)")
    }
    XCTAssertEqual(actualOperation, operation)
    XCTAssertEqual(actualFormId, formId)
    XCTAssertFalse(detail.isEmpty)
}

private func makeService(
    gate: FieldWorkGate = UNLOCKED, forms: FieldFormStore? = nil,
    requirements: WorkflowRequirements = ALL_REQUIRED,
    enqueueEvidence: ((OperationEnvelope<FieldForm>) throws -> Void)? = nil,
    outboxItem: ((String) throws -> FieldWorkflowOutboxItem?)? = nil
) -> (
    service: FieldWorkflowService, forms: FieldFormStore, enqueued: Box<OperationEnvelope<FieldForm>>,
    outcomes: Outcomes
) {
    let forms = forms ?? VolatileFieldFormStore()
    let enqueued = Box<OperationEnvelope<FieldForm>>()
    let outcomes = Outcomes()
    let enqueueEvidence = enqueueEvidence ?? { enqueued.items.append($0) }
    let outboxItem = outboxItem ?? { outcomes.byOpId[$0] }
    var seq = 0
    var uuid = 0
    let service = FieldWorkflowService(
        FieldWorkflowDeps(
            forms: forms, gateState: { gate }, enqueueEvidence: enqueueEvidence,
            outboxItem: outboxItem, requirements: { requirements },
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
    return (service, forms, enqueued, outcomes)
}

final class FieldWorkflowTests: XCTestCase {
    // MARK: draft save

    func testPersistsADraftDurablyAndRoundTripsIt() throws {
        let forms = VolatileFieldFormStore()
        let (service, _, _, _) = makeService(forms: forms)

        let result = try service.saveDraft(dvirForm(items: [InspectionItem(itemId: "brakes", label: "Brakes")]))
        guard case .ok = result else { return XCTFail("expected ok") }
        XCTAssertEqual(try forms.get("dvir-1")?.status, .draft)
        guard case .dvir(let dvir) = try forms.get("dvir-1")?.form else { return XCTFail("expected dvir") }
        XCTAssertEqual(dvir.kind, .preTripDvir)
        XCTAssertEqual(dvir.vehicleRef, "truck-7")
    }

    func testSaveDraftSurfacesReadAndWriteFailuresAndCanBeRetried() throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, _) = makeService(forms: store)

        store.failNextOperation = "get"
        XCTAssertThrowsError(try service.saveDraft(dvirForm())) {
            assertStorageFailure($0, operation: .saveDraft, formId: "dvir-1")
        }

        store.failNextOperation = "save-draft"
        XCTAssertThrowsError(try service.saveDraft(dvirForm())) {
            assertStorageFailure($0, operation: .saveDraft, formId: "dvir-1")
        }

        guard case .ok = try service.saveDraft(dvirForm()) else {
            return XCTFail("expected a retry to save")
        }
        XCTAssertEqual(try store.get("dvir-1")?.status, .draft)
    }

    func testCompleteFormSurfacesWriteFailureWithoutFalselyCompletingTheDraft() throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, _) = makeService(forms: store)
        _ = try service.saveDraft(dvirForm())

        store.failNextOperation = "save-completed"
        XCTAssertThrowsError(try service.completeForm("dvir-1")) {
            assertStorageFailure($0, operation: .completeForm, formId: "dvir-1")
        }
        XCTAssertEqual(try store.get("dvir-1")?.status, .draft)

        guard case .ok = try service.completeForm("dvir-1") else {
            return XCTFail("expected completion retry to succeed")
        }
    }

    func testALockedClockGateMakesEveryFieldActionNonActionableWithTheReasonSurfaced() throws {
        let (service, _, _, _) = makeService(gate: LOCKED)
        guard case .locked(let r1) = try service.saveDraft(dvirForm()) else { return XCTFail() }
        XCTAssertEqual(r1, "not-clocked-in")
        guard case .locked(let r2) = try service.completeForm("dvir-1") else { return XCTFail() }
        XCTAssertEqual(r2, "not-clocked-in")
        guard case .locked(let r3) = try service.submitForm("dvir-1") else { return XCTFail() }
        XCTAssertEqual(r3, "not-clocked-in")
        guard case .locked(let r4) = try service.guardTicketSubmit("sr-9") else { return XCTFail() }
        XCTAssertEqual(r4, "not-clocked-in")
    }

    // MARK: required step completion

    func testAnIncompleteFormRefusesCompletionWithTheExactReasons() throws {
        let (service, _, _, _) = makeService()
        _ = try service.saveDraft(
            dvirForm(items: [InspectionItem(itemId: "brakes", label: "Brakes")], signatureBlobIds: []))
        guard case .invalid(let errors) = try service.completeForm("dvir-1") else { return XCTFail("expected invalid") }
        XCTAssertTrue(errors.contains("inspection item brakes is unanswered"))
        XCTAssertTrue(errors.contains("DVIR needs the driver's signature"))
    }

    func testAJhaWithoutASignatureNeverCompletes() throws {
        let (service, _, _, _) = makeService()
        _ = try service.saveDraft(jhaForm(signatureBlobIds: []))
        guard case .invalid = try service.completeForm("jha-1") else { return XCTFail("expected invalid") }
    }

    func testAValidFormCompletesAndIsStamped() throws {
        let (service, forms, _, _) = makeService()
        _ = try service.saveDraft(dvirForm())
        guard case .ok = try service.completeForm("dvir-1") else { return XCTFail("expected ok") }
        XCTAssertEqual(try forms.get("dvir-1")?.status, .completed)
        guard case .dvir(let dvir) = try forms.get("dvir-1")?.form else { return XCTFail() }
        XCTAssertNotNil(dvir.completedAt)
    }

    // MARK: offline capture -> append-only evidence

    func testSubmitFormEnqueuesAnAppendOnlyEventWithRealWriteIdentityRecordFreezes() throws {
        let (service, forms, enqueued, _) = makeService()
        _ = try service.saveDraft(jhaForm())
        _ = try service.completeForm("jha-1")
        guard case .ok = try service.submitForm("jha-1") else { return XCTFail("expected ok") }

        XCTAssertEqual(enqueued.items.count, 1)
        XCTAssertEqual(enqueued.items[0].kind, .event)
        XCTAssertEqual(enqueued.items[0].type, "jhajsa.submit")
        XCTAssertEqual(enqueued.items[0].dependsOn, [])
        XCTAssertNil(enqueued.items[0].precondition)
        XCTAssertNoThrow(try assertEnvelopeConsistent(enqueued.items[0]))
        XCTAssertEqual(try forms.get("jha-1")?.status, .enqueued)
        XCTAssertEqual(try forms.get("jha-1")?.opId, enqueued.items[0].opId)

        // Frozen: append-only evidence is never edited or re-submitted.
        guard case .frozen = try service.saveDraft(jhaForm()) else { return XCTFail("expected frozen") }
        guard case .frozen = try service.submitForm("jha-1") else { return XCTFail("expected frozen") }
        XCTAssertEqual(enqueued.items.count, 1)
    }

    func testTheEnqueueIsLocalItWorksWithTheTransportOfflineNothingMarkedDurable() throws {
        let (service, forms, _, _) = makeService()
        _ = try service.saveDraft(dvirForm())
        _ = try service.completeForm("dvir-1")
        _ = try service.submitForm("dvir-1")
        _ = try service.reconcileOutcomes()
        XCTAssertEqual(try forms.get("dvir-1")?.status, .enqueued)  // owed to Hub, preserved
    }

    func testFailedEvidenceEnqueueLeavesTheCompletedFormRetryableAndUnfrozen() throws {
        var enqueueAttempts = 0
        let (service, forms, _, _) = makeService(
            enqueueEvidence: { _ in
                enqueueAttempts += 1
                if enqueueAttempts == 1 { throw TestEnqueueError.writeFailed }
            })
        _ = try service.saveDraft(dvirForm())
        _ = try service.completeForm("dvir-1")

        XCTAssertThrowsError(try service.submitForm("dvir-1")) { error in
            guard let workflowError = error as? FieldWorkflowError,
                case .evidenceEnqueue(let formId, let detail) = workflowError
            else {
                return XCTFail("expected an evidence-enqueue error")
            }
            XCTAssertEqual(formId, "dvir-1")
            XCTAssertTrue(detail.contains("writeFailed"))
        }
        XCTAssertEqual(try forms.get("dvir-1")?.status, .completed)
        XCTAssertNil(try forms.get("dvir-1")?.opId)

        guard case .ok = try service.submitForm("dvir-1") else {
            return XCTFail("expected retry to enqueue")
        }
        XCTAssertEqual(enqueueAttempts, 2)
        XCTAssertEqual(try forms.get("dvir-1")?.status, .enqueued)
        XCTAssertNotNil(try forms.get("dvir-1")?.opId)
    }

    func testSubmitFormRollsBackOutboxAndFormWhenItsStateWriteFails() throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, _) = makeService(
            forms: store,
            enqueueEvidence: { store.enqueue($0) })
        _ = try service.saveDraft(dvirForm())
        _ = try service.completeForm("dvir-1")

        store.failNextOperation = "save-enqueued"
        XCTAssertThrowsError(try service.submitForm("dvir-1")) {
            assertStorageFailure($0, operation: .submitForm, formId: "dvir-1")
        }
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(try store.get("dvir-1")?.status, .completed)

        guard case .ok = try service.submitForm("dvir-1") else {
            return XCTFail("expected submission retry to succeed")
        }
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertEqual(try store.get("dvir-1")?.status, .enqueued)
    }

    func testADraftCannotBeSubmittedBeforeCompletion() throws {
        let (service, _, _, _) = makeService()
        _ = try service.saveDraft(dvirForm())
        guard case .invalid = try service.submitForm("dvir-1") else { return XCTFail("expected invalid") }
    }

    // MARK: outcome reconciliation

    private func enqueuedForm(
        _ s: (
            service: FieldWorkflowService, forms: FieldFormStore, enqueued: Box<OperationEnvelope<FieldForm>>,
            outcomes: Outcomes
        )
    ) throws -> String {
        _ = try s.service.saveDraft(jhaForm())
        _ = try s.service.completeForm("jha-1")
        _ = try s.service.submitForm("jha-1")
        return try s.forms.get("jha-1")!.opId!
    }

    func testAcceptedIsDurable() throws {
        let s = makeService()
        let opId = try enqueuedForm(s)
        s.outcomes.byOpId[opId] = FieldWorkflowOutboxItem(state: .accepted)
        XCTAssertEqual(try s.service.reconcileOutcomes().accepted, ["jha-1"])
        XCTAssertEqual(try s.forms.get("jha-1")?.status, .accepted)
    }

    func testNeedsReviewIsPreservedFrozenWithHubsReasonStepNoLongerSatisfied() throws {
        let s = makeService()
        let opId = try enqueuedForm(s)
        s.outcomes.byOpId[opId] = FieldWorkflowOutboxItem(state: .needsReview, lastError: "assignment_changed")
        XCTAssertEqual(try s.service.reconcileOutcomes().needsReview, ["jha-1"])
        let record = try s.forms.get("jha-1")
        XCTAssertEqual(record?.status, .needsReview)
        XCTAssertEqual(record?.lastError, "assignment_changed")
        guard case .jha(let jha) = record?.form else { return XCTFail() }
        XCTAssertEqual(jha.formId, "jha-1")  // payload preserved, never wiped
        // Flagged safety evidence does NOT greenlight more work on that SR.
        XCTAssertNil(try s.service.completedSteps().jhaFormIdByServiceRequest["sr-9"])
        // And it stays frozen against edits.
        guard case .frozen = try s.service.saveDraft(jhaForm()) else { return XCTFail("expected frozen") }
    }

    func testRejectedIsPreservedFrozenWithTheRejectionCodeVerbatim() throws {
        let s = makeService()
        let opId = try enqueuedForm(s)
        s.outcomes.byOpId[opId] = FieldWorkflowOutboxItem(state: .rejected, rejectionCode: "locked_sr")
        XCTAssertEqual(try s.service.reconcileOutcomes().rejected, ["jha-1"])
        XCTAssertEqual(try s.forms.get("jha-1")?.status, .rejected)
        XCTAssertEqual(try s.forms.get("jha-1")?.lastError, "locked_sr")
    }

    func testReconcileFailuresRemainVisibleAndRetryable() throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, outcomes) = makeService(
            forms: store,
            enqueueEvidence: { store.enqueue($0) })
        _ = try service.saveDraft(jhaForm())
        _ = try service.completeForm("jha-1")
        _ = try service.submitForm("jha-1")
        let opId = try XCTUnwrap(store.get("jha-1")?.opId)
        outcomes.byOpId[opId] = FieldWorkflowOutboxItem(state: .accepted)

        store.failNextOperation = "list-by-status"
        XCTAssertThrowsError(try service.reconcileOutcomes()) {
            assertStorageFailure($0, operation: .listEnqueuedForms, formId: nil)
        }

        store.failNextOperation = "save-accepted"
        XCTAssertThrowsError(try service.reconcileOutcomes()) {
            assertStorageFailure($0, operation: .reconcileForm, formId: "jha-1")
        }
        XCTAssertEqual(try store.get("jha-1")?.status, .enqueued)

        XCTAssertEqual(try service.reconcileOutcomes().accepted, ["jha-1"])
        XCTAssertEqual(try store.get("jha-1")?.status, .accepted)
    }

    func testReconcileSurfacesOutboxReadFailures() throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, _) = makeService(
            forms: store,
            enqueueEvidence: { store.enqueue($0) },
            outboxItem: { _ in throw TestStorageError(operation: "outbox-get") })
        _ = try service.saveDraft(jhaForm())
        _ = try service.completeForm("jha-1")
        _ = try service.submitForm("jha-1")

        XCTAssertThrowsError(try service.reconcileOutcomes()) {
            assertStorageFailure($0, operation: .readOutboxOutcome, formId: "jha-1")
        }
        XCTAssertEqual(try store.get("jha-1")?.status, .enqueued)
    }

    // MARK: ticket submit gating

    func testHistoricalSafePreTripDoesNotUnlockTheCurrentClockSession() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(
                items: [
                    InspectionItem(
                        itemId: "brakes", label: "Brakes", result: .defect,
                        note: "adjusted")
                ],
                defectsCertifiedSafe: true,
                completedAt: "2026-06-10T05:59:59Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(
                clockInRequired: true, requiredSteps: [.preTripDvir]))

        XCTAssertNil(try service.completedSteps().preTripDvirFormId)
        guard case .blocked(let missing) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected historical DVIR to be ignored")
        }
        XCTAssertEqual(missing, [.preTripDvir])
    }

    func testHistoricalUnsafePreTripDoesNotPermanentlyBlockTheCurrentClockSession() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(
                items: [
                    InspectionItem(
                        itemId: "brakes", label: "Brakes", result: .defect,
                        note: "soft pedal")
                ],
                defectsCertifiedSafe: false,
                completedAt: "2026-06-09T18:00:00Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))

        XCTAssertNil(try service.completedSteps().preTripVehicleUnsafe)
        guard case .allowed = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected historical unsafe DVIR to be ignored")
        }
    }

    func testCurrentSessionDvirAndJhaSatisfyTheirExactServiceRequest() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(completedAt: "2026-06-10T06:00:00Z"),
            to: forms)
        try saveSatisfyingForm(
            jhaForm(completedAt: "2026-06-10T08:00:00Z"),
            to: forms)
        try saveSatisfyingForm(
            jhaForm(
                formId: "jha-other", serviceRequestId: "sr-other",
                completedAt: "2026-06-10T09:00:00Z"),
            to: forms)
        let (service, _, _, _) = makeService(forms: forms)

        let completed = try service.completedSteps()
        XCTAssertEqual(completed.preTripDvirFormId, "dvir-1")
        XCTAssertEqual(completed.jhaFormIdByServiceRequest["sr-9"], "jha-1")
        XCTAssertEqual(completed.jhaFormIdByServiceRequest["sr-other"], "jha-other")
        guard case .allowed = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected current-session evidence to satisfy the gate")
        }
    }

    func testAnotherVehiclesSafePreTripCannotUnlockTheRequestedVehicle() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(
                formId: "dvir-truck-7",
                vehicleRef: "truck-7",
                completedAt: "2026-06-10T08:00:00Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))

        XCTAssertEqual(try service.completedSteps().preTripDvirFormId, "dvir-truck-7")
        XCTAssertNil(try service.completedSteps(vehicleRef: "truck-8").preTripDvirFormId)
        guard
            case .blocked(let missing) = try service.guardTicketSubmit(
                "sr-9", vehicleRef: "truck-8")
        else {
            return XCTFail("expected truck-8 to require its own pre-trip")
        }
        XCTAssertEqual(missing, [.preTripDvir])

        // Compatibility API retains its prior requirement-driven behavior.
        guard case .allowed = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected the legacy guard to remain compatible")
        }
    }

    func testAnotherVehiclesUnsafePreTripDoesNotBlockTheRequestedSafeVehicle() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(
                formId: "dvir-truck-7-unsafe",
                vehicleRef: "truck-7",
                items: [
                    InspectionItem(
                        itemId: "brakes", label: "Brakes", result: .defect,
                        note: "soft pedal")
                ],
                defectsCertifiedSafe: false,
                completedAt: "2026-06-10T08:00:00Z"),
            to: forms)
        try saveSatisfyingForm(
            dvirForm(
                formId: "dvir-truck-8-safe",
                vehicleRef: "truck-8",
                completedAt: "2026-06-10T09:00:00Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))

        let truck8 = try service.completedSteps(vehicleRef: "truck-8")
        XCTAssertEqual(truck8.preTripDvirFormId, "dvir-truck-8-safe")
        XCTAssertNil(truck8.preTripVehicleUnsafe)
        guard case .allowed = try service.guardTicketSubmit("sr-9", vehicleRef: "truck-8") else {
            return XCTFail("expected truck-8 to remain usable")
        }

        guard
            case .vehicleUnsafe(let reviewRequired) = try service.guardTicketSubmit(
                "sr-9", vehicleRef: "truck-7")
        else {
            return XCTFail("expected truck-7's own unsafe pre-trip to block it")
        }
        XCTAssertTrue(reviewRequired)
    }

    func testVehicleAwareSubmitHandoffFailsClosedUntilThatVehicleHasAPreTrip() async throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(
                formId: "dvir-truck-7",
                vehicleRef: "truck-7",
                completedAt: "2026-06-10T08:00:00Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        var submitCount = 0

        let missingResult = try await service.submitTicketWithWorkflow(
            "sr-9", vehicleRef: "truck-8"
        ) {
            submitCount += 1
            return "submitted"
        }
        guard case .blocked(let missing) = missingResult else {
            return XCTFail("expected truck-8 to remain blocked")
        }
        XCTAssertEqual(missing, [.preTripDvir])
        XCTAssertEqual(submitCount, 0)

        let allowedResult = try await service.submitTicketWithWorkflow(
            "sr-9", vehicleRef: "truck-7"
        ) {
            submitCount += 1
            return "submitted"
        }
        guard case .submitted(let value) = allowedResult else {
            return XCTFail("expected truck-7 submission to run")
        }
        XCTAssertEqual(value, "submitted")
        XCTAssertEqual(submitCount, 1)
    }

    func testMissingOrMalformedCompletionTimestampsNeverSatisfyTheGate() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(dvirForm(completedAt: nil), to: forms)
        try saveSatisfyingForm(jhaForm(completedAt: "not-a-timestamp"), to: forms)
        let (service, _, _, _) = makeService(forms: forms)

        let completed = try service.completedSteps()
        XCTAssertNil(completed.preTripDvirFormId)
        XCTAssertTrue(completed.jhaFormIdByServiceRequest.isEmpty)
        guard case .blocked(let missing) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected timestamp-less evidence to be ignored")
        }
        XCTAssertEqual(missing, [.preTripDvir, .jhaJsa])
    }

    func testFutureDatedEvidenceFailsClosed() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(completedAt: "2026-06-10T12:00:01Z"),
            to: forms)
        let (service, _, _, _) = makeService(
            forms: forms,
            requirements: WorkflowRequirements(
                clockInRequired: true, requiredSteps: [.preTripDvir]))

        XCTAssertNil(try service.completedSteps().preTripDvirFormId)
        guard case .blocked(let missing) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected future-dated evidence to be ignored")
        }
        XCTAssertEqual(missing, [.preTripDvir])
    }

    func testCompletedStepReadFailuresBlockGuardAndSubmitHandoff() async throws {
        let store = InjectedFailureFieldFormStore()
        let (service, _, _, _) = makeService(
            forms: store,
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))

        store.failNextOperation = "list"
        XCTAssertThrowsError(try service.completedSteps()) {
            assertStorageFailure($0, operation: .listCompletedSteps, formId: nil)
        }

        store.failNextOperation = "list"
        XCTAssertThrowsError(try service.guardTicketSubmit("sr-9")) {
            assertStorageFailure($0, operation: .listCompletedSteps, formId: nil)
        }

        var submitted = false
        store.failNextOperation = "list"
        do {
            _ = try await service.submitTicketWithWorkflow("sr-9") {
                submitted = true
            }
            XCTFail("expected storage failure")
        } catch {
            assertStorageFailure(error, operation: .listCompletedSteps, formId: nil)
        }
        XCTAssertFalse(submitted)
    }

    func testMissingHubClockTimestampFallsBackToCurrentCalendarDayOnly() throws {
        let forms = VolatileFieldFormStore()
        let dayStart = Calendar.current.startOfDay(for: TEST_NOW_2026_06_10_12_00_00Z)
        try saveSatisfyingForm(
            dvirForm(completedAt: isoStamp(dayStart.addingTimeInterval(-1))),
            to: forms)
        try saveSatisfyingForm(
            jhaForm(completedAt: isoStamp(dayStart)),
            to: forms)
        let gate = FieldWorkGate.unlocked(
            clockedInSince: nil, source: "timeclock", employeeId: nil)
        let (service, _, _, _) = makeService(gate: gate, forms: forms)

        let completed = try service.completedSteps()
        XCTAssertNil(completed.preTripDvirFormId)
        XCTAssertEqual(completed.jhaFormIdByServiceRequest["sr-9"], "jha-1")
    }

    func testMalformedHubClockTimestampFailsClosedInsteadOfUsingDayFallback() throws {
        let forms = VolatileFieldFormStore()
        try saveSatisfyingForm(
            dvirForm(completedAt: "2026-06-10T08:00:00Z"),
            to: forms)
        let gate = FieldWorkGate.unlocked(
            clockedInSince: "not-a-timestamp", source: "timeclock", employeeId: nil)
        let (service, _, _, _) = makeService(gate: gate, forms: forms)

        XCTAssertNil(try service.completedSteps().preTripDvirFormId)
    }

    func testBlocksTicketSubmissionListingTheExactMissingHubRequiredSteps() throws {
        let (service, _, _, _) = makeService()
        guard case .blocked(let missing) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(missing, [.preTripDvir, .jhaJsa])
    }

    func testSubmitHandoffDelegatesOnlyOnceTheWorkflowAllows() async throws {
        let (service, _, _, _) = makeService()
        var ran = 0
        guard
            case .blocked = try await service.submitTicketWithWorkflow(
                "sr-9",
                {
                    ran += 1
                    return "accepted"
                })
        else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(ran, 0)

        _ = try service.saveDraft(dvirForm())
        _ = try service.completeForm("dvir-1")
        _ = try service.saveDraft(jhaForm())
        _ = try service.completeForm("jha-1")

        guard
            case .submitted(let result) = try await service.submitTicketWithWorkflow(
                "sr-9",
                {
                    ran += 1
                    return "accepted"
                })
        else {
            return XCTFail("expected submitted")
        }
        XCTAssertEqual(result, "accepted")
        XCTAssertEqual(ran, 1)
    }

    func testAJhaForAnotherSrDoesNotUnblockThisSr() throws {
        let (service, _, _, _) = makeService()
        _ = try service.saveDraft(dvirForm())
        _ = try service.completeForm("dvir-1")
        _ = try service.saveDraft(jhaForm(formId: "jha-x", serviceRequestId: "sr-other"))
        _ = try service.completeForm("jha-x")
        guard case .blocked(let missing) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(missing, [.jhaJsa])
    }

    func testWhenHubRequiresNothingTheGateIsOpen() throws {
        let (service, _, _, _) = makeService(
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        guard case .allowed = try service.guardTicketSubmit("sr-9") else { return XCTFail("expected allowed") }
    }

    // MARK: unsafe-vehicle rule

    private func completeUnsafePreTrip(_ service: FieldWorkflowService) throws {
        _ = try service.saveDraft(
            dvirForm(
                items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .defect, note: "soft pedal")],
                defectsCertifiedSafe: false))
        guard case .ok = try service.completeForm("dvir-1") else { return XCTFail("expected ok") }
    }

    func testGuardTicketSubmitReturnsVehicleUnsafeAheadOfTheStepGate() throws {
        let (service, _, _, _) = makeService(
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        try completeUnsafePreTrip(service)
        guard case .vehicleUnsafe(let reviewRequired) = try service.guardTicketSubmit("sr-9") else {
            return XCTFail("expected vehicleUnsafe")
        }
        XCTAssertTrue(reviewRequired)
    }

    func testSubmitTicketWithWorkflowRefusesToRunSubmitWhileTheVehicleIsUnsafe() async throws {
        let (service, _, _, _) = makeService(
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        try completeUnsafePreTrip(service)
        var ran = false
        let result = try await service.submitTicketWithWorkflow("sr-9") {
            ran = true
            return "submitted"
        }
        guard case .vehicleUnsafe(let reviewRequired) = result else { return XCTFail("expected vehicleUnsafe") }
        XCTAssertTrue(reviewRequired)
        XCTAssertFalse(ran)
    }

    func testASafePreTripDvirDefectClearedDoesNotTripTheRule() throws {
        let (service, _, _, _) = makeService(
            requirements: WorkflowRequirements(clockInRequired: true, requiredSteps: []))
        _ = try service.saveDraft(
            dvirForm(
                items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .defect, note: "adjusted")],
                defectsCertifiedSafe: true))
        guard case .ok = try service.completeForm("dvir-1") else { return XCTFail("expected ok") }
        guard case .allowed = try service.guardTicketSubmit("sr-9") else { return XCTFail("expected allowed") }
    }
}
