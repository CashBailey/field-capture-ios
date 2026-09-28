// Port of src/domain/hubGateway.ts — Mobile-facing Ops Hub gateway contract (first real
// integration slice).
//
// Pure types + protocols only — NO HTTP here. A FieldAdapters `OpsHubV1Client` implements these
// over the Hub v1 routes (`/api/v1/sync/session-status`, `/api/v1/sync/assignments`,
// `/api/v1/sync/submit`); the domain services depend only on these protocols so they stay
// hardware- and network-free in tests.
//
// This slice is deliberately NOT the full ADR 004 envelope protocol (`/sync/commands`,
// `/sync/changes`, tus uploads) — that engine remains deferred and `SyncTransport` keeps its
// placeholder. See docs/integration/ops-triad-contract.md.
import FieldContracts

// ---- errors (typed, so domain code can classify without string matching) ----

/// The request never reached Hub (offline, DNS, timeout). Retryable; work stays local.
public struct HubNetworkError: Error, CustomStringConvertible {
    public let message: String
    public let cause: Error?
    public var description: String { message }
    public init(_ message: String, cause: Error? = nil) {
        self.message = message
        self.cause = cause
    }
}

/// Hub rejected our credentials (401/403 on a read). Visible; never silently ignored.
public struct HubAuthError: Error, CustomStringConvertible {
    public let message: String
    public let httpStatus: Int
    public var description: String { message }
    public init(_ message: String, httpStatus: Int) {
        self.message = message
        self.httpStatus = httpStatus
    }
}

/// Hub answered, but not in the agreed shape (5xx, non-JSON, missing required fields).
public struct HubResponseError: Error, CustomStringConvertible {
    public let message: String
    public let httpStatus: Int?
    public var description: String { message }
    public init(_ message: String, httpStatus: Int? = nil) {
        self.message = message
        self.httpStatus = httpStatus
    }
}

// ---- session status (TimeClock clock-in, via Hub — the authority) ----

/// Hub's answer to "is the logged-in driver clocked in?" (GET /api/v1/sync/session-status).
public struct HubSessionStatus: Equatable, Sendable {
    public var clockedIn: Bool
    /// ISO 8601, or nil when not clocked in / not reported. The real Hub sends this as both
    /// `clocked_in_since` and a `since` alias (opshub `SessionStatusOut`); we read either.
    public var clockedInSince: String?
    /// e.g. "timeclock" — which system produced the open punch.
    public var source: String?
    public var employeeId: String?
    public var assignmentsAvailable: Bool
    /// The Hub's authoritative server time (ISO 8601, `server_time`), used for clock-skew handling
    /// and to seed the offline-policy window. Present only when the Hub reports it.
    public var serverTime: String?

    public init(
        clockedIn: Bool,
        clockedInSince: String?,
        source: String?,
        employeeId: String?,
        assignmentsAvailable: Bool,
        serverTime: String? = nil
    ) {
        self.clockedIn = clockedIn
        self.clockedInSince = clockedInSince
        self.source = source
        self.employeeId = employeeId
        self.assignmentsAvailable = assignmentsAvailable
        self.serverTime = serverTime
    }
}

/// Per-request options. Cancellation NEVER cancels the work item itself: local evidence stays
/// queued and retryable.
///
/// ponytail: the TS `signal?: AbortSignal` is an HTTP-adapter concern (FieldAdapters wires real
/// cancellation over URLSession); the pure domain layer never inspects it, so it is dropped here
/// rather than modeled with no consumer.
public struct HubRequestOptions: Sendable {
    public init() {}
}

public protocol SessionStatusSource {
    func getSessionStatus(options: HubRequestOptions?) async throws -> HubSessionStatus
}

public extension SessionStatusSource {
    func getSessionStatus() async throws -> HubSessionStatus {
        try await getSessionStatus(options: nil)
    }
}

// ---- assignments (active SRs for the logged-in driver, with frozen snapshots) ----

public struct AssignmentNamedRef: Equatable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AssignmentWell: Equatable, Sendable {
    public var id: String?
    public var name: String
    public var leaseId: String?

    public init(id: String? = nil, name: String, leaseId: String? = nil) {
        self.id = id
        self.name = name
        self.leaseId = leaseId
    }
}

public typealias AssignmentDisposalSite = AssignmentNamedRef

/// Single source of truth lives in FieldContracts (the Hub-shaped requirements).
public typealias AssignmentWorkflowRequirements = WorkflowRequirements

