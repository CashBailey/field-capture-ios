// Port of src/data/SqliteAssignmentStore.ts — Durable `AssignmentStore` over the local SQLite
// database. Hub is the authority on assignment: each successful pull wholesale-replaces the
// cached set (in one transaction, so a crash mid-replace can never leave a half-merged cache).
// Snapshots are stored verbatim as JSON — Mobile never edits or merges them (contract boundary).
import Foundation
import FieldContracts
import FieldDomain

// ---- rich_json (AssignmentDetails) <-> JSON object ----

private func namedRefToJSON(_ ref: AssignmentNamedRef) -> [String: Any] {
    var obj: [String: Any] = ["name": ref.name]
    if let id = ref.id { obj["id"] = id }
    return obj
}

private func namedRefFromJSON(_ obj: [String: Any]) -> AssignmentNamedRef? {
    guard let name = obj["name"] as? String else { return nil }
    return AssignmentNamedRef(id: obj["id"] as? String, name: name)
}

private func wellToJSON(_ w: AssignmentWell) -> [String: Any] {
    var obj: [String: Any] = ["name": w.name]
    if let id = w.id { obj["id"] = id }
    if let leaseId = w.leaseId { obj["leaseId"] = leaseId }
    return obj
}

private func wellFromJSON(_ obj: [String: Any]) -> AssignmentWell? {
    guard let name = obj["name"] as? String else { return nil }
    return AssignmentWell(id: obj["id"] as? String, name: name, leaseId: obj["leaseId"] as? String)
}

private func gpsPointToJSON(_ p: AssignmentGpsPoint) -> [String: Any] {
    ["lat": p.lat, "lon": p.lon]
}

private func gpsPointFromJSON(_ obj: [String: Any]) -> AssignmentGpsPoint? {
    guard let lat = obj["lat"] as? NSNumber, let lon = obj["lon"] as? NSNumber else { return nil }
    return AssignmentGpsPoint(lat: lat.doubleValue, lon: lon.doubleValue)
}

private func wellCoordToJSON(_ w: AssignmentWellCoordinate) -> [String: Any] {
    var obj: [String: Any] = ["lat": w.lat, "lon": w.lon]
    if let wellId = w.wellId { obj["wellId"] = wellId }
    return obj
}

private func wellCoordFromJSON(_ obj: [String: Any]) -> AssignmentWellCoordinate? {
    guard let lat = obj["lat"] as? NSNumber, let lon = obj["lon"] as? NSNumber else { return nil }
    return AssignmentWellCoordinate(lat: lat.doubleValue, lon: lon.doubleValue, wellId: obj["wellId"] as? String)
}

private func coordinatesToJSON(_ c: AssignmentCoordinates) -> [String: Any] {
    var obj: [String: Any] = ["wells": c.wells.map(wellCoordToJSON)]
    if let primary = c.primary { obj["primary"] = gpsPointToJSON(primary) }
    return obj
}

private func coordinatesFromJSON(_ obj: [String: Any]) -> AssignmentCoordinates {
    let wells =
        (obj["wells"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap(wellCoordFromJSON) } ?? []
    let primary = (obj["primary"] as? [String: Any]).flatMap(gpsPointFromJSON)
    return AssignmentCoordinates(primary: primary, wells: wells)
}

private func geofenceToJSON(_ g: AssignmentGeofenceHints) -> [String: Any] {
    var obj: [String: Any] = ["required": g.required]
    if let radiusM = g.radiusM { obj["radiusM"] = radiusM }
    if let source = g.source { obj["source"] = source }
    return obj
}

private func geofenceFromJSON(_ obj: [String: Any]) -> AssignmentGeofenceHints {
    AssignmentGeofenceHints(
        radiusM: (obj["radiusM"] as? NSNumber)?.doubleValue,
        required: (obj["required"] as? NSNumber)?.boolValue ?? false,
        source: obj["source"] as? String)
}

private func workflowReqToJSON(_ w: AssignmentWorkflowRequirements) -> [String: Any] {
    ["clockInRequired": w.clockInRequired, "requiredSteps": w.requiredSteps.map(\.rawValue)]
}

private func workflowReqFromJSON(_ obj: [String: Any]) -> AssignmentWorkflowRequirements {
    let steps =
        (obj["requiredSteps"] as? [Any])?.compactMap { ($0 as? String).flatMap(WorkflowStepType.init(rawValue:)) }
        ?? []
    return AssignmentWorkflowRequirements(
        clockInRequired: (obj["clockInRequired"] as? NSNumber)?.boolValue ?? false, requiredSteps: steps)
}

private func detailsToJSON(_ d: AssignmentDetails) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = d.requestNo { obj["requestNo"] = v }
    if let v = d.status { obj["status"] = v.rawValue }
    if let v = d.customer { obj["customer"] = namedRefToJSON(v) }
    if let v = d.lease { obj["lease"] = namedRefToJSON(v) }
    if let v = d.wells { obj["wells"] = v.map(wellToJSON) }
    if let v = d.material { obj["material"] = v }
    if let v = d.disposalSite { obj["disposalSite"] = namedRefToJSON(v) }
    if let v = d.vehicle { obj["vehicle"] = namedRefToJSON(v) }
    if let v = d.trailer { obj["trailer"] = namedRefToJSON(v) }
    if let v = d.jobType { obj["jobType"] = namedRefToJSON(v) }
    if let v = d.coordinates { obj["coordinates"] = coordinatesToJSON(v) }
    if let v = d.geofenceHints { obj["geofenceHints"] = geofenceToJSON(v) }
    if let v = d.workflowRequirements { obj["workflowRequirements"] = workflowReqToJSON(v) }
    return obj
}

