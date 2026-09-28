// Port of src/data/SqliteFieldFormStore.ts — Durable `FieldFormStore` over SQLite (migration v5).
// DVIR/JHA-JSA drafts survive restart; enqueued/answered forms keep their full payload, outbox
// opId, and Hub's verbatim reason — safety evidence is never trimmed to a status flag.
import Foundation
import FieldContracts
import FieldDomain

// ---- FieldForm (DvirForm | JhaForm) <-> JSON object ----

private func inspectionItemToJSON(_ item: InspectionItem) -> [String: Any] {
    var obj: [String: Any] = ["itemId": item.itemId, "label": item.label]
    if let result = item.result { obj["result"] = result.rawValue }
    if let note = item.note { obj["note"] = note }
    return obj
}

private func inspectionItemFromJSON(_ obj: [String: Any]) -> InspectionItem? {
    guard let itemId = obj["itemId"] as? String, let label = obj["label"] as? String else { return nil }

    let result: InspectionResult?
    if let rawResult = obj["result"] {
        guard let rawResult = rawResult as? String, let decoded = InspectionResult(rawValue: rawResult) else {
            return nil
        }
        result = decoded
    } else {
        result = nil
    }

    return InspectionItem(
        itemId: itemId, label: label,
        result: result,
        note: obj["note"] as? String)
}

private func decodeArray<Element>(_ value: Any, using decode: (Any) -> Element?) -> [Element]? {
    guard let values = value as? [Any] else { return nil }

    var decoded: [Element] = []
    decoded.reserveCapacity(values.count)
    for value in values {
        guard let element = decode(value) else { return nil }
        decoded.append(element)
    }
    return decoded
}

private func decodeObjectArray<Element>(
    _ value: Any,
    using decode: ([String: Any]) -> Element?
) -> [Element]? {
    decodeArray(value) { value in
        guard let object = value as? [String: Any] else { return nil }
        return decode(object)
    }
}

private func signatureToJSON(_ s: SignatureRecord) -> [String: Any] {
    var obj: [String: Any] = [
        "blobId": s.blobId, "signerName": s.signerName, "signedAtUtc": s.signedAtUtc,
        "certificationText": s.certificationText,
        "consentToElectronicSignature": s.consentToElectronicSignature,
        "deviceInstanceId": s.deviceInstanceId, "appVersion": s.appVersion,
    ]
    if let v = s.signerUserId { obj["signerUserId"] = v }
    if let v = s.signerRole { obj["signerRole"] = v }
    return obj
}

private func signatureFromJSON(_ obj: [String: Any]) -> SignatureRecord? {
    guard let blobId = obj["blobId"] as? String, let signerName = obj["signerName"] as? String,
        let signedAtUtc = obj["signedAtUtc"] as? String,
        let certificationText = obj["certificationText"] as? String,
        let deviceInstanceId = obj["deviceInstanceId"] as? String,
        let appVersion = obj["appVersion"] as? String
    else { return nil }
    return SignatureRecord(
        blobId: blobId, signerName: signerName, signerUserId: obj["signerUserId"] as? String,
        signerRole: obj["signerRole"] as? String, signedAtUtc: signedAtUtc,
        certificationText: certificationText, deviceInstanceId: deviceInstanceId, appVersion: appVersion)
}

private func hazardToJSON(_ h: JhaHazard) -> [String: Any] {
    ["hazardId": h.hazardId, "description": h.description, "mitigation": h.mitigation]
}

private func hazardFromJSON(_ obj: [String: Any]) -> JhaHazard? {
    guard let hazardId = obj["hazardId"] as? String, let description = obj["description"] as? String,
        let mitigation = obj["mitigation"] as? String
    else { return nil }
    return JhaHazard(hazardId: hazardId, description: description, mitigation: mitigation)
}

private func dvirToJSON(_ d: DvirForm) -> [String: Any] {
    var obj: [String: Any] = [
        "formId": d.formId, "kind": d.kind.rawValue, "vehicleRef": d.vehicleRef,
        "items": d.items.map(inspectionItemToJSON), "signatureBlobIds": d.signatureBlobIds,
    ]
    if let v = d.odometer { obj["odometer"] = v }
    if let v = d.defectsCertifiedSafe { obj["defectsCertifiedSafe"] = v }
    if let v = d.signatures { obj["signatures"] = v.map(signatureToJSON) }
    if let v = d.completedAt { obj["completedAt"] = v }
    return obj
}