/// The Service Request lifecycle states (opshub `dispatch/constants.py ServiceRequestStatus`).
public enum AssignmentStatus: String, Equatable, Sendable, Codable, CaseIterable {
    case requested
    case authorized
    case assigned
    case inProgress = "in_progress"
    case completed
    case closed
    case onHold = "on_hold"
    case cancelled
}

public struct AssignmentGpsPoint: Equatable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public struct AssignmentWellCoordinate: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var wellId: String?

    public init(lat: Double, lon: Double, wellId: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.wellId = wellId
    }
}

/// Validation-only well coordinates (Hub `coordinates`). Used for Phase-7 geofence hints, NOT for
/// navigation, routing, or map rendering — Field Capture is field capture, not FieldNav.
public struct AssignmentCoordinates: Equatable, Sendable {
    public var primary: AssignmentGpsPoint?
    public var wells: [AssignmentWellCoordinate]

    public init(primary: AssignmentGpsPoint? = nil, wells: [AssignmentWellCoordinate]) {
        self.primary = primary
        self.wells = wells
    }
}

/// Hub `geofence_hints`: how close to the well a location-validation check should expect to be.
public struct AssignmentGeofenceHints: Equatable, Sendable {
    public var radiusM: Double?
    public var required: Bool
    public var source: String?

    public init(radiusM: Double? = nil, required: Bool, source: String? = nil) {
        self.radiusM = radiusM
        self.required = required
        self.source = source
    }
}

public struct AssignmentDetails: Equatable, Sendable {
    /// Human-facing SR number (Hub `request_no`, e.g. "2026-000001").
    public var requestNo: String?
    /// SR lifecycle status; drives the inbox Active/On hold filters.
    public var status: AssignmentStatus?
    public var customer: AssignmentNamedRef?
    public var lease: AssignmentNamedRef?
    public var wells: [AssignmentWell]?
    public var material: String?
    public var disposalSite: AssignmentDisposalSite?
    public var vehicle: AssignmentNamedRef?
    public var trailer: AssignmentNamedRef?
    /// Hub sends `job_type` as an object `{id,name}` (opshub `_entity_ref`), not a bare string.
    public var jobType: AssignmentNamedRef?
    public var coordinates: AssignmentCoordinates?
    public var geofenceHints: AssignmentGeofenceHints?
    public var workflowRequirements: AssignmentWorkflowRequirements?

    public init(
        requestNo: String? = nil,
        status: AssignmentStatus? = nil,
        customer: AssignmentNamedRef? = nil,
        lease: AssignmentNamedRef? = nil,
        wells: [AssignmentWell]? = nil,
        material: String? = nil,
        disposalSite: AssignmentDisposalSite? = nil,
        vehicle: AssignmentNamedRef? = nil,
        trailer: AssignmentNamedRef? = nil,
        jobType: AssignmentNamedRef? = nil,
        coordinates: AssignmentCoordinates? = nil,
        geofenceHints: AssignmentGeofenceHints? = nil,
        workflowRequirements: AssignmentWorkflowRequirements? = nil
    ) {
        self.requestNo = requestNo
        self.status = status
        self.customer = customer
        self.lease = lease
        self.wells = wells
        self.material = material
        self.disposalSite = disposalSite
        self.vehicle = vehicle
        self.trailer = trailer
        self.jobType = jobType
        self.coordinates = coordinates
        self.geofenceHints = geofenceHints
        self.workflowRequirements = workflowRequirements
    }
}

/// One assigned Service Request: a frozen snapshot plus the hash Hub uses to detect drift.
///
/// ponytail: `snapshot` mirrors the TS `unknown` — an opaque JSON blob no domain code compares
/// for equality (only reads through, e.g. `workflowRequirementsFromSnapshot`) — so it stays a
/// plain `Any?` rather than the Equatable `JSONValue` tree contracts uses for compared payloads.
public struct HubAssignment {
    public var serviceRequestId: String
    /// Hub-computed hash of the frozen snapshot; echoed back on submit for drift detection.
    public var snapshotHash: String
    /// The frozen SR snapshot as Hub sent it. Opaque to this slice; the form slices type it later.
    public var snapshot: Any?
    /// Hub's latest authoritative SR/assignment version, used only for display/drift diagnostics.
    /// The real Hub sends this as a STRING equal to `snapshotHash` (opshub `sync/router.py`),
    /// never a numeric counter.
    public var latestServerVersion: String?
    /// Normalized rich assignment metadata for UI and workflow gating.
    public var details: AssignmentDetails?

