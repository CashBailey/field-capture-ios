// Port of src/domain/locationEvidence.ts — Durable home for validation-only location evidence
// (Phase 7). Append-only and NON-EVICTABLE: location evidence is unsynced field work — it is
// preserved until the Hub acks it, never auto-deleted (cross-cutting invariant). The single-shot
// native GPS capture and the sync-wire shape are device-/Hub-gated; this store + the contract
// model are the pure, durable foundation.
import FieldContracts

public protocol LocationEvidenceStore {
    var durability: StoreDurability { get }
    /// Append a location-evidence record (append-only; never overwritten away as unsynced work).
    func record(_ evidence: LocationEvidence) throws
    func get(_ id: String) -> LocationEvidence?
    func listByServiceRequest(_ serviceRequestId: String) -> [LocationEvidence]
    func list() -> [LocationEvidence]
}

/// ponytail: the TS interface's `record` is untyped `void` (JS has no checked exceptions) but the
/// volatile implementation below throws on a duplicate id — the Swift protocol requirement is
/// marked `throws` so that runtime behavior is expressible at all.
public struct LocationEvidenceStoreError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// In-memory test seam — explicitly volatile.
public final class VolatileLocationEvidenceStore: LocationEvidenceStore {
    public let durability: StoreDurability = .volatileMemory
    private var rows: [String: LocationEvidence] = [:]

    public init() {}

    public func record(_ evidence: LocationEvidence) throws {
        guard rows[evidence.id] == nil else {
            throw LocationEvidenceStoreError("location evidence \(evidence.id) already exists")
        }
        rows[evidence.id] = evidence
    }

    public func get(_ id: String) -> LocationEvidence? {
        rows[id]
    }

    public func listByServiceRequest(_ serviceRequestId: String) -> [LocationEvidence] {
        list().filter { $0.serviceRequestId == serviceRequestId }
    }

    public func list() -> [LocationEvidence] {
        Array(rows.values)
    }
}
