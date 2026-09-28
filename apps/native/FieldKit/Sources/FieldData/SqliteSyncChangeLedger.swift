// Port of src/data/SqliteSyncChangeLedger.ts — Durable down-sync applied-changes ledger over
// SQLite (ADR-004 §4g). Idempotent on the server-issued (authority_epoch, commit_seq) primary
// key, so re-applying a change page after a crash-between-apply-and-frontier-persist records
// each change exactly once.
import Foundation
import FieldContracts
import FieldDomain

private let COLUMNS =
    "authority_epoch, commit_seq, op_id, entity_type, entity_id, change_type, payload_json, created_at"

private func fromRow(_ row: SqlRow) -> SyncChangeRow {
    let payload: JSONValue
    if let text = row.string("payload_json"), let parsed = try? jsonParse(text) {
        payload = jsonValueFromAny(parsed)
    } else {
        payload = .null
    }
    return SyncChangeRow(
        authorityEpoch: Int(row.int("authority_epoch") ?? 0),
        commitSeq: Int(row.int("commit_seq") ?? 0),
        opId: row.string("op_id") ?? "",
        entityType: row.string("entity_type") ?? "",
        entityId: row.string("entity_id") ?? "",
        changeType: row.string("change_type") ?? "",
        payload: payload,
        createdAt: row.string("created_at") ?? ""
    )
}

public final class SqliteSyncChangeLedger: SyncChangeLedger {
    private let db: SqlDriver
    public let durability: StoreDurability
    private let now: () -> Date

    public init(_ db: SqlDriver, _ durability: StoreDurability, now: @escaping () -> Date = { Date() }) {
        self.db = db
        self.durability = durability
        self.now = now
    }

    public func record(_ change: SyncChangeRow) throws -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try db.transaction {
            let keyParams: [SqlValue] = [
                .int(Int64(change.authorityEpoch)), .int(Int64(change.commitSeq)),
            ]
            guard
                try db.first(
                    "SELECT 1 AS one FROM sync_changes WHERE authority_epoch = ? AND commit_seq = ?",
                    keyParams) == nil
            else { return false }

            try db.run(
                "INSERT INTO sync_changes (\(COLUMNS), applied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .int(Int64(change.authorityEpoch)),
                    .int(Int64(change.commitSeq)),
                    .text(change.opId),
                    .text(change.entityType),
                    .text(change.entityId),
                    .text(change.changeType),
                    .text(try jsonStringify(jsonValueToAny(change.payload))),
                    .text(change.createdAt),
                    .text(formatter.string(from: now())),
                ])
            return true
        }
    }

    public func has(_ authorityEpoch: Int, _ commitSeq: Int) -> Bool {
        (try! db.first(
            "SELECT 1 AS one FROM sync_changes WHERE authority_epoch = ? AND commit_seq = ?",
            [.int(Int64(authorityEpoch)), .int(Int64(commitSeq))])) != nil
    }

    public func count() -> Int {
        Int((try! db.first("SELECT COUNT(*) AS n FROM sync_changes"))?.int("n") ?? 0)
    }

    public func list() -> [SyncChangeRow] {
        (try! db.all("SELECT \(COLUMNS) FROM sync_changes ORDER BY authority_epoch, commit_seq")).map(fromRow)
    }
}
