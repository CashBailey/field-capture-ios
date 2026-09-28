import FieldContracts
// Port of __tests__/field-form-builders.test.ts
import XCTest

@testable import FieldDomain

final class FieldFormsTests: XCTestCase {
    private func record(_ blobId: String, signerRole: String = "Driver") -> SignatureRecord {
        buildSignatureRecord(
            blobId: blobId,
            signerName: "Alex Rivera",
            signerUserId: "arivera",
            signerRole: signerRole,
            signedAtUtc: "2026-06-21T12:00:00.000Z",
            certificationText: JHA_CERTIFICATION_TEXT,
            deviceInstanceId: "device-1",
            appVersion: "1.0.0"
        )
    }

    func testBuildSignatureRecordStampsConsentTrueAndKeepsFields() {
        let r = record("blob-1")
        XCTAssertEqual(r.blobId, "blob-1")
        XCTAssertEqual(r.signerRole, "Driver")
        XCTAssertTrue(r.consentToElectronicSignature)
    }

    func testSignatureBytesEncodesTheSerializedVectorToBytesRoundTrippably() {
        let s = "{\"v\":1,\"strokes\":[[[1,2],[3,4]]]}"
        let bytes = signatureBytes(s)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), s)
    }

    func testJhaJsaFormCarriesAllBlobIdsAndSignatureRecordsAndIsCompletable() {
        let form = jhaJsaForm("sr-1", [record("sig-driver"), record("sig-owner", signerRole: "Owner")])
        XCTAssertEqual(form.signatureBlobIds, ["sig-driver", "sig-owner"])
        XCTAssertEqual(form.signatures?.map(\.blobId), ["sig-driver", "sig-owner"])
        XCTAssertEqual(form.signatures?.map(\.signerRole), ["Driver", "Owner"])
        XCTAssertEqual(validateFormCompletion(.jha(form)), [])
    }

    func testJhaJsaFormPreservesEveryEnteredHazardAndSignatureExactly() throws {
        let hazards = [
            JhaHazard(
                hazardId: "traffic-control",
                description: "Live traffic beside the work zone",
                mitigation: "Deploy cones and a trained spotter"
            ),
            JhaHazard(
                hazardId: "stored-pressure",
                description: "Residual pressure in the line",
                mitigation: "Bleed to zero and verify the gauge"
            ),
            JhaHazard(
                hazardId: "heat-01",
                description: "Heat index above 100 °F",
                mitigation: "Water, shade, and 20-minute rotations"
            ),
        ]
        let signatures = [record("sig-driver"), record("sig-crew", signerRole: "Additional Crew")]

        let form = try jhaJsaForm(serviceRequestId: "sr-real", hazards: hazards, signatures: signatures)

        XCTAssertEqual(form.formId, "jha-jsa-sr-real")
        XCTAssertEqual(form.serviceRequestId, "sr-real")
        XCTAssertEqual(form.hazards, hazards)
        XCTAssertEqual(form.signatures, signatures)
        XCTAssertEqual(form.signatureBlobIds, ["sig-driver", "sig-crew"])
    }

    func testProductionBuildersPreserveExplicitUniqueFormIds() throws {
        let hazards = [
            JhaHazard(
                hazardId: "pressure",
                description: "Stored pressure",
                mitigation: "Bleed and verify zero")
        ]
        let item = InspectionItem(
            itemId: "brakes", label: "Brakes", result: .ok)

        let jha = try jhaJsaForm(
            formId: "jha-jsa-sr-1-shift-20260711-001",
            serviceRequestId: "sr-1",
            hazards: hazards,
            signatures: [record("sig-jha")])
        let preTrip = try preTripDvirForm(
            formId: "pre-trip-dvir-sr-1-shift-20260711-001",
            serviceRequestId: "sr-1",
            vehicleRef: "truck-7",
            items: [item],
            signatures: [record("sig-pre")])
        let postTrip = try postTripDvirForm(
            formId: "post-trip-dvir-sr-1-shift-20260711-001",
            serviceRequestId: "sr-1",
            vehicleRef: "truck-7",
            items: [item],
            signatures: [record("sig-post")])

        XCTAssertEqual(jha.formId, "jha-jsa-sr-1-shift-20260711-001")
        XCTAssertEqual(preTrip.formId, "pre-trip-dvir-sr-1-shift-20260711-001")
        XCTAssertEqual(postTrip.formId, "post-trip-dvir-sr-1-shift-20260711-001")
    }

    func testExplicitEmptyFormIdIsRejectedInsteadOfFallingBackToTheLegacyId() {
        XCTAssertThrowsError(
            try preTripDvirForm(
                formId: "",
                serviceRequestId: "sr-1",
                vehicleRef: "truck-7",
                items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
                signatures: [record("sig-pre")])
        ) { error in
            XCTAssertEqual((error as? FieldFormError)?.message, "formId is required")
        }
    }

    func testJhaJsaFormRejectsIncompleteEnteredEvidenceInsteadOfReplacingIt() {
        XCTAssertThrowsError(
            try jhaJsaForm(serviceRequestId: "sr-1", hazards: [], signatures: [record("sig-driver")])
        ) { error in
            XCTAssertEqual((error as? FieldFormError)?.message, "JHA needs at least one hazard")
        }
    }

    func testPreTripDvirFormCarriesTheBlobIdAndRecordAndIsCompletable() {
        let form = preTripDvirForm("sr-1", "truck-7", record("sig-pre"))
        XCTAssertEqual(form.signatureBlobIds, ["sig-pre"])
        XCTAssertEqual(validateFormCompletion(.dvir(form)), [])
    }

    func testPostTripDvirFormCarriesTheBlobIdAndRecordAndIsCompletable() {
        let form = postTripDvirForm("sr-1", "truck-7", record("sig-post"))
        XCTAssertEqual(form.signatureBlobIds, ["sig-post"])
        XCTAssertEqual(validateFormCompletion(.dvir(form)), [])
    }

    func testPreTripDvirFormPreservesMultipleDefectsAndTheirExactValues() throws {
        let items = [
            InspectionItem(
                itemId: "service-brakes",
                label: "Service brakes",
                result: .defect,
                note: "Air pressure drops below 60 PSI"
            ),
            InspectionItem(
                itemId: "right-rear-tire",
                label: "Right rear tire",
                result: .defect,
                note: "Tread measured at 1/32 in"
            ),
            InspectionItem(
                itemId: "trailer-lamps",
                label: "Trailer lamps",
                result: .notApplicable,
                note: "No trailer connected"
            ),
        ]
        let signatures = [record("sig-driver"), record("sig-mechanic", signerRole: "Mechanic")]

        let form = try preTripDvirForm(
            serviceRequestId: "sr-real",
            vehicleRef: "truck-42",
            items: items,
            defectsCertifiedSafe: false,
            signatures: signatures,
            odometer: 98_765.4
        )

        XCTAssertEqual(form.formId, "pre-trip-dvir-sr-real")
        XCTAssertEqual(form.kind, .preTripDvir)
        XCTAssertEqual(form.vehicleRef, "truck-42")
        XCTAssertEqual(form.odometer, 98_765.4)
        XCTAssertEqual(form.items, items)
        XCTAssertEqual(form.defectsCertifiedSafe, false)
        XCTAssertEqual(form.signatures, signatures)
        XCTAssertEqual(form.signatureBlobIds, ["sig-driver", "sig-mechanic"])
    }

    func testPostTripDvirFormPreservesMultipleDefectsAndTheirExactValues() throws {
        let items = [
            InspectionItem(itemId: "mirror", label: "Left mirror", result: .defect, note: "Cracked at lower edge"),
            InspectionItem(itemId: "horn", label: "Horn", result: .ok, note: nil),
            InspectionItem(itemId: "leak", label: "Fluid leak", result: .defect, note: "Two drops under gearbox"),
        ]
        let signatures = [record("sig-post")]

        let form = try postTripDvirForm(
            serviceRequestId: "sr-post",
            vehicleRef: "truck-42",
            items: items,
            defectsCertifiedSafe: true,
            signatures: signatures,
            odometer: 98_811
        )

        XCTAssertEqual(form.formId, "post-trip-dvir-sr-post")
        XCTAssertEqual(form.kind, .postTripDvir)
        XCTAssertEqual(form.items, items)
        XCTAssertEqual(form.defectsCertifiedSafe, true)
        XCTAssertEqual(form.signatures, signatures)
        XCTAssertEqual(form.signatureBlobIds, ["sig-post"])
    }

    func testDvirFormRejectsDefectsWithoutTheDriversSafetyCertification() {
        let defect = InspectionItem(itemId: "brakes", label: "Brakes", result: .defect, note: "Pulls left")

        XCTAssertThrowsError(
            try preTripDvirForm(
                serviceRequestId: "sr-1",
                vehicleRef: "truck-7",
                items: [defect],
                signatures: [record("sig-pre")]
            )
        ) { error in
            XCTAssertEqual(
                (error as? FieldFormError)?.message,
                "defects present: safe-to-operate certification is required"
            )
        }
    }
}
