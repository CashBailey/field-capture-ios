// Port of src/data/SqliteDiagnosticLogStore.ts — Durable diagnostic-log store over SQLite
// (§4f-g) — append-only entries backing the Sync Center / More copy-diagnostic export.
// `recent(n)` returns the newest entries first.
import Foundation
import FieldContracts
import FieldDomain

// ---- shared JSON helpers (FieldData-internal; several stores serialize a `JSONValue` tree into
// a TEXT column the same way `JSON.stringify`/`JSON.parse` do on the TS side) ----

/// Convert a `JSONValue` tree to a Foundation JSON-native value, ready for `JSONSerialization`.
func jsonValueToAny(_ value: JSONValue) -> Any {
    switch value {
    case .string(let s): return s
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let items): return items.map(jsonValueToAny)
    case .object(let fields): return fields.mapValues(jsonValueToAny)
    }
}

/// Convert a Foundation JSON-native value (as produced by `JSONSerialization`) into the
/// Equatable `JSONValue` tree. Checks `NSNumber`'s CFBoolean type id first — a blind `as? Bool`
/// cast on `Any` is unreliable for JSON-decoded numbers.
func jsonValueFromAny(_ any: Any) -> JSONValue {
    if any is NSNull { return .null }
    if let s = any as? String { return .string(s) }
    if let n = any as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        return .number(n.doubleValue)
    }
    if let arr = any as? [Any] { return .array(arr.map(jsonValueFromAny)) }
    if let obj = any as? [String: Any] { return .object(obj.mapValues(jsonValueFromAny)) }
    return .null
}

/// Serialize a Foundation JSON-native value to a JSON string, mirroring `JSON.stringify`.
/// Encoding failures are explicit so persistence callers can preserve the original work and
/// surface the storage error instead of terminating the process.
private enum JSONStringifyError: Error, LocalizedError {
    case invalidNumber(path: String)
    case unsupportedValue(path: String, type: String)

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let path):
            return "JSON number at \(path) must be finite"
        case .unsupportedValue(let path, let type):
            return "unsupported JSON value at \(path): \(type)"
        }
    }
}

/// `JSONSerialization` raises an Objective-C exception for non-finite numbers. Validate the
/// closed JSON-native tree first so bad input follows the normal Swift error path.
private func validateJSONNativeValue(_ value: Any, path: String = "$") throws {
    switch value {
    case is NSNull, is String:
        return
    case let number as NSNumber:
        guard CFGetTypeID(number) == CFBooleanGetTypeID() || number.doubleValue.isFinite else {
            throw JSONStringifyError.invalidNumber(path: path)
        }
    case let array as [Any]:
        for (index, item) in array.enumerated() {
            try validateJSONNativeValue(item, path: "\(path)[\(index)]")
        }
    case let object as [String: Any]:
        for (key, item) in object {
            try validateJSONNativeValue(item, path: "\(path).\(key)")
        }
    default:
        throw JSONStringifyError.unsupportedValue(
            path: path, type: String(reflecting: type(of: value)))
    }
}

func jsonStringify(_ value: Any) throws -> String {
    try validateJSONNativeValue(value)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    guard let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    return text
}

