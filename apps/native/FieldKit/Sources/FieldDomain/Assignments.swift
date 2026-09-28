// Port of src/domain/assignments.ts — Tolerant parsing of the real opshub assignment wire shape
// into the typed `HubAssignment` / `AssignmentDetails` domain model. Any malformed REQUIRED field
// (service_request_id, snapshot_hash) throws `HubResponseError`; malformed OPTIONAL fields are
// simply dropped rather than wire-breaking the whole assignment list.
import Foundation
import FieldContracts

private let KNOWN_ASSIGNMENT_STATUSES: [AssignmentStatus] = AssignmentStatus.allCases

private func isRecord(_ value: Any?) -> Bool {
    value is [String: Any]
}

/// nil/NSNull → nil. A string → trimmed non-empty string, or throws. Anything else → throws.
private func optionalString(_ value: Any?, _ path: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    guard let s = value as? String else {
        throw HubResponseError("\(path) must be a non-empty string")
    }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw HubResponseError("\(path) must be a non-empty string")
    }
    return trimmed
}

/// The first present, non-blank string among `keys` on `rec`. A present-but-blank string is
/// treated as absent so a later key (or the id fallback) can supply the label — the real Hub
/// sends "" for optional labels (e.g. well field_name), and a blank must never wire-break the
/// assignment list. Non-string values still defer to `optionalString` for a clear typed error.
private func firstString(_ rec: [String: Any], _ path: String, _ keys: [String]) throws -> String? {
    for key in keys {
        guard let value = rec[key], !(value is NSNull) else { continue }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return trimmed
        }
        return try optionalString(value, "\(path).\(key)")
    }
    return nil
}

private func parseNamedRef(
    _ value: Any?,
    _ path: String,
    idKeys: [String],
    nameKeys: [String] = ["name", "label", "display_name"]
) throws -> AssignmentNamedRef? {
    guard let value, !(value is NSNull) else { return nil }
    if value is String {
        guard let name = try optionalString(value, path) else {
            throw HubResponseError("\(path) must be a non-empty string")
        }
        return AssignmentNamedRef(name: name)
    }
    guard let rec = value as? [String: Any] else {
        throw HubResponseError("\(path) must be an object or string")
    }
    let id = try firstString(rec, path, idKeys)
    let name = try firstString(rec, path, nameKeys) ?? id
    guard let name else {
        throw HubResponseError("\(path).name is required when \(path) is set")
    }
    return AssignmentNamedRef(id: id, name: name)
}

private func parseWell(_ value: Any?, _ path: String) throws -> AssignmentWell {
    // The real Hub sends the driver-facing well label as `well_no` (e.g. "114H"), not `name`;
    // prefer it so the driver sees the well number instead of a falling-back-to-id UUID.
    guard
        let named = try parseNamedRef(
            value, path,
            idKeys: ["well_id", "wellId", "id"],
            nameKeys: ["well_no", "name", "label", "display_name"]
        )
    else {
        throw HubResponseError("\(path) is required")
    }
    let rec = (value as? [String: Any]) ?? [:]
    let leaseId = try firstString(rec, path, ["lease_id", "leaseId"])
    return AssignmentWell(id: named.id, name: named.name, leaseId: leaseId)
}

private func parseWells(_ value: Any?, _ path: String) throws -> [AssignmentWell]? {
    guard let value, !(value is NSNull) else { return nil }
    guard let array = value as? [Any] else {
        throw HubResponseError("\(path) must be a list")
    }
    return try array.enumerated().map { index, entry in try parseWell(entry, "\(path)[\(index)]") }
}

private func parseDisposalSite(_ value: Any?, _ path: String) throws -> AssignmentDisposalSite? {
    try parseNamedRef(value, path, idKeys: ["site_id", "disposal_site_id", "id"])
}

private func parseMaterial(_ value: Any?, _ path: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if value is String { return try optionalString(value, path) }
    guard let rec = value as? [String: Any] else {
        throw HubResponseError("\(path) must be an object or string")
    }
    return try firstString(rec, path, ["name", "label", "material_name", "description"])
}