private func dvirFromJSON(_ obj: [String: Any]) -> DvirForm? {
    guard let formId = obj["formId"] as? String, let kindRaw = obj["kind"] as? String,
        let kind = DvirKind(rawValue: kindRaw), let vehicleRef = obj["vehicleRef"] as? String,
        let rawItems = obj["items"], let items = decodeObjectArray(rawItems, using: inspectionItemFromJSON),
        let rawSignatureBlobIds = obj["signatureBlobIds"],
        let signatureBlobIds = decodeArray(rawSignatureBlobIds, using: { $0 as? String })
    else { return nil }

    let signatures: [SignatureRecord]?
    if let rawSignatures = obj["signatures"] {
        guard let decoded = decodeObjectArray(rawSignatures, using: signatureFromJSON) else { return nil }
        signatures = decoded
    } else {
        signatures = nil
    }

    return DvirForm(
        formId: formId, kind: kind, vehicleRef: vehicleRef,
        odometer: (obj["odometer"] as? NSNumber)?.doubleValue, items: items,
        defectsCertifiedSafe: (obj["defectsCertifiedSafe"] as? NSNumber)?.boolValue,
        signatureBlobIds: signatureBlobIds, signatures: signatures,
        completedAt: obj["completedAt"] as? String)
}

private func jhaToJSON(_ j: JhaForm) -> [String: Any] {
    var obj: [String: Any] = [
        "formId": j.formId, "kind": "jha-jsa", "serviceRequestId": j.serviceRequestId,
        "hazards": j.hazards.map(hazardToJSON), "signatureBlobIds": j.signatureBlobIds,
    ]
    if let v = j.signatures { obj["signatures"] = v.map(signatureToJSON) }
    if let v = j.completedAt { obj["completedAt"] = v }
    return obj
}

private func jhaFromJSON(_ obj: [String: Any]) -> JhaForm? {
    guard let formId = obj["formId"] as? String, let serviceRequestId = obj["serviceRequestId"] as? String,
        let rawHazards = obj["hazards"], let hazards = decodeObjectArray(rawHazards, using: hazardFromJSON),
        let rawSignatureBlobIds = obj["signatureBlobIds"],
        let signatureBlobIds = decodeArray(rawSignatureBlobIds, using: { $0 as? String })
    else { return nil }

    let signatures: [SignatureRecord]?
    if let rawSignatures = obj["signatures"] {
        guard let decoded = decodeObjectArray(rawSignatures, using: signatureFromJSON) else { return nil }
        signatures = decoded
    } else {
        signatures = nil
    }

    return JhaForm(
        formId: formId, serviceRequestId: serviceRequestId, hazards: hazards,
        signatureBlobIds: signatureBlobIds, signatures: signatures, completedAt: obj["completedAt"] as? String)
}

/// Public: the composition root reuses this exact wire shape when enqueueing form evidence
/// (the JSON here IS the TS object shape, `kind` discriminant included).
public func fieldFormToJSON(_ form: FieldForm) -> [String: Any] {
    switch form {
    case .dvir(let d): return dvirToJSON(d)
    case .jha(let j): return jhaToJSON(j)
    }
}

private func fieldFormFromJSON(_ obj: [String: Any]) -> FieldForm? {
    guard let kindRaw = obj["kind"] as? String, let kind = FieldFormKind(rawValue: kindRaw) else {
        return nil
    }

    switch kind {
    case .jhaJsa:
        return jhaFromJSON(obj).map(FieldForm.jha)
    case .preTripDvir, .postTripDvir:
        guard let dvir = dvirFromJSON(obj), dvir.kind.rawValue == kind.rawValue else { return nil }
        return .dvir(dvir)
    }
}

private func formId(_ form: FieldForm) -> String {
    switch form {
    case .dvir(let d): return d.formId
    case .jha(let j): return j.formId
    }
}

/// The row's own `kind` column (not the JSON's) — mirrors TS `form.kind`.
private func kindColumn(_ form: FieldForm) -> String {
    switch form {
    case .dvir(let d): return d.kind.rawValue
    case .jha: return "jha-jsa"
    }
}