/// Parse a JSON string into a Foundation JSON-native value, mirroring `JSON.parse`. Throws on
/// malformed JSON so callers that must tolerate out-of-band corruption (e.g. envelope rows) can
/// quarantine the row instead of crashing.
func jsonParse(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

public enum SqliteDiagnosticLogStoreError: Error, Equatable, Sendable, CustomStringConvertible,
    LocalizedError
{
    case corruptRecord(id: String, detail: String)
    case encodingFailed(id: String, detail: String)
    case invalidCountResult

    public var description: String {
        switch self {
        case .corruptRecord(let id, let detail):
            return "diagnostic log \(id) is corrupt: \(detail)"
        case .encodingFailed(let id, let detail):
            return "diagnostic log \(id) could not be encoded: \(detail)"
        case .invalidCountResult:
            return "diagnostic log count query returned an invalid result"
        }
    }

    public var errorDescription: String? { description }
}

private func fromRow(_ row: SqlRow) throws -> DiagnosticLog {
    let rowId = row.string("id") ?? "<unknown>"
    guard rowId != "<unknown>", !rowId.isEmpty else {
        throw SqliteDiagnosticLogStoreError.corruptRecord(
            id: rowId, detail: "missing or empty id")
    }
    guard let levelRaw = row.string("level"), let level = DiagnosticLevel(rawValue: levelRaw)
    else {
        throw SqliteDiagnosticLogStoreError.corruptRecord(
            id: rowId, detail: "unknown or missing level")
    }
    guard let message = row.string("message") else {
        throw SqliteDiagnosticLogStoreError.corruptRecord(
            id: rowId, detail: "missing message")
    }
    guard let createdAt = row.string("created_at"), !createdAt.isEmpty else {
        throw SqliteDiagnosticLogStoreError.corruptRecord(
            id: rowId, detail: "missing or empty created_at")
    }

    let context: [String: JSONValue]?
    if let text = row.string("context_json") {
        let parsed: Any
        do {
            parsed = try jsonParse(text)
        } catch {
            throw SqliteDiagnosticLogStoreError.corruptRecord(
                id: rowId, detail: "context_json is malformed")
        }
        guard let object = parsed as? [String: Any] else {
            throw SqliteDiagnosticLogStoreError.corruptRecord(
                id: rowId, detail: "context_json is not an object")
        }
        context = object.mapValues(jsonValueFromAny)
    } else {
        context = nil
    }
    return DiagnosticLog(
        id: rowId,
        level: level,
        message: message,
        context: context,
        createdAt: createdAt
    )
}

public final class SqliteDiagnosticLogStore: DiagnosticLogStore {
    /// Diagnostic data is useful for support but must not grow without bound.
    public static let defaultRetentionLimit = 500

    private let db: SqlDriver
    private let retentionLimit: Int
    public let durability: StoreDurability

    public init(
        _ db: SqlDriver,
        _ durability: StoreDurability,
        retentionLimit: Int = SqliteDiagnosticLogStore.defaultRetentionLimit
    ) {
        precondition(retentionLimit > 0, "diagnostic retention limit must be positive")
        self.db = db
        self.durability = durability
        self.retentionLimit = retentionLimit
    }

    public func record(_ entry: DiagnosticLog) throws {
        let contextJson: String?
        do {
            contextJson = try entry.context.map { try jsonStringify($0.mapValues(jsonValueToAny)) }
        } catch {
            throw SqliteDiagnosticLogStoreError.encodingFailed(
                id: entry.id, detail: String(describing: error))
        }

        try db.transaction {
            try db.run(
                """
                INSERT OR REPLACE INTO diagnostic_logs (id, level, message, context_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(entry.id),
                    .text(entry.level.rawValue),
                    .text(entry.message),
                    contextJson.map(SqlValue.text) ?? .null,
                    .text(entry.createdAt),
                ])
            try db.run(
                """
                DELETE FROM diagnostic_logs
                WHERE id IN (
                  SELECT id FROM diagnostic_logs
                  ORDER BY created_at DESC, id DESC
                  LIMIT -1 OFFSET ?
                )
                """,
                [.int(Int64(retentionLimit))])
        }
    }

    public func recent(_ limit: Int) throws -> [DiagnosticLog] {
        try db.all(
            "SELECT id, level, message, context_json, created_at FROM diagnostic_logs ORDER BY created_at DESC, id DESC LIMIT ?",
            [.int(Int64(max(0, limit)))]
        ).map(fromRow)
    }

    public func count() throws -> Int {
        guard let count = try db.first("SELECT COUNT(*) AS n FROM diagnostic_logs")?.int("n")
        else { throw SqliteDiagnosticLogStoreError.invalidCountResult }
        return Int(count)
    }
}
