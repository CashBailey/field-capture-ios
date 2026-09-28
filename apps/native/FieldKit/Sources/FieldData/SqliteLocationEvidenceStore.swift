// Port of src/data/SqliteLocationEvidenceStore.ts — Durable validation-only location-evidence
// store over SQLite (Phase 7). Append-only and non-evictable — location evidence is unsynced
// field work, preserved until the Hub acks it.
import Foundation
import FieldContracts
import FieldDomain

private let COLUMNS =
    "id, service_request_id, place_kind, evidence_type, gps_json, notes, state, created_at"

private func gpsToJSON(_ gps: LocationGpsPoint) -> [String: Any] {
    ["lat": gps.lat, "lon": gps.lon, "accuracyM": gps.accuracyM, "timestampMs": gps.timestampMs]
}

private func gpsFromJSON(_ text: String) -> LocationGpsPoint? {
    guard let obj = (try? jsonParse(text)) as? [String: Any] else { return nil }
    guard let lat = obj["lat"] as? NSNumber, let lon = obj["lon"] as? NSNumber,
        let accuracyM = obj["accuracyM"] as? NSNumber, let timestampMs = obj["timestampMs"] as? NSNumber
    else { return nil }
    return LocationGpsPoint(
        lat: lat.doubleValue, lon: lon.doubleValue, accuracyM: accuracyM.doubleValue,
        timestampMs: timestampMs.int64Value)
}

private func fromRow(_ row: SqlRow) -> LocationEvidence {
    LocationEvidence(
        id: row.string("id") ?? "",
        serviceRequestId: row.string("service_request_id") ?? "",
        placeKind: LocationPlaceKind(rawValue: row.string("place_kind") ?? "") ?? .other,
        evidenceType: row.string("evidence_type") ?? "",
        gps: row.string("gps_json").flatMap(gpsFromJSON),
        notes: row.string("notes"),
        state: LocationEvidenceState(rawValue: row.string("state") ?? "") ?? .notCaptured,
        createdAt: row.string("created_at") ?? ""
    )
}

public final class SqliteLocationEvidenceStore: LocationEvidenceStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func record(_ evidence: LocationEvidence) throws {
        // Plain INSERT (no OR REPLACE): append-only — a duplicate id hits the primary-key
        // constraint and throws, never silently overwrites unsynced field work.
        try db.run(
            "INSERT INTO location_evidence (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(evidence.id),
                .text(evidence.serviceRequestId),
                .text(evidence.placeKind.rawValue),
                .text(evidence.evidenceType),
                try evidence.gps.map { .text(try jsonStringify(gpsToJSON($0))) } ?? .null,
                evidence.notes.map(SqlValue.text) ?? .null,
                .text(evidence.state.rawValue),
                .text(evidence.createdAt),
            ])
    }

    public func get(_ id: String) -> LocationEvidence? {
        (try! db.first("SELECT \(COLUMNS) FROM location_evidence WHERE id = ?", [.text(id)]))
            .map(fromRow)
    }

    public func listByServiceRequest(_ serviceRequestId: String) -> [LocationEvidence] {
        (try! db.all(
            "SELECT \(COLUMNS) FROM location_evidence WHERE service_request_id = ? ORDER BY created_at, id",
            [.text(serviceRequestId)])).map(fromRow)
    }

    public func list() -> [LocationEvidence] {
        (try! db.all("SELECT \(COLUMNS) FROM location_evidence ORDER BY created_at, id")).map(fromRow)
    }
}