/// The real Hub sends a STRING equal to snapshot_hash. Tolerate a legacy finite number by
/// coercing to its string form so older cached/replayed payloads still parse.
private func parseLatestServerVersion(_ value: Any?, _ path: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let d = finiteDouble(value) {
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
    return try optionalString(value, path)
}

/// Wraps the contracts `parseWorkflowRequirements(_:)` with the domain-level nil/type checks the
/// TS local function of the same name performed before delegating to `fieldwork.parseWorkflowRequirements`.
private func parseAssignmentWorkflowRequirements(_ value: Any?) throws -> WorkflowRequirements? {
    guard let value, !(value is NSNull) else { return nil }
    guard isRecord(value) else {
        throw HubResponseError("workflow_requirements must be an object")
    }
    return FieldContracts.parseWorkflowRequirements(value)
}

/// Tolerant status parse: unknown/malformed values yield nil — never a wire-break.
private func parseStatus(_ value: Any?) -> AssignmentStatus? {
    guard let raw = value as? String else { return nil }
    var normalized = ""
    var lastWasSeparator = false
    for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        if ch == " " || ch == "-" {
            if !lastWasSeparator { normalized.append("_") }
            lastWasSeparator = true
        } else {
            normalized.append(ch)
            lastWasSeparator = false
        }
    }
    return KNOWN_ASSIGNMENT_STATUSES.first { $0.rawValue == normalized }
}

/// Numeric coercion from an untyped JSON value: excludes booleans (which bridge to NSNumber),
/// accepts Int/Double/NSNumber, requires finiteness.
private func finiteDouble(_ value: Any) -> Double? {
    if value is Bool { return nil }
    switch value {
    case let d as Double: return d.isFinite ? d : nil
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
    default: return nil
    }
}

private func parseGpsPoint(_ value: Any?) -> AssignmentGpsPoint? {
    guard let rec = value as? [String: Any] else { return nil }
    guard let lat = rec["lat"].flatMap(finiteDouble), let lon = rec["lon"].flatMap(finiteDouble) else {
        return nil
    }
    return AssignmentGpsPoint(lat: lat, lon: lon)
}

/// Validation-only coordinates from Hub `coordinates` ({primary, wells[]}). Malformed GPS points
/// are dropped (never throw) — but a malformed well id (present, non-string) still throws via
/// `firstString`, matching the TS which does not catch it here either.
private func parseCoordinates(_ value: Any?) throws -> AssignmentCoordinates? {
    guard let rec = value as? [String: Any] else { return nil }
    let primary = parseGpsPoint(rec["primary"])
    let rawWells = (rec["wells"] as? [Any]) ?? []
    var wells: [AssignmentWellCoordinate] = []
    for raw in rawWells {
        guard let point = parseGpsPoint(raw) else { continue }
        var wellId: String?
        if let rawRec = raw as? [String: Any] {
            wellId = try firstString(rawRec, "coordinates.wells", ["well_id", "wellId", "id"])
        }
        wells.append(AssignmentWellCoordinate(lat: point.lat, lon: point.lon, wellId: wellId))
    }
    if primary == nil, wells.isEmpty { return nil }
    return AssignmentCoordinates(primary: primary, wells: wells)
}

