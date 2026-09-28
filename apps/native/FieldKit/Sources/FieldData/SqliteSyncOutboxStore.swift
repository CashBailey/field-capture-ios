// Port of src/data/SqliteSyncOutboxStore.ts — Durable `SyncOutboxStore` over SQLite: the generic
// ADR 004 operation outbox behind the full sync engine. Rows are keyed by opId, carry the full
// envelope (write identity included), the contracts state machine state, retry metadata, the
// committed change token, and timestamps. The submit/dispatch path never deletes rows; pruning
// accepted rows moves their opIds into the `committed_ops` ledger so dependency planning still
// resolves them (`planDispatch`'s `committedOpIds`).
import Foundation
import FieldContracts
import FieldDomain

// ---- OperationEnvelope<JSONValue> <-> JSON object ----

private func envelopeToJSON(_ env: OperationEnvelope<JSONValue>) -> [String: Any] {
    var obj: [String: Any] = [
        "opId": env.opId,
        "kind": env.kind.rawValue,
        "type": env.type,
        "idempotencyKey": env.idempotencyKey,
        "localSeq": env.localSeq,
        "dependsOn": env.dependsOn,
    ]
    if let p = env.precondition { obj["precondition"] = ["baseVersion": p.baseVersion] }
    obj["payload"] = jsonValueToAny(env.payload)
    return obj
}

private func envelopeFromJSON(_ obj: [String: Any]) -> OperationEnvelope<JSONValue>? {
    guard let opId = obj["opId"] as? String, let kindRaw = obj["kind"] as? String,
        let kind = OperationKind(rawValue: kindRaw), let type = obj["type"] as? String,
        let idempotencyKey = obj["idempotencyKey"] as? String,
        let localSeq = (obj["localSeq"] as? NSNumber)?.intValue
    else { return nil }
    let dependsOn = (obj["dependsOn"] as? [Any])?.compactMap { $0 as? String } ?? []
    let precondition: VersionPrecondition? = (obj["precondition"] as? [String: Any]).flatMap {
        ($0["baseVersion"] as? NSNumber).map { VersionPrecondition(baseVersion: $0.intValue) }
    }
    let payload = jsonValueFromAny(obj["payload"] ?? NSNull())
    return OperationEnvelope(
        opId: opId, kind: kind, type: type, idempotencyKey: idempotencyKey, localSeq: localSeq,
        dependsOn: dependsOn, precondition: precondition, payload: payload)
}

private let COLUMNS =
    "op_id, idempotency_key, envelope_json, state, retry_count, committed_epoch, committed_seq, "
    + "rejection_code, last_error, next_attempt_at_ms, created_at, updated_at"

private let SAVE_SQL =
    "INSERT OR REPLACE INTO sync_outbox (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

private func toRowParams(_ item: DurableSyncOutboxItem) throws -> [SqlValue] {
    [
        .text(item.envelope.opId),
        .text(item.envelope.idempotencyKey),
        .text(try jsonStringify(envelopeToJSON(item.envelope))),
        .text(item.state.rawValue),
        .int(Int64(item.retryCount)),
        item.committedToken.map { .int(Int64($0.authorityEpoch)) } ?? .null,
        item.committedToken.map { .int(Int64($0.commitSeq)) } ?? .null,
        item.rejectionCode.map(SqlValue.text) ?? .null,
        item.lastError.map(SqlValue.text) ?? .null,
        item.nextAttemptAtMs.map(SqlValue.int) ?? .null,
        .text(item.createdAt),
        .text(item.updatedAt),
    ]
}

