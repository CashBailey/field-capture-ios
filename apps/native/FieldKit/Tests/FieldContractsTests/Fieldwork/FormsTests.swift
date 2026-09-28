// Port of test/forms.test.ts
import XCTest

@testable import FieldContracts

final class FormsTests: XCTestCase {
    private func makeDvir(
        items: [InspectionItem] = [
            InspectionItem(itemId: "brakes", label: "Brakes", result: .ok),
            InspectionItem(itemId: "lights", label: "Lights", result: .ok),
        ],
        signatureBlobIds: [String] = ["sig-blob-1"],
        defectsCertifiedSafe: Bool? = nil
    ) -> DvirForm {
        DvirForm(
            formId: "dvir-1", kind: .preTripDvir, vehicleRef: "truck-7", items: items,
            defectsCertifiedSafe: defectsCertifiedSafe, signatureBlobIds: signatureBlobIds
        )
    }

    private func makeJha(
        hazards: [JhaHazard] = [JhaHazard(hazardId: "h1", description: "H2S exposure", mitigation: "monitor + PPE")],
        signatureBlobIds: [String] = ["sig-blob-2"]
    ) -> JhaForm {
        JhaForm(formId: "jha-1", serviceRequestId: "sr-9", hazards: hazards, signatureBlobIds: signatureBlobIds)
    }

    // ---- validateFormCompletion — DVIR ----

    func testDvirFullyAnsweredSignedIsCompletable() {
        XCTAssertEqual(validateFormCompletion(.dvir(makeDvir())), [])
    }

    func testDvirUnansweredItemsBlockCompletion() {
        let form = makeDvir(items: [InspectionItem(itemId: "brakes", label: "Brakes")])
        XCTAssertTrue(validateFormCompletion(.dvir(form)).contains("inspection item brakes is unanswered"))
    }

