// Port of src/data/SqliteReceiptDraftStore.ts — Durable receipt-draft storage (Phase 5):
// UI-editable local work that exists before any submit, preserved until submitted or explicitly
// deleted, in its own table like field_ticket_drafts.
import FieldDomain

private let COLUMNS =
    "id, service_request_id, receipt_type, vendor, receipt_no, amount, notes, ticket_draft_id, created_at, updated_at"

public enum SqliteReceiptDraftStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case corruptRecord(id: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let id, let detail):
            return "receipt draft \(id) is corrupt: \(detail)"
        }
    }
}

private func corruptReceiptDraft(_ id: String, _ detail: String) -> SqliteReceiptDraftStoreError {
    .corruptRecord(id: id, detail: detail)
}

private func requiredString(_ row: SqlRow, _ column: String, id: String) throws -> String {
    guard let value = row.string(column) else {
        throw corruptReceiptDraft(id, "missing or invalid \(column)")
    }
    return value
}

private func optionalString(_ row: SqlRow, _ column: String, id: String) throws -> String? {
    switch row[column] {
    case .text(let value)?: return value
    case .null?: return nil
    default: throw corruptReceiptDraft(id, "invalid \(column)")
    }
}

private func fromRow(_ row: SqlRow) throws -> ReceiptDraft {
    let id = row.string("id") ?? "<unknown>"
    guard let receiptTypeRaw = row.string("receipt_type"), let receiptType = ReceiptType(rawValue: receiptTypeRaw)
    else {
        throw corruptReceiptDraft(id, "unknown or missing receipt_type")
    }
    guard let amount = row.real("amount"), amount.isFinite else {
        throw corruptReceiptDraft(id, "missing or invalid amount")
    }

    return try ReceiptDraft(
        id: requiredString(row, "id", id: id),
        serviceRequestId: requiredString(row, "service_request_id", id: id),
        receiptType: receiptType,
        vendor: requiredString(row, "vendor", id: id),
        receiptNo: requiredString(row, "receipt_no", id: id),
        amount: amount,
        notes: requiredString(row, "notes", id: id),
        ticketDraftId: optionalString(row, "ticket_draft_id", id: id),
        createdAt: requiredString(row, "created_at", id: id),
        updatedAt: requiredString(row, "updated_at", id: id)
    )
}

public final class SqliteReceiptDraftStore: ReceiptDraftStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func save(_ draft: ReceiptDraft) throws {
        try db.run(
            "INSERT OR REPLACE INTO receipt_drafts (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(draft.id),
                .text(draft.serviceRequestId),
                .text(draft.receiptType.rawValue),
                .text(draft.vendor),
                .text(draft.receiptNo),
                .real(draft.amount),
                .text(draft.notes),
                draft.ticketDraftId.map(SqlValue.text) ?? .null,
                .text(draft.createdAt),
                .text(draft.updatedAt),
            ])
    }

    public func get(_ id: String) throws -> ReceiptDraft? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM receipt_drafts WHERE id = ?", [.text(id)])
        else { return nil }
        return try fromRow(row)
    }

    public func list() throws -> [ReceiptDraft] {
        try db.all("SELECT \(COLUMNS) FROM receipt_drafts ORDER BY created_at, id").map(fromRow)
    }

    public func delete(_ id: String) throws {
        try db.run("DELETE FROM receipt_drafts WHERE id = ?", [.text(id)])
    }
}