/// Parse one row, or nil when its envelope JSON is corrupted — a corrupt row must never take the
/// whole outbox down; corrupt opIds stay visible via `listCorruptOpIds()`.
private func fromRowSafe(_ row: SqlRow) -> DurableSyncOutboxItem? {
    guard let text = row.string("envelope_json"), let obj = (try? jsonParse(text)) as? [String: Any],
        let envelope = envelopeFromJSON(obj),
        let storedOpId = row.string("op_id"), envelope.opId == storedOpId,
        let storedIdempotencyKey = row.string("idempotency_key"),
        envelope.idempotencyKey == storedIdempotencyKey,
        let stateRaw = row.string("state"), let state = OutboxItemState(rawValue: stateRaw),
        let retryCount = row.int("retry_count"), retryCount >= 0,
        let createdAt = row.string("created_at"), !createdAt.isEmpty,
        let updatedAt = row.string("updated_at"), !updatedAt.isEmpty
    else { return nil }
    let committedEpoch = row.int("committed_epoch")
    let committedSeq = row.int("committed_seq")
    let committedToken: ChangeToken?
    if let committedEpoch, let committedSeq {
        committedToken = ChangeToken(authorityEpoch: Int(committedEpoch), commitSeq: Int(committedSeq))
    } else if committedEpoch == nil, committedSeq == nil {
        committedToken = nil
    } else {
        return nil
    }
    return DurableSyncOutboxItem(
        envelope: envelope, state: state, retryCount: Int(retryCount),
        committedToken: committedToken, rejectionCode: row.string("rejection_code"),
        lastError: row.string("last_error"), createdAt: createdAt,
        updatedAt: updatedAt, nextAttemptAtMs: row.int("next_attempt_at_ms"))
}

public final class SqliteSyncOutboxStore: SyncOutboxStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func save(_ item: DurableSyncOutboxItem) throws {
        try db.run(SAVE_SQL, try toRowParams(item))
    }

    public func saveAll(_ items: [DurableSyncOutboxItem]) throws {
        guard !items.isEmpty else { return }
        try db.transaction {
            for item in items {
                try db.run(SAVE_SQL, try toRowParams(item))
            }
        }
    }

    public func get(_ opId: String) throws -> DurableSyncOutboxItem? {
        try db.first("SELECT \(COLUMNS) FROM sync_outbox WHERE op_id = ?", [.text(opId)])
            .flatMap(fromRowSafe)
    }

    public func list() throws -> [DurableSyncOutboxItem] {
        try db.all("SELECT \(COLUMNS) FROM sync_outbox ORDER BY created_at, op_id").compactMap(fromRowSafe)
    }

    public func listByState(_ state: OutboxItemState) throws -> [DurableSyncOutboxItem] {
        try db.all(
            "SELECT \(COLUMNS) FROM sync_outbox WHERE state = ? ORDER BY created_at, op_id",
            [.text(state.rawValue)]
        ).compactMap(fromRowSafe)
    }

    public func committedOpIds() throws -> Set<String> {
        Set(try db.all("SELECT op_id FROM committed_ops").compactMap { $0.string("op_id") })
    }

    /// opIds of rows whose stored envelope no longer parses — surfaced, not hidden.
    public func listCorruptOpIds() throws -> [String] {
        try db.all("SELECT \(COLUMNS) FROM sync_outbox")
            .filter { fromRowSafe($0) == nil }
            .compactMap { $0.string("op_id") }
    }

    /**
     * Prune ONE accepted row: delete it and record its opId in the committed-op ledger, in a
     * single transaction. Refuses (throws) for any non-accepted state — the pruning policy layer
     * decides WHAT to prune; this guard makes "prune unsynced work" unrepresentable at the store.
     */
    public func pruneAcceptedToLedger(_ opId: String, _ committedAt: String) throws {
        try db.transaction {
            guard let row = try db.first("SELECT state FROM sync_outbox WHERE op_id = ?", [.text(opId)])
            else {
                throw SqlError(message: "cannot prune \(opId): not in the outbox", code: 1)
            }
            guard row.string("state") == "accepted" else {
                throw SqlError(
                    message:
                        "cannot prune \(opId): state is '\(row.string("state") ?? "")', only 'accepted' may be pruned",
                    code: 1)
            }
            try db.run("DELETE FROM sync_outbox WHERE op_id = ?", [.text(opId)])
            try db.run(
                "INSERT OR REPLACE INTO committed_ops (op_id, committed_at) VALUES (?, ?)",
                [.text(opId), .text(committedAt)])
        }
    }
}
