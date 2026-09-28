// Port of src/data/SqliteTicketEvidenceStore.ts — Durable `TicketEvidenceStore` over the local
// SQLite database — the real outbox table. Unsynced work survives restart: rows are keyed by
// idempotency key and carry the full envelope (payload + write identity), submit status,
// rejection code/detail/http-status, outcome timestamps, and retry metadata. Nothing is ever
// deleted here by the submit path — accepted rows are kept as local proof of what was sent until
// a later pruning slice.
import Foundation
import FieldContracts
import FieldDomain

// ---- FieldTicketDetail <-> JSON object ----

private func ftInToJSON(_ f: FtIn) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = f.ft { obj["ft"] = v }
    if let v = f.inches { obj["inches"] = v }
    return obj
}

private func ftInFromJSON(_ obj: [String: Any]) -> FtIn {
    FtIn(ft: (obj["ft"] as? NSNumber)?.doubleValue, inches: (obj["inches"] as? NSNumber)?.doubleValue)
}

private func gaugeReadingToJSON(_ g: GaugeReading) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = g.total { obj["total"] = ftInToJSON(v) }
    if let v = g.water { obj["water"] = ftInToJSON(v) }
    if let v = g.condensate { obj["condensate"] = ftInToJSON(v) }
    return obj
}

private func gaugeReadingFromJSON(_ obj: [String: Any]) -> GaugeReading {
    GaugeReading(
        total: (obj["total"] as? [String: Any]).map(ftInFromJSON),
        water: (obj["water"] as? [String: Any]).map(ftInFromJSON),
        condensate: (obj["condensate"] as? [String: Any]).map(ftInFromJSON))
}

private func tankGaugeToJSON(_ t: TankGauge) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = t.label { obj["label"] = v }
    if let v = t.locationTime { obj["locationTime"] = v }
    if let v = t.beginning { obj["beginning"] = gaugeReadingToJSON(v) }
    if let v = t.ending { obj["ending"] = gaugeReadingToJSON(v) }
    if let v = t.waterPulled { obj["waterPulled"] = ftInToJSON(v) }
    if let v = t.barrelsPulled { obj["barrelsPulled"] = v }
    return obj
}

private func tankGaugeFromJSON(_ obj: [String: Any]) -> TankGauge {
    TankGauge(
        label: obj["label"] as? String, locationTime: obj["locationTime"] as? String,
        beginning: (obj["beginning"] as? [String: Any]).map(gaugeReadingFromJSON),
        ending: (obj["ending"] as? [String: Any]).map(gaugeReadingFromJSON),
        waterPulled: (obj["waterPulled"] as? [String: Any]).map(ftInFromJSON),
        barrelsPulled: (obj["barrelsPulled"] as? NSNumber)?.doubleValue)
}

private func lineItemToJSON(_ l: TicketLineItem) -> [String: Any] {
    var obj: [String: Any] = ["description": l.description]
    if let v = l.qty { obj["qty"] = v }
    if let v = l.rate { obj["rate"] = v }
    if let v = l.total { obj["total"] = v }
    return obj
}

private func lineItemFromJSON(_ obj: [String: Any]) -> TicketLineItem? {
    guard let description = obj["description"] as? String else { return nil }
    return TicketLineItem(
        description: description, qty: (obj["qty"] as? NSNumber)?.doubleValue,
        rate: (obj["rate"] as? NSNumber)?.doubleValue, total: (obj["total"] as? NSNumber)?.doubleValue)
}

private func timesToJSON(_ t: FieldTicketTimes) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = t.yardArrival { obj["yardArrival"] = v }
    if let v = t.timeIn { obj["timeIn"] = v }
    if let v = t.timeOut { obj["timeOut"] = v }
    return obj
}

private func timesFromJSON(_ obj: [String: Any]) -> FieldTicketTimes {
    FieldTicketTimes(
        yardArrival: obj["yardArrival"] as? String, timeIn: obj["timeIn"] as? String,
        timeOut: obj["timeOut"] as? String)
}

private func detailToJSON(_ d: FieldTicketDetail) -> [String: Any] {
    var obj: [String: Any] = [:]
    if let v = d.rigNo { obj["rigNo"] = v }
    if let v = d.times { obj["times"] = timesToJSON(v) }
    if let v = d.tanks { obj["tanks"] = v.map(tankGaugeToJSON) }
    if let v = d.lineItems { obj["lineItems"] = v.map(lineItemToJSON) }
    return obj
}

private func detailFromJSON(_ obj: [String: Any]) -> FieldTicketDetail {
    FieldTicketDetail(
        rigNo: obj["rigNo"] as? String,
        times: (obj["times"] as? [String: Any]).map(timesFromJSON),
        tanks: (obj["tanks"] as? [Any])?.compactMap { ($0 as? [String: Any]).map(tankGaugeFromJSON) },
        lineItems: (obj["lineItems"] as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap(lineItemFromJSON) }
    )
}

// ---- HubFieldTicketSubmission <-> JSON object ----