    public init(
        serviceRequestId: String,
        snapshotHash: String,
        snapshot: Any? = nil,
        latestServerVersion: String? = nil,
        details: AssignmentDetails? = nil
    ) {
        self.serviceRequestId = serviceRequestId
        self.snapshotHash = snapshotHash
        self.snapshot = snapshot
        self.latestServerVersion = latestServerVersion
        self.details = details
    }
}

public protocol AssignmentSource {
    func getAssignments(options: HubRequestOptions?) async throws -> [HubAssignment]
}

public extension AssignmentSource {
    func getAssignments() async throws -> [HubAssignment] {
        try await getAssignments(options: nil)
    }
}

// ---- minimal field-ticket submit ----

/// The minimal field-ticket payload Hub accepts in this slice (POST /api/v1/sync/submit).
public struct HubFieldTicketSubmission: Equatable, Sendable {
    /// `gtr:<device_instance_id>:<local_seq>:<op_uuid>` — built with the contracts helper.
    public var idempotencyKey: String
    public var serviceRequestId: String
    /// The assignment's snapshot hash, echoed back so Hub can flag drift (412-style).
    public var snapshotHash: String
    public var ticketNo: String
    public var quantityBbl: Double
    public var disposalTicketNo: String
    /// Full paper-ticket detail (gauges, times, rig #, line items). Additive — the Hub currently
    /// ignores unknown submit fields (verified 201); it is sent as `field_ticket_detail` on the
    /// wire and persisted once the Hub adds the column. The contract scalars above are unaffected.
    public var detail: FieldTicketDetail?

    public init(
        idempotencyKey: String,
        serviceRequestId: String,
        snapshotHash: String,
        ticketNo: String,
        quantityBbl: Double,
        disposalTicketNo: String,
        detail: FieldTicketDetail? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.serviceRequestId = serviceRequestId
        self.snapshotHash = snapshotHash
        self.ticketNo = ticketNo
        self.quantityBbl = quantityBbl
        self.disposalTicketNo = disposalTicketNo
        self.detail = detail
    }
}

/// Every possible Hub answer to a submit, as data (never thrown): the caller MUST handle each
/// case, and only `.accepted` may ever mark local work durable (cross-cutting invariant #2).
///
/// - accepted     → Hub committed it (duplicate=true means an idempotent replay of an earlier
///                  accept — equally durable).
/// - rejected     → Hub said no. kind "blocked" (403/409-style: not clocked in, original still
///                  in progress) is retryable after the user acts; kind "needsReview"
///                  (412/422-style: snapshot drift, idempotency mismatch) freezes the work for
///                  manual review. rejectionCode/detail preserve Hub's reason verbatim.
/// - authFailed   → 401; re-auth then retry. Work stays local.
/// - transient    → network failure, 5xx/429, or a malformed 2xx body. Retry later; never durable.
public enum HubSubmitOutcome: Equatable, Sendable {
    public enum RejectedKind: String, Equatable, Sendable {
        case blocked
        case needsReview = "needs-review"
    }

    public enum TransientReason: String, Equatable, Sendable {
        case network
        case server
        case malformedResponse = "malformed-response"
    }

    // ponytail: Swift enum cases cannot carry default associated-value arguments (unlike TS
    // optional object fields), so every construction site below passes `nil` explicitly for the
    // fields the TS literal omits.
    case accepted(duplicate: Bool, snapshotDrift: Bool?, ticketId: String?)
    case rejected(kind: RejectedKind, httpStatus: Int, rejectionCode: String, detail: String?)
    case authFailed(httpStatus: Int)
    case transient(reason: TransientReason, httpStatus: Int?, detail: String?)
}

public protocol FieldTicketSubmitter {
    func submitFieldTicket(
        _ submission: HubFieldTicketSubmission,
        options: HubRequestOptions?
    ) async throws -> HubSubmitOutcome
}

public extension FieldTicketSubmitter {
    func submitFieldTicket(_ submission: HubFieldTicketSubmission) async throws -> HubSubmitOutcome {
        try await submitFieldTicket(submission, options: nil)
    }
}

// StoreDurability lives in StoreDurability.swift (seeded ahead of this port).
