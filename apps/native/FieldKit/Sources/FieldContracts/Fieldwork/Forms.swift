// Port of fieldwork/forms.ts — DVIR / JHA-JSA field-form contracts + the workflow-step gate
// (field-day-workflow.md): pre-trip DVIR at day start, a JHA/JSA per Service Request BEFORE work,
// post-trip DVIR at day end. Completed forms sync as APPEND-ONLY evidence (ADR 004 — never
// overwritten, never auto-merged); Hub config decides which steps are REQUIRED before a field
// ticket may be submitted. Pure types + validation — no storage, no network, no UI here.

public struct FieldFormError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum FieldFormKind: String, Equatable, Sendable, Codable {
    case preTripDvir = "pre-trip-dvir"
    case jhaJsa = "jha-jsa"
    case postTripDvir = "post-trip-dvir"
}

public enum InspectionResult: String, Equatable, Sendable, Codable {
    case ok
    case defect
    case notApplicable = "not-applicable"
}

public struct InspectionItem: Equatable, Sendable {
    public var itemId: String
    public var label: String
    /// Unanswered items stay nil — a draft is allowed to be incomplete; completion is not.
    public var result: InspectionResult?
    /// Required when result is `.defect` — a defect with no description is unactionable.
    public var note: String?

    public init(itemId: String, label: String, result: InspectionResult? = nil, note: String? = nil) {
        self.itemId = itemId
        self.label = label
        self.result = result
        self.note = note
    }
}

/// Inline TS union on `DvirForm.kind` (a narrower subset of `FieldFormKind`).
public enum DvirKind: String, Equatable, Sendable, Codable {
    case preTripDvir = "pre-trip-dvir"
    case postTripDvir = "post-trip-dvir"
}

/// Driver Vehicle Inspection Report (pre- or post-trip).
public struct DvirForm: Equatable, Sendable {
    public var formId: String
    public var kind: DvirKind
    public var vehicleRef: String
    public var odometer: Double?
    public var items: [InspectionItem]
    /**
     * Required (either value) once any item is a defect: the driver certifies the vehicle is
     * still safe to operate (true) or not (false). Never defaulted.
     */
    public var defectsCertifiedSafe: Bool?
    /// Signature blob ids (capture flow). At least one required to complete.
    public var signatureBlobIds: [String]
    public var signatures: [SignatureRecord]?
    public var completedAt: String?

    public init(
        formId: String,
        kind: DvirKind,
        vehicleRef: String,
        odometer: Double? = nil,
        items: [InspectionItem],
        defectsCertifiedSafe: Bool? = nil,
        signatureBlobIds: [String],
        signatures: [SignatureRecord]? = nil,
        completedAt: String? = nil
    ) {
        self.formId = formId
        self.kind = kind
        self.vehicleRef = vehicleRef
        self.odometer = odometer
        self.items = items
        self.defectsCertifiedSafe = defectsCertifiedSafe
        self.signatureBlobIds = signatureBlobIds
        self.signatures = signatures
        self.completedAt = completedAt
    }
}

public struct JhaHazard: Equatable, Sendable {
    public var hazardId: String
    public var description: String
    public var mitigation: String

    public init(hazardId: String, description: String, mitigation: String) {
        self.hazardId = hazardId
        self.description = description
        self.mitigation = mitigation
    }
}

/// Compliance metadata bound to a captured signature (ESIGN/UETA/FMCSA functional standard:
/// attribution, intent, consent, device/audit). The drawn artifact is the blob at `blobId`.
public struct SignatureRecord: Equatable, Sendable {
    public var blobId: String
    public var signerName: String
    public var signerUserId: String?
    /// Driver-facing role at signing time, e.g. Driver, Owner, Additional Crew.
    public var signerRole: String?
    /// ISO-8601 UTC.
    public var signedAtUtc: String
    /// The exact certification/intent statement the signer approved.
    public var certificationText: String
    /// Proof of consent to sign electronically (15 USC 7001(c)). Always true once captured — the
    /// TS literal type `true` becomes a fixed stored value here (not a settable init parameter).
    public var consentToElectronicSignature: Bool = true
    public var deviceInstanceId: String
    public var appVersion: String

    public init(
        blobId: String,
        signerName: String,
        signerUserId: String? = nil,
        signerRole: String? = nil,
        signedAtUtc: String,
        certificationText: String,
        deviceInstanceId: String,
        appVersion: String
    ) {
        self.blobId = blobId
        self.signerName = signerName
        self.signerUserId = signerUserId
        self.signerRole = signerRole
        self.signedAtUtc = signedAtUtc
        self.certificationText = certificationText
        self.deviceInstanceId = deviceInstanceId
        self.appVersion = appVersion
    }
}