private func detailsFromJSON(_ obj: [String: Any]) -> AssignmentDetails {
    AssignmentDetails(
        requestNo: obj["requestNo"] as? String,
        status: (obj["status"] as? String).flatMap(AssignmentStatus.init(rawValue:)),
        customer: (obj["customer"] as? [String: Any]).flatMap(namedRefFromJSON),
        lease: (obj["lease"] as? [String: Any]).flatMap(namedRefFromJSON),
        wells: (obj["wells"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap(wellFromJSON) },
        material: obj["material"] as? String,
        disposalSite: (obj["disposalSite"] as? [String: Any]).flatMap(namedRefFromJSON),
        vehicle: (obj["vehicle"] as? [String: Any]).flatMap(namedRefFromJSON),
        trailer: (obj["trailer"] as? [String: Any]).flatMap(namedRefFromJSON),
        jobType: (obj["jobType"] as? [String: Any]).flatMap(namedRefFromJSON),
        coordinates: (obj["coordinates"] as? [String: Any]).map(coordinatesFromJSON),
        geofenceHints: (obj["geofenceHints"] as? [String: Any]).map(geofenceFromJSON),
        workflowRequirements: (obj["workflowRequirements"] as? [String: Any]).map(workflowReqFromJSON)
    )
}

// ---- snapshot_json (opaque `Any?`) ----

private func snapshotToJSON(_ snapshot: Any?) throws -> String {
    try jsonStringify(snapshot ?? NSNull())
}

private func snapshotFromJSON(_ text: String) -> Any? {
    guard let parsed = try? jsonParse(text) else { return nil }
    return parsed is NSNull ? nil : parsed
}

private func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private let COLUMNS =
    "service_request_id, snapshot_hash, snapshot_json, latest_server_version, rich_json"

private func fromRow(_ row: SqlRow) -> HubAssignment {
    let richObj = (try? jsonParse(row.string("rich_json") ?? "{}")) as? [String: Any] ?? [:]
    return HubAssignment(
        serviceRequestId: row.string("service_request_id") ?? "",
        snapshotHash: row.string("snapshot_hash") ?? "",
        snapshot: snapshotFromJSON(row.string("snapshot_json") ?? "null"),
        latestServerVersion: row.string("latest_server_version"),
        details: richObj.isEmpty ? nil : detailsFromJSON(richObj)
    )
}

public final class SqliteAssignmentStore: AssignmentStore {
    private let db: SqlDriver
    public let durability: StoreDurability
    private let now: () -> Date

    public init(_ db: SqlDriver, _ durability: StoreDurability, now: @escaping () -> Date = { Date() }) {
        self.db = db
        self.durability = durability
        self.now = now
    }

    public func putAssignments(_ assignments: [HubAssignment]) {
        let at = isoStamp(now())
        try! db.transaction {
            try db.run("DELETE FROM assignments")
            for a in assignments {
                // OR REPLACE: a duplicated SR in one Hub payload (server bug) must not abort the
                // whole refresh with a PK violation — last entry wins, matching the volatile test
                // seam.
                try db.run(
                    """
                    INSERT OR REPLACE INTO assignments (
                      \(COLUMNS), updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(a.serviceRequestId),
                        .text(a.snapshotHash),
                        .text(try snapshotToJSON(a.snapshot)),
                        a.latestServerVersion.map(SqlValue.text) ?? .null,
                        .text(try jsonStringify(a.details.map(detailsToJSON) ?? [:])),
                        .text(at),
                    ])
            }
        }
    }

    public func listAssignments() -> [HubAssignment] {
        (try! db.all("SELECT \(COLUMNS) FROM assignments ORDER BY service_request_id")).map(fromRow)
    }

    public func getSnapshotHash(_ serviceRequestId: String) -> String? {
        (try! db.first(
            "SELECT snapshot_hash FROM assignments WHERE service_request_id = ?", [.text(serviceRequestId)]))?.string(
                "snapshot_hash")
    }
}