private func submissionToJSON(_ p: HubFieldTicketSubmission) -> [String: Any] {
    var obj: [String: Any] = [
        "idempotencyKey": p.idempotencyKey,
        "serviceRequestId": p.serviceRequestId,
        "snapshotHash": p.snapshotHash,
        "ticketNo": p.ticketNo,
        "quantityBbl": p.quantityBbl,
        "disposalTicketNo": p.disposalTicketNo,
    ]
    if let v = p.detail { obj["detail"] = detailToJSON(v) }
    return obj
}

private func submissionFromJSON(_ obj: [String: Any]) -> HubFieldTicketSubmission? {
    guard let idempotencyKey = obj["idempotencyKey"] as? String,
        let serviceRequestId = obj["serviceRequestId"] as? String,
        let snapshotHash = obj["snapshotHash"] as? String,
        let ticketNo = obj["ticketNo"] as? String,
        let quantityBbl = (obj["quantityBbl"] as? NSNumber)?.doubleValue,
        let disposalTicketNo = obj["disposalTicketNo"] as? String
    else { return nil }
    return HubFieldTicketSubmission(
        idempotencyKey: idempotencyKey, serviceRequestId: serviceRequestId, snapshotHash: snapshotHash,
        ticketNo: ticketNo, quantityBbl: quantityBbl, disposalTicketNo: disposalTicketNo,
        detail: (obj["detail"] as? [String: Any]).map(detailFromJSON))
}

// ---- OperationEnvelope<HubFieldTicketSubmission> <-> JSON object ----

private func envelopeToJSON(_ env: OperationEnvelope<HubFieldTicketSubmission>) -> [String: Any] {
    var obj: [String: Any] = [
        "opId": env.opId,
        "kind": env.kind.rawValue,
        "type": env.type,
        "idempotencyKey": env.idempotencyKey,
        "localSeq": env.localSeq,
        "dependsOn": env.dependsOn,
    ]
    if let p = env.precondition { obj["precondition"] = ["baseVersion": p.baseVersion] }
    obj["payload"] = submissionToJSON(env.payload)
    return obj
}

private func envelopeFromJSON(_ obj: [String: Any]) -> OperationEnvelope<HubFieldTicketSubmission>? {
    guard let opId = obj["opId"] as? String, let kindRaw = obj["kind"] as? String,
        let kind = OperationKind(rawValue: kindRaw), let type = obj["type"] as? String,
        let idempotencyKey = obj["idempotencyKey"] as? String,
        let localSeq = (obj["localSeq"] as? NSNumber)?.intValue,
        let payloadObj = obj["payload"] as? [String: Any], let payload = submissionFromJSON(payloadObj)
    else { return nil }
    let dependsOn = (obj["dependsOn"] as? [Any])?.compactMap { $0 as? String } ?? []
    let precondition: VersionPrecondition? = (obj["precondition"] as? [String: Any]).flatMap {
        ($0["baseVersion"] as? NSNumber).map { VersionPrecondition(baseVersion: $0.intValue) }
    }
    return OperationEnvelope(
        opId: opId, kind: kind, type: type, idempotencyKey: idempotencyKey, localSeq: localSeq,
        dependsOn: dependsOn, precondition: precondition, payload: payload)
}

// ---- durable outbox projection (index.ts extra exports) ----

public enum DurableOutboxStatus: String, Equatable, Sendable {
    case pending
    case inFlight = "in-flight"
    case retry
    case blocked
    case failed
    case accepted
    case needsReview = "needs-review"
}

public struct DurableOutboxItem: Equatable, Sendable {
    public var id: String
    public var type: String
    public var payload: HubFieldTicketSubmission
    public var idempotencyKey: String
    public var status: DurableOutboxStatus
    public var attempts: Int
    public var createdAt: String
    public var updatedAt: String
    public var lastError: String?
    public var lastHttpStatus: Int?
    public var lastRejectionCode: String?

    public init(
        id: String, type: String, payload: HubFieldTicketSubmission, idempotencyKey: String,
        status: DurableOutboxStatus, attempts: Int, createdAt: String, updatedAt: String,
        lastError: String? = nil, lastHttpStatus: Int? = nil, lastRejectionCode: String? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.attempts = attempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.lastHttpStatus = lastHttpStatus
        self.lastRejectionCode = lastRejectionCode
    }
}

private func outboxStatus(from evidence: TicketEvidence) -> DurableOutboxStatus {
    switch evidence.state {
    case .pending:
        if evidence.lastRejectionCode != nil { return .blocked }
        if evidence.attempts > 0 || evidence.lastTransientReason != nil
            || evidence.nextAttemptAtMs != nil
        {
            return .retry
        }
        return .pending
    case .inFlight: return .inFlight
    case .accepted: return .accepted
    case .needsReview: return .needsReview
    case .rejected: return .failed
    }
}

private let COLUMNS =
    "id, type, payload_json, idempotency_key, outbox_status, envelope_json, state, "
    + "attempts, created_at, updated_at, "
    + "last_rejection_code, last_detail, last_http_status, last_outcome_at, "
    + "last_transient_reason, next_attempt_at_ms"