public let DVIR_PRETRIP_CERTIFICATION_TEXT = "I confirm this pre-trip inspection is complete and accurate."
public let DVIR_POSTTRIP_CERTIFICATION_TEXT = "I confirm this post-trip inspection is complete and accurate."
public let JHA_CERTIFICATION_TEXT = "I confirm the hazards and controls for this job were reviewed."

/// Job Hazard / Job Safety Analysis for one Service Request. TS's `kind: "jha-jsa"` literal field
/// is dropped here — `FieldForm.jha` is the discriminant now (see `FieldForm` below).
public struct JhaForm: Equatable, Sendable {
    public var formId: String
    public var serviceRequestId: String
    public var hazards: [JhaHazard]
    /// Signature blob ids (append-only evidence — ADR 004 signatures are never deleted).
    public var signatureBlobIds: [String]
    /// Signature compliance records (one per signer); each blobId also appears in signatureBlobIds.
    public var signatures: [SignatureRecord]?
    public var completedAt: String?

    public init(
        formId: String,
        serviceRequestId: String,
        hazards: [JhaHazard],
        signatureBlobIds: [String],
        signatures: [SignatureRecord]? = nil,
        completedAt: String? = nil
    ) {
        self.formId = formId
        self.serviceRequestId = serviceRequestId
        self.hazards = hazards
        self.signatureBlobIds = signatureBlobIds
        self.signatures = signatures
        self.completedAt = completedAt
    }
}

/// TS discriminated union `DvirForm | JhaForm` (discriminant: `.kind`). Per PORTING.md, ported as
/// a Swift enum with associated values.
public enum FieldForm: Equatable, Sendable {
    case dvir(DvirForm)
    case jha(JhaForm)
}

/**
 * Completion validation: the list of human-readable reasons a form may NOT be marked complete
 * (empty = completable). Drafts may violate all of these — the gate is at completion time.
 */
public func validateFormCompletion(_ form: FieldForm) -> [String] {
    var errors: [String] = []
    switch form {
    case .jha(let jha):
        if jha.formId.isEmpty { errors.append("formId is required") }
        if jha.serviceRequestId.isEmpty { errors.append("JHA must reference a service request") }
        if jha.hazards.isEmpty { errors.append("JHA needs at least one hazard") }
        for hazard in jha.hazards {
            if hazard.description.isEmpty { errors.append("hazard \(hazard.hazardId) has no description") }
            if hazard.mitigation.isEmpty { errors.append("hazard \(hazard.hazardId) has no mitigation") }
        }
        if jha.signatureBlobIds.isEmpty { errors.append("JHA needs at least one signature") }
    case .dvir(let dvir):
        if dvir.formId.isEmpty { errors.append("formId is required") }
        if dvir.vehicleRef.isEmpty { errors.append("DVIR must reference a vehicle") }
        if dvir.items.isEmpty { errors.append("DVIR needs at least one inspection item") }
        for item in dvir.items {
            if item.result == nil { errors.append("inspection item \(item.itemId) is unanswered") }
            let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.result == .defect && note.isEmpty {
                errors.append("defect on \(item.itemId) needs a note")
            }
        }
        let hasDefect = dvir.items.contains { $0.result == .defect }
        if hasDefect && dvir.defectsCertifiedSafe == nil {
            errors.append("defects present: safe-to-operate certification is required")
        }
        if dvir.signatureBlobIds.isEmpty { errors.append("DVIR needs the driver's signature") }
    }
    return errors
}

// ---- workflow-step gate (Hub-configured) ----

/**
 * Hub workflow step identifiers — the real Hub `SrWorkflowStep.step_type` values
 * (opshub `sync/workflow.py`, `sync/protocol.py`). Kept as the Hub's own strings so the
 * gate maps 1:1 to `workflow_requirements.required_steps[]` with no client-side translation.
 */
public enum WorkflowStepType: String, Equatable, Sendable, Codable, CaseIterable {
    case preTripDvir = "pre_trip_dvir"
    case jha
    case postTripDvir = "post_trip_dvir"
}

private let KNOWN_WORKFLOW_STEPS: [WorkflowStepType] = [.preTripDvir, .jha, .postTripDvir]

/**
 * Which steps Hub requires before a field ticket may be submitted. Hub is authoritative.
 * Mirrors the real Hub `workflow_requirements` wire shape (opshub `sync/snapshots.py`):
 * `{ clock_in_required: bool, required_steps: string[] }`. The clock-in gate is enforced
 * separately from Hub session-status truth, so `clockInRequired` here is informational only.
 */
