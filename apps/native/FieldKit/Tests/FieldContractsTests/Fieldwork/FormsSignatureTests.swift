// Port of src/fieldwork/forms.signature.test.ts
import XCTest

@testable import FieldContracts

final class FormsSignatureTests: XCTestCase {
    private let record = SignatureRecord(
        blobId: "blob-1",
        signerName: "Alex Rivera",
        signerUserId: "arivera",
        signerRole: "Driver",
        signedAtUtc: "2026-06-21T12:00:00.000Z",
        certificationText: JHA_CERTIFICATION_TEXT,
        deviceInstanceId: "device-1",
        appVersion: "1.0.0"
    )

    func testCertificationTextConstantsAreNonEmpty() {
        XCTAssertGreaterThan(DVIR_PRETRIP_CERTIFICATION_TEXT.count, 0)
        XCTAssertGreaterThan(DVIR_POSTTRIP_CERTIFICATION_TEXT.count, 0)
        XCTAssertGreaterThan(JHA_CERTIFICATION_TEXT.count, 0)
    }

    func testJhaCarryingASignatureRecordAndBlobIdIsCompletable() {
        let form = JhaForm(
            formId: "jha-jsa-sr-1",
            serviceRequestId: "sr-1",
            hazards: [JhaHazard(hazardId: "h1", description: "H2S", mitigation: "monitor")],
            signatureBlobIds: [record.blobId],
            signatures: [record]
        )
        XCTAssertEqual(validateFormCompletion(.jha(form)), [])
        XCTAssertEqual(form.signatures?.first?.signerRole, "Driver")
    }
}
