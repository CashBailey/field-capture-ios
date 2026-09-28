// Port of src/domain/fieldForms.ts — Domain seams for DVIR / JHA-JSA field forms. A form lives
// locally as an editable DRAFT, gets COMPLETED (validated against the contracts rules), is
// ENQUEUED into the durable sync outbox as an append-only evidence event, and ends ACCEPTED /
// NEEDS-REVIEW / REJECTED when Hub answers. Once enqueued the payload is frozen — append-only
// evidence is never edited, and a non-accepted outcome preserves the record (with Hub's reason)
// instead of deleting it.
import Foundation
import FieldContracts

public enum FieldFormStatus: String, Equatable, Sendable, Codable {
    case draft
    case completed
    case enqueued
    case accepted
    case needsReview = "needs-review"
    case rejected
}

public struct FieldFormRecord: Equatable, Sendable {
    public var form: FieldForm
    public var status: FieldFormStatus
    /// opId of the evidence operation in the sync outbox, once enqueued.
    public var opId: String?
    /// Hub's rejection code / review reason, preserved verbatim.
    public var lastError: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        form: FieldForm,
        status: FieldFormStatus,
        opId: String? = nil,
        lastError: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.form = form
        self.status = status
        self.opId = opId
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol FieldFormStore {
    var durability: StoreDurability { get }
    /// Runs field-form writes in the caller's current durable database transaction. Production
    /// uses this to commit the form's `enqueued` state and its outbox evidence as one unit.
    func transaction(_ body: () throws -> Void) throws
    func save(_ record: FieldFormRecord) throws
    func get(_ formId: String) throws -> FieldFormRecord?
    func list() throws -> [FieldFormRecord]
    func listByStatus(_ status: FieldFormStatus) throws -> [FieldFormRecord]
}

private extension FieldForm {
    var formId: String {
        switch self {
        case .dvir(let dvir): return dvir.formId
        case .jha(let jha): return jha.formId
        }
    }
}

/**
 * Field-form builders + signature helpers. The JHA/DVIR wizard screens are presentational, so the
 * durable record is assembled here. A form MUST carry at least one signature (the safety evidence
 * `validateFormCompletion` requires); the signature is the driver's captured artifact (blob) plus
 * a `SignatureRecord` of compliance metadata (ESIGN/UETA/FMCSA functional standard).
 */
public func signatureBytes(_ serialized: String) -> Data {
    // serializeSignature emits ASCII JSON; UTF-8 round-trips it byte-for-byte.
    Data(serialized.utf8)
}

public func buildSignatureRecord(
    blobId: String,
    signerName: String,
    signerUserId: String? = nil,
    signerRole: String? = nil,
    signedAtUtc: String,
    certificationText: String,
    deviceInstanceId: String,
    appVersion: String
) -> SignatureRecord {
    // `SignatureRecord.consentToElectronicSignature` defaults to `true` and is not a settable
    // init parameter (see FieldContracts/Fieldwork/Forms.swift) — mirrors the TS spread
    // `{ ...p, consentToElectronicSignature: true }` automatically.
    SignatureRecord(
        blobId: blobId,
        signerName: signerName,
        signerUserId: signerUserId,
        signerRole: signerRole,
        signedAtUtc: signedAtUtc,
        certificationText: certificationText,
        deviceInstanceId: deviceInstanceId,
        appVersion: appVersion
    )
}

private func makeJhaJsaForm(
    formId: String,
    serviceRequestId: String,
    hazards: [JhaHazard],
    signatures: [SignatureRecord]
) -> JhaForm {
    JhaForm(
        formId: formId,
        serviceRequestId: serviceRequestId,
        hazards: hazards,
        signatureBlobIds: signatures.map(\.blobId),
        signatures: signatures
    )
}

private func makeDvirForm(
    formId: String,
    kind: DvirKind,
    vehicleRef: String,
    odometer: Double?,
    items: [InspectionItem],
    defectsCertifiedSafe: Bool?,
    signatures: [SignatureRecord]
) -> DvirForm {
    DvirForm(
        formId: formId,
        kind: kind,
        vehicleRef: vehicleRef,
        odometer: odometer,
        items: items,
        defectsCertifiedSafe: defectsCertifiedSafe,
        signatureBlobIds: signatures.map(\.blobId),
        signatures: signatures
    )
}

private func requireCompletable(_ form: FieldForm) throws {
    let errors = validateFormCompletion(form)
    guard errors.isEmpty else {
        throw FieldFormError(errors.joined(separator: "; "))
    }
}

/// Builds a JHA from the driver's actual hazard review and signatures. Input order and values are
/// preserved exactly; validation rejects incomplete evidence instead of substituting canned data.
public func jhaJsaForm(
    serviceRequestId: String,
    hazards: [JhaHazard],
    signatures: [SignatureRecord]
) throws -> JhaForm {
    try jhaJsaForm(
        formId: "jha-jsa-\(serviceRequestId)",
        serviceRequestId: serviceRequestId,
        hazards: hazards,
        signatures: signatures)
}

/// Explicit-id production overload. A fresh signed form should receive a fresh id so evidence
/// from a prior shift remains immutable without preventing today's form from being created.
public func jhaJsaForm(
    formId: String,
    serviceRequestId: String,
    hazards: [JhaHazard],
    signatures: [SignatureRecord]
) throws -> JhaForm {
    let form = makeJhaJsaForm(
        formId: formId,
        serviceRequestId: serviceRequestId,
        hazards: hazards,
        signatures: signatures)
    try requireCompletable(.jha(form))
    return form
}

/// Builds a pre-trip DVIR from the driver's actual answers and signatures. In particular, defect
/// notes and the safe-to-operate certification are never inferred or rewritten.
public func preTripDvirForm(
    serviceRequestId: String,
    vehicleRef: String,
    items: [InspectionItem],
    defectsCertifiedSafe: Bool? = nil,
    signatures: [SignatureRecord],
    odometer: Double? = nil
) throws -> DvirForm {
    try preTripDvirForm(
        formId: "\(DvirKind.preTripDvir.rawValue)-\(serviceRequestId)",
        serviceRequestId: serviceRequestId,
        vehicleRef: vehicleRef,
        items: items,
        defectsCertifiedSafe: defectsCertifiedSafe,
        signatures: signatures,
        odometer: odometer)
}

/// Explicit-id production overload. The id identifies this signed inspection event, not merely
/// the service request, so later shifts can create new immutable evidence for the same SR.
public func preTripDvirForm(
    formId: String,
    serviceRequestId: String,
    vehicleRef: String,
    items: [InspectionItem],
    defectsCertifiedSafe: Bool? = nil,
    signatures: [SignatureRecord],
    odometer: Double? = nil
) throws -> DvirForm {
    let form = makeDvirForm(
        formId: formId,
        kind: .preTripDvir,
        vehicleRef: vehicleRef,
        odometer: odometer,
        items: items,
        defectsCertifiedSafe: defectsCertifiedSafe,
        signatures: signatures
    )
    try requireCompletable(.dvir(form))
    return form
}

/// Builds a post-trip DVIR from the driver's actual answers and signatures. In particular, defect
/// notes and the safe-to-operate certification are never inferred or rewritten.
public func postTripDvirForm(
    serviceRequestId: String,
    vehicleRef: String,
    items: [InspectionItem],
    defectsCertifiedSafe: Bool? = nil,
    signatures: [SignatureRecord],
    odometer: Double? = nil
) throws -> DvirForm {
    try postTripDvirForm(
        formId: "\(DvirKind.postTripDvir.rawValue)-\(serviceRequestId)",
        serviceRequestId: serviceRequestId,
        vehicleRef: vehicleRef,
        items: items,
        defectsCertifiedSafe: defectsCertifiedSafe,
        signatures: signatures,
        odometer: odometer)
}

/// Explicit-id production overload for a distinct signed post-trip inspection event.
public func postTripDvirForm(
    formId: String,
    serviceRequestId: String,
    vehicleRef: String,
    items: [InspectionItem],
    defectsCertifiedSafe: Bool? = nil,
    signatures: [SignatureRecord],
    odometer: Double? = nil
) throws -> DvirForm {
    let form = makeDvirForm(
        formId: formId,
        kind: .postTripDvir,
        vehicleRef: vehicleRef,
        odometer: odometer,
        items: items,
        defectsCertifiedSafe: defectsCertifiedSafe,
        signatures: signatures
    )
    try requireCompletable(.dvir(form))
    return form
}

/// Compatibility builder retained for TypeScript parity. Production flows should use the labeled
/// overload above so the driver's real hazards reach durable evidence.
public func jhaJsaForm(_ serviceRequestId: String, _ signatures: [SignatureRecord]) -> JhaForm {
    makeJhaJsaForm(
        formId: "jha-jsa-\(serviceRequestId)",
        serviceRequestId: serviceRequestId,
        hazards: [JhaHazard(hazardId: "h1", description: "H2S exposure", mitigation: "Monitor and ventilate")],
        signatures: signatures
    )
}

/// Convenience overload mirroring the TS union `SignatureRecord | readonly SignatureRecord[]`.
public func jhaJsaForm(_ serviceRequestId: String, _ signature: SignatureRecord) -> JhaForm {
    jhaJsaForm(serviceRequestId, [signature])
}

/// Compatibility builder retained for TypeScript parity. Production flows should use the labeled
/// overload above so the driver's real inspection answers reach durable evidence.
public func preTripDvirForm(_ serviceRequestId: String, _ vehicleRef: String, _ signature: SignatureRecord) -> DvirForm
{
    makeDvirForm(
        formId: "\(DvirKind.preTripDvir.rawValue)-\(serviceRequestId)",
        kind: .preTripDvir,
        vehicleRef: vehicleRef,
        odometer: nil,
        items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
        defectsCertifiedSafe: nil,
        signatures: [signature]
    )
}

/// Compatibility builder retained for TypeScript parity. Production flows should use the labeled
/// overload above so the driver's real inspection answers reach durable evidence.
public func postTripDvirForm(_ serviceRequestId: String, _ vehicleRef: String, _ signature: SignatureRecord) -> DvirForm
{
    makeDvirForm(
        formId: "\(DvirKind.postTripDvir.rawValue)-\(serviceRequestId)",
        kind: .postTripDvir,
        vehicleRef: vehicleRef,
        odometer: nil,
        items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
        defectsCertifiedSafe: nil,
        signatures: [signature]
    )
}

/// In-memory form store. VOLATILE — TEST SEAM ONLY (production: FieldData's durable SQLite
/// field-form store).
public final class VolatileFieldFormStore: FieldFormStore {
    public let durability: StoreDurability = .volatileMemory
    private var byId: [String: FieldFormRecord] = [:]

    public init() {}

    public func transaction(_ body: () throws -> Void) throws {
        let snapshot = byId
        do {
            try body()
        } catch {
            byId = snapshot
            throw error
        }
    }

    public func save(_ record: FieldFormRecord) throws {
        byId[record.form.formId] = record
    }

    public func get(_ formId: String) throws -> FieldFormRecord? {
        byId[formId]
    }

    public func list() throws -> [FieldFormRecord] {
        Array(byId.values)
    }

    public func listByStatus(_ status: FieldFormStatus) throws -> [FieldFormRecord] {
        try list().filter { $0.status == status }
    }
}