public struct WorkflowRequirements: Equatable, Sendable {
    public var clockInRequired: Bool
    public var requiredSteps: [WorkflowStepType]

    public init(clockInRequired: Bool, requiredSteps: [WorkflowStepType]) {
        self.clockInRequired = clockInRequired
        self.requiredSteps = requiredSteps
    }
}

/**
 * Parse Hub's `workflow_requirements` from an untyped snapshot/config blob. ABSENT or malformed
 * fields default to NOT required: the gate is a UX guard, Hub still authoritatively re-validates
 * every submit — inventing a requirement Hub never set would block legitimate work offline.
 * Unknown `required_steps` entries are ignored; legacy boolean keys (older snapshots, pre
 * `required_steps[]`) are tolerated so cached payloads still gate correctly.
 */
public func parseWorkflowRequirements(_ value: Any?) -> WorkflowRequirements {
    let rec = (value as? [String: Any]) ?? [:]
    let rawSteps = (rec["required_steps"] as? [Any]) ?? []
    var present = Set(rawSteps.compactMap { $0 as? String })
    // Tolerate legacy boolean keys from snapshots that predate required_steps[].
    if (rec["require_pre_trip_dvir"] as? Bool) == true { present.insert(WorkflowStepType.preTripDvir.rawValue) }
    if (rec["require_jha_per_sr"] as? Bool) == true { present.insert(WorkflowStepType.jha.rawValue) }
    if (rec["require_post_trip_dvir"] as? Bool) == true { present.insert(WorkflowStepType.postTripDvir.rawValue) }
    return WorkflowRequirements(
        clockInRequired: (rec["clock_in_required"] as? Bool) == true,
        requiredSteps: KNOWN_WORKFLOW_STEPS.filter { present.contains($0.rawValue) }
    )
}

/// The steps a worker has completed so far (form ids of COMPLETED forms).
public struct CompletedWorkflowSteps: Equatable, Sendable {
    public var preTripDvirFormId: String?
    /**
     * True when the completed pre-trip DVIR certified the vehicle NOT safe to operate
     * (`defectsCertifiedSafe == false`). Drives the unsafe-vehicle rule below.
     */
    public var preTripVehicleUnsafe: Bool?
    /// serviceRequestId → completed JHA formId.
    public var jhaFormIdByServiceRequest: [String: String]

    public init(
        preTripDvirFormId: String? = nil,
        preTripVehicleUnsafe: Bool? = nil,
        jhaFormIdByServiceRequest: [String: String]
    ) {
        self.preTripDvirFormId = preTripDvirFormId
        self.preTripVehicleUnsafe = preTripVehicleUnsafe
        self.jhaFormIdByServiceRequest = jhaFormIdByServiceRequest
    }
}

public enum TicketSubmitGate: Equatable, Sendable {
    case allowed
    case blocked(missing: [FieldFormKind])
}

/**
 * May a field ticket for `serviceRequestId` be submitted? Blocks ONLY on steps Hub requires
 * that are not complete. (Post-trip DVIR gates the END of day, not ticket submission.)
 */
public func checkTicketSubmitAllowed(
    _ requirements: WorkflowRequirements,
    _ completed: CompletedWorkflowSteps,
    _ serviceRequestId: String
) -> TicketSubmitGate {
    var missing: [FieldFormKind] = []
    if requirements.requiredSteps.contains(.preTripDvir) && completed.preTripDvirFormId == nil {
        missing.append(.preTripDvir)
    }
    if requirements.requiredSteps.contains(.jha) && completed.jhaFormIdByServiceRequest[serviceRequestId] == nil {
        missing.append(.jhaJsa)
    }
    return missing.isEmpty ? .allowed : .blocked(missing: missing)
}

/// Whether a DVIR certified the vehicle NOT safe to operate (a defect the driver did not clear).
public func dvirCertifiesUnsafe(_ form: DvirForm) -> Bool {
    form.defectsCertifiedSafe == false
}

public enum VehicleSafetyGate: Equatable, Sendable {
    case safe
    case unsafe(reason: String, reviewRequired: Bool)
}

/**
 * The unsafe-vehicle rule (field-day-workflow): when the completed pre-trip DVIR certified the
 * vehicle NOT safe to operate, field work is blocked for the day and the SR must be escalated to
 * Hub review. The phone never overrides this locally — it is a hard safety gate, distinct from the
 * Hub-configured workflow-step gate. Captured at DVIR completion, enforced here.
 */
public func checkVehicleSafeToOperate(_ completed: CompletedWorkflowSteps) -> VehicleSafetyGate {
    completed.preTripVehicleUnsafe == true
        ? .unsafe(reason: "pre-trip-dvir-unsafe", reviewRequired: true)
        : .safe
}