private func toRowParams(_ evidence: TicketEvidence) throws -> [SqlValue] {
    [
        .text(evidence.envelope.idempotencyKey),
        .text(evidence.envelope.type),
        .text(try jsonStringify(submissionToJSON(evidence.envelope.payload))),
        .text(evidence.envelope.idempotencyKey),
        .text(outboxStatus(from: evidence).rawValue),
        .text(try jsonStringify(envelopeToJSON(evidence.envelope))),
        .text(evidence.state.rawValue),
        .int(Int64(evidence.attempts)),
        .text(evidence.createdAt),
        .text(evidence.updatedAt),
        evidence.lastRejectionCode.map(SqlValue.text) ?? .null,
        evidence.lastDetail.map(SqlValue.text) ?? .null,
        evidence.lastHttpStatus.map { .int(Int64($0)) } ?? .null,
        evidence.lastOutcomeAt.map(SqlValue.text) ?? .null,
        evidence.lastTransientReason.map(SqlValue.text) ?? .null,
        evidence.nextAttemptAtMs.map(SqlValue.int) ?? .null,
    ]
}

/**
 * Parse one row, or nil when its envelope JSON is corrupted (out-of-band file damage). A corrupt
 * row must never take the whole store down — boot recovery and the retry engine keep working on
 * the healthy rows; corrupt keys stay visible via `listCorruptKeys()`.
 */
private func fromRowSafe(_ row: SqlRow) -> TicketEvidence? {
    guard let text = row.string("envelope_json"), let obj = (try? jsonParse(text)) as? [String: Any],
        let envelope = envelopeFromJSON(obj),
        let state = OutboxItemState(rawValue: row.string("state") ?? "")
    else { return nil }
    return TicketEvidence(
        envelope: envelope, state: state, attempts: Int(row.int("attempts") ?? 0),
        createdAt: row.string("created_at") ?? "", updatedAt: row.string("updated_at") ?? "",
        lastRejectionCode: row.string("last_rejection_code"), lastDetail: row.string("last_detail"),
        lastHttpStatus: row.int("last_http_status").map(Int.init),
        lastOutcomeAt: row.string("last_outcome_at"),
        lastTransientReason: row.string("last_transient_reason"),
        nextAttemptAtMs: row.int("next_attempt_at_ms"))
}

/**
 * Durable outbox projection required by the Mobile/Hub integration: explicit row identity,
 * operation type, payload, idempotency key, operational status, attempts, last error/status,
 * rejection code, and timestamps. This is a read projection over the evidence table so the
 * domain can keep using the tested contracts state machine internally.
 */
private func outboxItemFromRow(_ row: SqlRow) -> DurableOutboxItem? {
    guard let evidence = fromRowSafe(row) else { return nil }
    let id = row.string("id").flatMap { $0.isEmpty ? nil : $0 } ?? evidence.envelope.idempotencyKey
    let type = row.string("type").flatMap { $0.isEmpty ? nil : $0 } ?? evidence.envelope.type
    return DurableOutboxItem(
        id: id, type: type, payload: evidence.envelope.payload,
        idempotencyKey: evidence.envelope.idempotencyKey, status: outboxStatus(from: evidence),
        attempts: evidence.attempts, createdAt: evidence.createdAt, updatedAt: evidence.updatedAt,
        lastError: evidence.lastDetail ?? evidence.lastTransientReason,
        lastHttpStatus: evidence.lastHttpStatus, lastRejectionCode: evidence.lastRejectionCode)
}

public final class SqliteTicketEvidenceStore: TicketEvidenceStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func save(_ evidence: TicketEvidence) {
        try! db.run(
            "INSERT OR REPLACE INTO ticket_evidence (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            try toRowParams(evidence))
    }

    public func get(_ idempotencyKey: String) -> TicketEvidence? {
        (try! db.first(
            "SELECT \(COLUMNS) FROM ticket_evidence WHERE idempotency_key = ?", [.text(idempotencyKey)])).flatMap(
                fromRowSafe)
    }

    public func list() -> [TicketEvidence] {
        (try! db.all("SELECT \(COLUMNS) FROM ticket_evidence ORDER BY created_at, idempotency_key"))
            .compactMap(fromRowSafe)
    }

    public func listOutboxItems() -> [DurableOutboxItem] {
        (try! db.all("SELECT \(COLUMNS) FROM ticket_evidence ORDER BY created_at, idempotency_key"))
            .compactMap(outboxItemFromRow)
    }

    /// Rows in a given state — the retry engine's sweep query.
    public func listByState(_ state: OutboxItemState) -> [TicketEvidence] {
        (try! db.all(
            "SELECT \(COLUMNS) FROM ticket_evidence WHERE state = ? ORDER BY created_at, idempotency_key",
            [.text(state.rawValue)])).compactMap(fromRowSafe)
    }

    /// Idempotency keys of rows whose stored envelope no longer parses — surfaced, not hidden.
    public func listCorruptKeys() -> [String] {
        (try! db.all("SELECT \(COLUMNS) FROM ticket_evidence"))
            .filter { fromRowSafe($0) == nil }
            .compactMap { $0.string("idempotency_key") }
    }
}
