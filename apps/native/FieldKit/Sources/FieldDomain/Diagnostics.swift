// Port of src/domain/diagnostics.ts — Diagnostic logs + a copy-pasteable diagnostic report (spec
// 7.15 Sync Center / §4f-g). The Sync Center and More screens expose a "copy diagnostic"
// affordance; this is the durable backing store for it plus the pure formatter that assembles a
// report. SECRET-FREE by construction: the report never includes bearer tokens, passwords, or
// full payloads — only counts, states, and timestamps an office can act on.
import Foundation
import FieldContracts

public enum DiagnosticLevel: String, Equatable, Sendable, Codable {
    case info
    case warning
    case error
}

public struct DiagnosticLog: Equatable, Sendable {
    public var id: String
    public var level: DiagnosticLevel
    /// Short human-facing message. Callers must NOT put secrets/tokens here.
    public var message: String
    /// Optional small context (codes, ids, counts) — never tokens or full payloads.
    public var context: [String: JSONValue]?
    public var createdAt: String

    public init(
        id: String, level: DiagnosticLevel, message: String, context: [String: JSONValue]? = nil, createdAt: String
    ) {
        self.id = id
        self.level = level
        self.message = message
        self.context = context
        self.createdAt = createdAt
    }
}

public protocol DiagnosticLogStore {
    var durability: StoreDurability { get }
    /// Append a log entry (append-only; diagnostic logs may be rotated, never field WORK).
    func record(_ entry: DiagnosticLog) throws
    /// The most recent entries, newest first, capped at `limit`.
    func recent(_ limit: Int) throws -> [DiagnosticLog]
    func count() throws -> Int
}

/// In-memory test seam — explicitly volatile.
public final class VolatileDiagnosticLogStore: DiagnosticLogStore {
    public let durability: StoreDurability = .volatileMemory
    private var rows: [DiagnosticLog] = []

    public init() {}

    public func record(_ entry: DiagnosticLog) {
        rows.append(entry)
    }

    public func recent(_ limit: Int) -> [DiagnosticLog] {
        Array(rows.suffix(max(0, limit)).reversed())
    }

    public func count() -> Int {
        rows.count
    }
}

public struct DiagnosticReportInput {
    public var appEnv: String
    public var hubUrl: String?
    public var storageDurability: StoreDurability
    /// Last successful Hub contact (epoch ms) or nil.
    public var lastHubContactAtMs: Int64?
    /// Offline-policy state label (online / offline-within-limit / offline-over-limit).
    public var offlinePolicyState: String
    /// Outbox rollup counts (Sync Center categories → counts).
    public var counts: [String: Int]
    public var recentLogs: [DiagnosticLog]
    /// Stamp for the report header (epoch ms). Injected, never read from a global clock.
    public var generatedAtMs: Int64

    public init(
        appEnv: String,
        hubUrl: String?,
        storageDurability: StoreDurability,
        lastHubContactAtMs: Int64?,
        offlinePolicyState: String,
        counts: [String: Int],
        recentLogs: [DiagnosticLog],
        generatedAtMs: Int64
    ) {
        self.appEnv = appEnv
        self.hubUrl = hubUrl
        self.storageDurability = storageDurability
        self.lastHubContactAtMs = lastHubContactAtMs
        self.offlinePolicyState = offlinePolicyState
        self.counts = counts
        self.recentLogs = recentLogs
        self.generatedAtMs = generatedAtMs
    }
}

private func isoStamp(_ epochMs: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
}

/**
 * Assemble a copy-pasteable, SECRET-FREE diagnostic report. Defensive redaction: any context key
 * that looks like a credential is dropped, so a careless caller can never leak a token here.
 */
public func buildDiagnosticReport(_ input: DiagnosticReportInput) -> String {
    var lines: [String] = []
    lines.append("Field Capture diagnostic")
    lines.append("generated: \(isoStamp(input.generatedAtMs))")
    lines.append("hub env: \(input.appEnv)")
    lines.append("hub url: \(input.hubUrl.map(redactSensitiveText) ?? "not configured")")
    lines.append("local storage: \(input.storageDurability.rawValue)")
    lines.append(
        "last hub contact: \(input.lastHubContactAtMs.map(isoStamp) ?? "never")"
    )
    lines.append("offline policy: \(input.offlinePolicyState)")
    lines.append("queues:")
    for (key, value) in input.counts {
        lines.append("  \(key): \(value)")
    }
    if !input.recentLogs.isEmpty {
        lines.append("recent:")
        for log in input.recentLogs {
            let ctx = log.context.map { " \(jsonString(.object(redactSecrets($0))))" } ?? ""
            lines.append("  [\(log.level.rawValue)] \(log.createdAt) \(redactSensitiveText(log.message))\(ctx)")
        }
    }
    return lines.joined(separator: "\n")
}

private let SECRET_KEY_TERMS = ["token", "secret", "password", "authorization", "bearer", "key"]

private func isSecretKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    return SECRET_KEY_TERMS.contains { lower.contains($0) }
}

private func redactSecrets(_ context: [String: JSONValue]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (key, value) in context {
        out[key] = isSecretKey(key) ? .string("[redacted]") : redactSecrets(value)
    }
    return out
}

private func redactSecrets(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let text): return .string(redactSensitiveText(text))
    case .array(let values): return .array(values.map(redactSecrets))
    case .object(let values): return .object(redactSecrets(values))
    case .number, .bool, .null: return value
    }
}

private func redactSensitiveText(_ text: String) -> String {
    let bearerPattern = #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#
    let withoutBearer = text.replacingOccurrences(
        of: bearerPattern,
        with: "Bearer [redacted]",
        options: .regularExpression
    )
    let urlQueryPattern = #"(?i)(https?://[^\s?#]+)\?[^\s#]*"#
    return withoutBearer.replacingOccurrences(
        of: urlQueryPattern,
        with: "$1?[redacted]",
        options: .regularExpression
    )
}

private func jsonString(_ value: JSONValue) -> String {
    switch value {
    case .string(let s):
        return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    case .number(let n):
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    case .bool(let b):
        return b ? "true" : "false"
    case .null:
        return "null"
    case .array(let items):
        return "[" + items.map(jsonString).joined(separator: ",") + "]"
    case .object(let fields):
        let keys = fields.keys.sorted()
        return "{" + keys.map { "\"\($0)\":\(jsonString(fields[$0]!))" }.joined(separator: ",") + "}"
    }
}