    func testDvirDefectRequiresNoteAndSafeCertification() {
        let form = makeDvir(items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .defect)])
        let errors = validateFormCompletion(.dvir(form))
        XCTAssertTrue(errors.contains("defect on brakes needs a note"))
        XCTAssertTrue(errors.contains("defects present: safe-to-operate certification is required"))

        let certified = makeDvir(
            items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .defect, note: "pads worn")],
            defectsCertifiedSafe: false  // certifying NOT safe is a valid, complete answer
        )
        XCTAssertEqual(validateFormCompletion(.dvir(certified)), [])
    }

    func testDvirUnsignedNeverComplete() {
        XCTAssertTrue(
            validateFormCompletion(.dvir(makeDvir(signatureBlobIds: []))).contains("DVIR needs the driver's signature")
        )
    }

    func testDvirEmptyChecklistNeverComplete() {
        XCTAssertTrue(
            validateFormCompletion(.dvir(makeDvir(items: []))).contains("DVIR needs at least one inspection item")
        )
    }

    // ---- validateFormCompletion — JHA/JSA ----

    func testJhaHazardListedSignedIsCompletable() {
        XCTAssertEqual(validateFormCompletion(.jha(makeJha())), [])
    }

    func testJhaRequiresAtLeastOneHazardWithDescriptionAndMitigation() {
        XCTAssertTrue(validateFormCompletion(.jha(makeJha(hazards: []))).contains("JHA needs at least one hazard"))
        let errors = validateFormCompletion(
            .jha(makeJha(hazards: [JhaHazard(hazardId: "h1", description: "", mitigation: "")])))
        XCTAssertTrue(errors.contains("hazard h1 has no description"))
        XCTAssertTrue(errors.contains("hazard h1 has no mitigation"))
    }

    func testJhaUnsignedNeverComplete() {
        XCTAssertTrue(
            validateFormCompletion(.jha(makeJha(signatureBlobIds: []))).contains("JHA needs at least one signature")
        )
    }

    // ---- parseWorkflowRequirements ----

    func testParseWorkflowRequirementsReadsRealHubShape() {
        let result = parseWorkflowRequirements([
            "clock_in_required": true,
            "required_steps": ["pre_trip_dvir", "jha", "post_trip_dvir"],
        ])
        XCTAssertEqual(
            result, WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir, .jha, .postTripDvir]))
    }

    func testParseWorkflowRequirementsIgnoresUnknownStepsCanonicalOrder() {
        let result = parseWorkflowRequirements([
            "clock_in_required": true,
            "required_steps": ["jha", "made_up_step", "pre_trip_dvir"],
        ])
        XCTAssertEqual(result, WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir, .jha]))
    }

    func testParseWorkflowRequirementsToleratesLegacyBooleanKeys() {
        let result = parseWorkflowRequirements([
            "require_pre_trip_dvir": true,
            "require_jha_per_sr": true,
        ])
        XCTAssertEqual(result, WorkflowRequirements(clockInRequired: false, requiredSteps: [.preTripDvir, .jha]))
    }

    func testParseWorkflowRequirementsAbsentOrMalformedMeansNotRequired() {
        let none = WorkflowRequirements(clockInRequired: false, requiredSteps: [])
        XCTAssertEqual(parseWorkflowRequirements(nil), none)
        XCTAssertEqual(parseWorkflowRequirements("garbage"), none)
        XCTAssertEqual(parseWorkflowRequirements(["required_steps": "not-a-list"]), none)
        XCTAssertEqual(parseWorkflowRequirements(["require_pre_trip_dvir": "yes"]), none)
    }

    // ---- checkTicketSubmitAllowed ----

    private let ALL_REQUIRED = WorkflowRequirements(
        clockInRequired: true, requiredSteps: [.preTripDvir, .jha, .postTripDvir])

    func testChecksTicketSubmitBlocksWithExactMissingSteps() {
        let gate = checkTicketSubmitAllowed(
            ALL_REQUIRED, CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:]), "sr-9")
        XCTAssertEqual(gate, .blocked(missing: [.preTripDvir, .jhaJsa]))
    }

    func testJhaForDifferentSrDoesNotSatisfyThisSr() {
        let gate = checkTicketSubmitAllowed(
            ALL_REQUIRED,
            CompletedWorkflowSteps(preTripDvirFormId: "dvir-1", jhaFormIdByServiceRequest: ["sr-other": "jha-x"]),
            "sr-9"
        )
        XCTAssertEqual(gate, .blocked(missing: [.jhaJsa]))
    }

    func testAllowsWhenEveryRequiredStepIsComplete() {
        let gate = checkTicketSubmitAllowed(
            ALL_REQUIRED,
            CompletedWorkflowSteps(preTripDvirFormId: "dvir-1", jhaFormIdByServiceRequest: ["sr-9": "jha-1"]),
            "sr-9"
        )
        XCTAssertEqual(gate, .allowed)
    }

    func testNothingRequiredAlwaysAllowed() {
        let gate = checkTicketSubmitAllowed(
            WorkflowRequirements(clockInRequired: true, requiredSteps: []),
            CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:]),
            "sr-9"
        )
        XCTAssertEqual(gate, .allowed)
    }

    func testPostTripOnlyRequirementNeverGatesTicketSubmission() {
        let gate = checkTicketSubmitAllowed(
            WorkflowRequirements(clockInRequired: true, requiredSteps: [.postTripDvir]),
            CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:]),
            "sr-9"
        )
        XCTAssertEqual(gate, .allowed)
    }

    // ---- unsafe-vehicle rule ----

    func testDvirCertifiesUnsafeTrueOnlyWhenCertifiedNotSafe() {
        XCTAssertTrue(dvirCertifiesUnsafe(makeDvir(defectsCertifiedSafe: false)))
        XCTAssertFalse(dvirCertifiesUnsafe(makeDvir(defectsCertifiedSafe: true)))
        XCTAssertFalse(dvirCertifiesUnsafe(makeDvir()))  // no certification → not unsafe
    }

    func testBlocksFieldWorkWhenPreTripDvirCertifiedUnsafe() {
        let gate = checkVehicleSafeToOperate(
            CompletedWorkflowSteps(preTripVehicleUnsafe: true, jhaFormIdByServiceRequest: [:])
        )
        XCTAssertEqual(gate, .unsafe(reason: "pre-trip-dvir-unsafe", reviewRequired: true))
    }

    func testIsSafeWhenVehicleNotCertifiedUnsafe() {
        XCTAssertEqual(checkVehicleSafeToOperate(CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:])), .safe)
        XCTAssertEqual(
            checkVehicleSafeToOperate(
                CompletedWorkflowSteps(preTripVehicleUnsafe: false, jhaFormIdByServiceRequest: [:])),
            .safe
        )
    }
}