private let COLUMNS =
    "form_id, kind, service_request_id, vehicle_ref, payload_json, status, op_id, last_error, created_at, updated_at"

public enum SqliteFieldFormStoreError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case corruptRecord(formId: String, detail: String)
    case encodingFailed(formId: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let formId, let detail):
            return "field form \(formId) is corrupt: \(detail)"
        case .encodingFailed(let formId, let detail):
            return "field form \(formId) could not be encoded: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

private func encodedPayload(_ form: FieldForm) throws -> String {
    do {
        let data = try JSONSerialization.data(
            withJSONObject: fieldFormToJSON(form), options: [.fragmentsAllowed])
        guard let payload = String(data: data, encoding: .utf8) else {
            throw SqliteFieldFormStoreError.encodingFailed(
                formId: formId(form), detail: "JSON encoder returned non-UTF-8 data")
        }
        return payload
    } catch let error as SqliteFieldFormStoreError {
        throw error
    } catch {
        throw SqliteFieldFormStoreError.encodingFailed(
            formId: formId(form), detail: String(describing: error))
    }
}

private func toRowParams(_ r: FieldFormRecord) throws -> [SqlValue] {
    let form = r.form
    let serviceRequestId: String? = {
        if case .jha(let j) = form { return j.serviceRequestId }
        return nil
    }()
    let vehicleRef: String? = {
        if case .dvir(let d) = form { return d.vehicleRef }
        return nil
    }()
    return [
        .text(formId(form)),
        .text(kindColumn(form)),
        serviceRequestId.map(SqlValue.text) ?? .null,
        vehicleRef.map(SqlValue.text) ?? .null,
        .text(try encodedPayload(form)),
        .text(r.status.rawValue),
        r.opId.map(SqlValue.text) ?? .null,
        r.lastError.map(SqlValue.text) ?? .null,
        .text(r.createdAt),
        .text(r.updatedAt),
    ]
}

private func fromRow(_ row: SqlRow) throws -> FieldFormRecord {
    let storedFormId = row.string("form_id") ?? "<unknown>"
    guard let rowKindRaw = row.string("kind"), FieldFormKind(rawValue: rowKindRaw) != nil else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "unknown or missing kind")
    }
    guard let payloadText = row.string("payload_json") else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "missing payload_json")
    }

    let parsed: Any
    do {
        parsed = try jsonParse(payloadText)
    } catch {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "payload_json is malformed: \(error)")
    }
    guard let object = parsed as? [String: Any], let form = fieldFormFromJSON(object) else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "payload does not match the field-form contract")
    }
    guard formId(form) == storedFormId else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "payload formId does not match its row key")
    }
    guard kindColumn(form) == rowKindRaw else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "payload kind does not match its row kind")
    }
    guard let statusRaw = row.string("status"), let status = FieldFormStatus(rawValue: statusRaw) else {
        throw SqliteFieldFormStoreError.corruptRecord(
            formId: storedFormId, detail: "unknown or missing status")
    }
    return FieldFormRecord(
        form: form,
        status: status,
        opId: row.string("op_id"),
        lastError: row.string("last_error"),
        createdAt: row.string("created_at") ?? "",
        updatedAt: row.string("updated_at") ?? ""
    )
}

public final class SqliteFieldFormStore: FieldFormStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func transaction(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }

    public func save(_ record: FieldFormRecord) throws {
        try db.run(
            "INSERT OR REPLACE INTO field_forms (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            try toRowParams(record))
    }

    public func get(_ formId: String) throws -> FieldFormRecord? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM field_forms WHERE form_id = ?", [.text(formId)])
        else { return nil }
        return try fromRow(row)
    }

    public func list() throws -> [FieldFormRecord] {
        try db.all("SELECT \(COLUMNS) FROM field_forms ORDER BY created_at, form_id").map(fromRow)
    }

    public func listByStatus(_ status: FieldFormStatus) throws -> [FieldFormRecord] {
        try db.all(
            "SELECT \(COLUMNS) FROM field_forms WHERE status = ? ORDER BY created_at, form_id",
            [.text(status.rawValue)]
        ).map(fromRow)
    }
}