private func parseGeofenceHints(_ value: Any?) -> AssignmentGeofenceHints? {
    guard let rec = value as? [String: Any] else { return nil }
    let radiusM = rec["radius_m"].flatMap(finiteDouble)
    let required = (rec["required"] as? Bool) == true
    // The real Hub sends source: "" when there are no coordinates; tolerate it (never throw).
    let source = (rec["source"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap {
        $0.isEmpty ? nil : $0
    }
    if radiusM == nil, !required, source == nil { return nil }
    return AssignmentGeofenceHints(radiusM: radiusM, required: required, source: source)
}

public func parseAssignmentDetails(_ entry: [String: Any]) throws -> AssignmentDetails? {
    var details = AssignmentDetails()
    details.requestNo = try optionalString(entry["request_no"] ?? entry["requestNo"], "request_no")
    details.status = parseStatus(entry["status"])
    details.customer = try parseNamedRef(entry["customer"], "customer", idKeys: ["customer_id", "id"])
    details.lease = try parseNamedRef(entry["lease"], "lease", idKeys: ["lease_id", "id"])
    details.wells = try parseWells(entry["wells"], "wells")
    details.material = try parseMaterial(entry["material"], "material")
    details.disposalSite = try parseDisposalSite(entry["disposal_site"] ?? entry["disposalSite"], "disposal_site")
    // The real Hub sends the driver-facing vehicle label as `truck_no` (e.g. "Truck 12"), not
    // `name`; prefer it so the driver sees the truck number instead of a falling-back-to-id UUID.
    details.vehicle = try parseNamedRef(
        entry["vehicle"], "vehicle",
        idKeys: ["vehicle_id", "id"],
        nameKeys: ["truck_no", "name", "label", "display_name"]
    )
    details.trailer = try parseNamedRef(entry["trailer"], "trailer", idKeys: ["trailer_id", "id"])
    details.jobType = try parseNamedRef(
        entry["job_type"] ?? entry["jobType"], "job_type", idKeys: ["job_type_id", "id"])
    details.coordinates = try parseCoordinates(entry["coordinates"])
    details.geofenceHints = parseGeofenceHints(entry["geofence_hints"] ?? entry["geofenceHints"])
    details.workflowRequirements = try parseAssignmentWorkflowRequirements(
        entry["workflow_requirements"] ?? entry["workflowRequirements"])
    let isEmpty =
        details.requestNo == nil && details.status == nil && details.customer == nil
        && details.lease == nil && details.wells == nil && details.material == nil
        && details.disposalSite == nil && details.vehicle == nil && details.trailer == nil
        && details.jobType == nil && details.coordinates == nil && details.geofenceHints == nil
        && details.workflowRequirements == nil
    return isEmpty ? nil : details
}

public func parseHubAssignmentEntry(_ entry: Any, indexLabel: String = "assignment") throws -> HubAssignment {
    guard let rec = entry as? [String: Any] else {
        throw HubResponseError("\(indexLabel) is not an object")
    }
    guard let serviceRequestId = try optionalString(rec["service_request_id"], "\(indexLabel).service_request_id"),
        let snapshotHash = try optionalString(rec["snapshot_hash"], "\(indexLabel).snapshot_hash")
    else {
        throw HubResponseError("\(indexLabel) is missing service_request_id and/or snapshot_hash")
    }
    let latestServerVersion = try parseLatestServerVersion(
        rec["latest_server_version"] ?? rec["latestServerVersion"], "\(indexLabel).latest_server_version"
    )
    let details = try parseAssignmentDetails(rec)
    let snapshot = rec["snapshot"] ?? NSNull()
    return HubAssignment(
        serviceRequestId: serviceRequestId,
        snapshotHash: snapshotHash,
        snapshot: snapshot is NSNull ? nil : snapshot,
        latestServerVersion: latestServerVersion,
        details: details
    )
}

private func workflowRequirementsFromSnapshot(_ snapshot: Any?) -> WorkflowRequirements {
    let config: Any?
    if let rec = snapshot as? [String: Any], rec["workflow_requirements"] != nil {
        config = rec["workflow_requirements"]
    } else {
        config = snapshot
    }
    return FieldContracts.parseWorkflowRequirements(config)
}

public func parseWorkflowRequirementsFromAssignments(
    _ assignments: [HubAssignment],
    _ serviceRequestId: String? = nil
) -> WorkflowRequirements {
    let assignment: HubAssignment?
    if let serviceRequestId {
        assignment = assignments.first { $0.serviceRequestId == serviceRequestId }
    } else {
        assignment = assignments.first
    }
    if let requirements = assignment?.details?.workflowRequirements {
        return requirements
    }
    return workflowRequirementsFromSnapshot(assignment?.snapshot)
}

/// Whether a job is a flowback job, by its SR `job_type` name. The customer signature is required
/// ONLY for flowback (item 6); every other job type neither shows nor requires it. Isolated here
/// as one small predicate so the flowback rule is trivial to tweak in one place.
public func isFlowbackJob(_ jobType: String?) -> Bool {
    (jobType ?? "").lowercased().contains("flowback")
}
