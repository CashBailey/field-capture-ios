// Port of src/domain/syncChanges.ts — Down-sync applied-changes ledger (ADR-004 / plan §4g,
// Section 4e item 4). The sync engine's pull-once step applies a page of changes and THEN
// persists the advanced frontier — so the apply MUST be idempotent and must never silently drop a
// change (a no-op apply would advance the frontier past authoritative changes, losing them
// forever). This ledger durably records each change keyed by its server-issued
// `(authorityEpoch, commitSeq)`; re-applying the same page is a no-op (idempotent), and a crash
// between apply and frontier-persist re-delivers the page harmlessly.
//
// This is the RECORD step. Per-entity application (patching a cached assignment, confirming an
// accepted form, …) reads from this ledger and is layered on as those consumers land — recording
// first guarantees the change is never lost in the meantime.
import Foundation
import FieldContracts

/// One down-synced change row (opshub `GET /sync/changes`), normalized.
public struct SyncChangeRow: Equatable, Sendable {
    public var authorityEpoch: Int
    public var commitSeq: Int
    public var opId: String
    public var entityType: String
    public var entityId: String
    public var changeType: String
    /// ponytail: mirrors the TS `unknown` payload as the Equatable `JSONValue` tree FieldContracts
    /// already uses for opaque, structurally-compared JSON (see `FieldTicket.fields`) — this row
    /// IS compared whole via `==` in the ported tests, unlike `HubAssignment.snapshot`.
    public var payload: JSONValue
    public var createdAt: String

    public init(
        authorityEpoch: Int,
        commitSeq: Int,
        opId: String,
        entityType: String,
        entityId: String,
        changeType: String,
        payload: JSONValue,
        createdAt: String
    ) {
        self.authorityEpoch = authorityEpoch
        self.commitSeq = commitSeq
        self.opId = opId
        self.entityType = entityType
        self.entityId = entityId
        self.changeType = changeType
        self.payload = payload
        self.createdAt = createdAt
    }
}

public protocol SyncChangeLedger {
    var durability: StoreDurability { get }
    /// Record a change. Returns true if newly inserted, false if it was already applied (idempotent).
    func record(_ change: SyncChangeRow) throws -> Bool
    func has(_ authorityEpoch: Int, _ commitSeq: Int) -> Bool
    func count() -> Int
    func list() -> [SyncChangeRow]
}

private func str(_ value: Any?) -> String {
    (value as? String) ?? ""
}

/// Integer coercion from an untyped JSON value (mirrors TS `Number.isInteger`): excludes booleans
/// and non-integral numbers.
private func intValue(_ value: Any?) -> Int? {
    guard let value, !(value is Bool) else { return nil }
    switch value {
    case let i as Int: return i
    case let d as Double: return d.isFinite && d.truncatingRemainder(dividingBy: 1) == 0 ? Int(d) : nil
    case let n as NSNumber:
        let d = n.doubleValue
        return d.isFinite && d.truncatingRemainder(dividingBy: 1) == 0 ? Int(d) : nil
    default: return nil
    }
}

private extension JSONValue {
    /// Best-effort conversion of an untyped JSON value (as produced by `JSONSerialization` or a
    /// Swift dictionary literal in a test) into the Equatable `JSONValue` tree.
    static func from(_ any: Any?) -> JSONValue {
        guard let any, !(any is NSNull) else { return .null }
        switch any {
        case let v as JSONValue: return v
        case let v as Bool: return .bool(v)
        case let v as String: return .string(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as NSNumber: return .number(v.doubleValue)
        case let v as [Any]: return .array(v.map { JSONValue.from($0) })
        case let v as [String: Any]: return .object(v.mapValues { JSONValue.from($0) })
        default: return .null
        }
    }
}

/**
 * Tolerantly normalize one raw change from the Hub. Returns nil ONLY when the server-issued key
 * fields (`authority_epoch`, `commit_seq`, `change_type`) are missing/malformed — that change
 * cannot be keyed or deduped, so the caller counts it as skipped rather than guessing a key.
 */
public func parseSyncChange(_ value: Any) -> SyncChangeRow? {
    guard let rec = value as? [String: Any] else { return nil }
    guard
        let authorityEpoch = intValue(rec["authority_epoch"] ?? rec["authorityEpoch"]),
        let commitSeq = intValue(rec["commit_seq"] ?? rec["commitSeq"]),
        let changeType = (rec["change_type"] ?? rec["changeType"]) as? String,
        !changeType.isEmpty
    else {
        return nil
    }
    return SyncChangeRow(
        authorityEpoch: authorityEpoch,
        commitSeq: commitSeq,
        opId: str(rec["op_id"] ?? rec["opId"]),
        entityType: str(rec["entity_type"] ?? rec["entityType"]),
        entityId: str(rec["entity_id"] ?? rec["entityId"]),
        changeType: changeType,
        payload: JSONValue.from(rec["payload"]),
        createdAt: str(rec["created_at"] ?? rec["createdAt"])
    )
}

public struct RecordChangesResult: Equatable, Sendable {
    /// Newly recorded (not previously applied).
    public var recorded: Int
    /// Already-applied duplicates (idempotent re-delivery).
    public var duplicates: Int
    /// Unkeyable/malformed changes — a Hub contract violation; surfaced, never silently dropped.
    public var skipped: Int

    public init(recorded: Int, duplicates: Int, skipped: Int) {
        self.recorded = recorded
        self.duplicates = duplicates
        self.skipped = skipped
    }
}

/**
 * Idempotently record a page of raw changes into the ledger. Safe to wire directly as the sync
 * engine's `applyChanges` callback (its return is unused there; this returns counts for
 * callers/tests).
 */
public func recordChanges(_ ledger: SyncChangeLedger, _ changes: [Any]) throws -> RecordChangesResult {
    var recorded = 0
    var duplicates = 0
    var skipped = 0
    for raw in changes {
        guard let change = parseSyncChange(raw) else {
            skipped += 1
            continue
        }
        if try ledger.record(change) { recorded += 1 } else { duplicates += 1 }
    }
    return RecordChangesResult(recorded: recorded, duplicates: duplicates, skipped: skipped)
}

/// In-memory test seam — explicitly volatile.
public final class VolatileSyncChangeLedger: SyncChangeLedger {
    public let durability: StoreDurability = .volatileMemory
    private var rows: [String: SyncChangeRow] = [:]

    public init() {}

    private func key(_ epoch: Int, _ seq: Int) -> String { "\(epoch):\(seq)" }

    public func record(_ change: SyncChangeRow) -> Bool {
        let k = key(change.authorityEpoch, change.commitSeq)
        guard rows[k] == nil else { return false }
        rows[k] = change
        return true
    }

    public func has(_ authorityEpoch: Int, _ commitSeq: Int) -> Bool {
        rows[key(authorityEpoch, commitSeq)] != nil
    }

    public func count() -> Int {
        rows.count
    }

    public func list() -> [SyncChangeRow] {
        rows.values.sorted {
            $0.authorityEpoch != $1.authorityEpoch ? $0.authorityEpoch < $1.authorityEpoch : $0.commitSeq < $1.commitSeq
        }
    }
}
