// Port of src/data/SqliteFieldTicketDraftStore.ts — Durable field-ticket draft storage. Drafts
// are UI-editable local work that may exist before a submit attempt creates immutable
// evidence/outbox rows, so they live in their own table.
import FieldDomain

private let COLUMNS =
    "id, service_request_id, ticket_no, quantity_bbl, disposal_ticket_no, truck, trailer, driver, notes, capture_method, created_at, updated_at"

public enum SqliteFieldTicketDraftStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case corruptRecord(id: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let id, let detail):
            return "field-ticket draft \(id) is corrupt: \(detail)"
        }
    }
}

private func corruptFieldTicketDraft(_ id: String, _ detail: String) -> SqliteFieldTicketDraftStoreError {
    .corruptRecord(id: id, detail: detail)
}

private func requiredString(_ row: SqlRow, _ column: String, id: String) throws -> String {
    guard let value = row.string(column) else {
        throw corruptFieldTicketDraft(id, "missing or invalid \(column)")
    }
    return value
}

private func optionalString(_ row: SqlRow, _ column: String, id: String) throws -> String? {
    switch row[column] {
    case .text(let value)?: return value
    case .null?: return nil
    default: throw corruptFieldTicketDraft(id, "invalid \(column)")
    }
}

private func fromRow(_ row: SqlRow) throws -> FieldTicketDraft {
    let id = row.string("id") ?? "<unknown>"
    guard let quantityBbl = row.real("quantity_bbl"), quantityBbl.isFinite else {
        throw corruptFieldTicketDraft(id, "missing or invalid quantity_bbl")
    }
    let captureMethodRaw = try optionalString(row, "capture_method", id: id)
    let captureMethod: TicketCaptureMethod?
    if let captureMethodRaw {
        guard let parsed = TicketCaptureMethod(rawValue: captureMethodRaw) else {
            throw corruptFieldTicketDraft(id, "unknown capture_method '\(captureMethodRaw)'")
        }
        captureMethod = parsed
    } else {
        captureMethod = nil
    }

    return try FieldTicketDraft(
        id: requiredString(row, "id", id: id),
        serviceRequestId: requiredString(row, "service_request_id", id: id),
        ticketNo: requiredString(row, "ticket_no", id: id),
        quantityBbl: quantityBbl,
        disposalTicketNo: requiredString(row, "disposal_ticket_no", id: id),
        truck: optionalString(row, "truck", id: id),
        trailer: optionalString(row, "trailer", id: id),
        driver: optionalString(row, "driver", id: id),
        notes: optionalString(row, "notes", id: id),
        captureMethod: captureMethod,
        // ponytail: mirrors the TS store, which never persists `detail` — `field_ticket_drafts`
        // has no detail column (see migrations.ts); the full paper-ticket detail rides only on
        // the submission payload (SqliteTicketEvidenceStore), not the draft.
        createdAt: requiredString(row, "created_at", id: id),
        updatedAt: requiredString(row, "updated_at", id: id)
    )
}

public final class SqliteFieldTicketDraftStore: FieldTicketDraftStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func save(_ draft: FieldTicketDraft) throws {
        try db.run(
            "INSERT OR REPLACE INTO field_ticket_drafts (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(draft.id),
                .text(draft.serviceRequestId),
                .text(draft.ticketNo),
                .real(draft.quantityBbl),
                .text(draft.disposalTicketNo),
                draft.truck.map(SqlValue.text) ?? .null,
                draft.trailer.map(SqlValue.text) ?? .null,
                draft.driver.map(SqlValue.text) ?? .null,
                draft.notes.map(SqlValue.text) ?? .null,
                draft.captureMethod.map { SqlValue.text($0.rawValue) } ?? .null,
                .text(draft.createdAt),
                .text(draft.updatedAt),
            ])
    }

    public func get(_ id: String) throws -> FieldTicketDraft? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM field_ticket_drafts WHERE id = ?", [.text(id)])
        else { return nil }
        return try fromRow(row)
    }

    public func list() throws -> [FieldTicketDraft] {
        try db.all("SELECT \(COLUMNS) FROM field_ticket_drafts ORDER BY updated_at, id").map(fromRow)
    }

    public func delete(_ id: String) throws {
        try db.run("DELETE FROM field_ticket_drafts WHERE id = ?", [.text(id)])
    }
}
