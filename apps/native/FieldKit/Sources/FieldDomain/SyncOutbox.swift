// Port of src/domain/syncOutbox.ts — Domain seams for the full ADR 004 sync engine: the generic
// durable operation outbox (every command/event the phone owes Hub) and the down-sync frontier
// (the server-issued change token the next pull resumes after). Pure protocols + volatile test
// seams — NO SQL, NO network here. Production uses FieldData's durable SQLite outbox/frontier
// stores.
import FieldContracts

/**
 * A durable outbox row: the contracts `OutboxItem` plus the engine's backoff stamp. Timestamps are
 * required here — durable rows must always say when they were created/last changed.
 *
 * ponytail: the TS `sync.OutboxItem<TPayload = unknown>` default is ported as a concrete
 * `OperationEnvelope<JSONValue>` — the opaque-JSON idiom FieldContracts already uses for other
 * untyped wire payloads (see `FieldTicket.fields`) — rather than re-adding the generic parameter
 * nothing in this file (or its tests — there are none) ever instantiates with a concrete type.
 */
public struct DurableSyncOutboxItem: Equatable, Sendable {
    public var envelope: OperationEnvelope<JSONValue>
    public var state: OutboxItemState
    public var retryCount: Int
    /// Set when Hub commits it.
    public var committedToken: ChangeToken?
    /// Machine-readable rejection, e.g. "stale_version", "locked_sr", "assignment_changed".
    public var rejectionCode: String?
    /// Human-readable detail of the most recent failure (Hub `detail` or transport error), verbatim.
    public var lastError: String?
    public var createdAt: String
    public var updatedAt: String
    /// Epoch ms before which the engine must not redispatch (full-jitter backoff).
    public var nextAttemptAtMs: Int64?

    public init(
        envelope: OperationEnvelope<JSONValue>,
        state: OutboxItemState,
        retryCount: Int = 0,
        committedToken: ChangeToken? = nil,
        rejectionCode: String? = nil,
        lastError: String? = nil,
        createdAt: String,
        updatedAt: String,
        nextAttemptAtMs: Int64? = nil
    ) {
        self.envelope = envelope
        self.state = state
        self.retryCount = retryCount
        self.committedToken = committedToken
        self.rejectionCode = rejectionCode
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nextAttemptAtMs = nextAttemptAtMs
    }
}

public protocol SyncOutboxStore {
    var durability: StoreDurability { get }
    /// Persist one row. Storage failures must be reported to the caller; an implementation must
    /// never claim success after dropping the write.
    func save(_ item: DurableSyncOutboxItem) throws
    /// Persist a state transition for a batch atomically. Either every row is visible afterward,
    /// or none of them is. The engine uses this before dispatch and during recovery so a failed
    /// write cannot leave only part of a batch advanced.
    func saveAll(_ items: [DurableSyncOutboxItem]) throws
    func get(_ opId: String) throws -> DurableSyncOutboxItem?
    func list() throws -> [DurableSyncOutboxItem]
    func listByState(_ state: OutboxItemState) throws -> [DurableSyncOutboxItem]
    /// opIds of accepted parents that were PRUNED from the outbox (the committed-op ledger).
    /// `planDispatch` needs these so a dependent enqueued after its parent was pruned still
    /// resolves as satisfied instead of surfacing as a dead dependency.
    func committedOpIds() throws -> Set<String>
}

/// In-memory outbox. VOLATILE — TEST SEAM ONLY (mirrors `VolatileTicketEvidenceStore`).
public final class VolatileSyncOutboxStore: SyncOutboxStore {
    public let durability: StoreDurability = .volatileMemory
    private var byOpId: [String: DurableSyncOutboxItem] = [:]
    private var committed: Set<String> = []

    public init() {}

    public func save(_ item: DurableSyncOutboxItem) {
        byOpId[item.envelope.opId] = item
    }

    public func saveAll(_ items: [DurableSyncOutboxItem]) {
        var next = byOpId
        for item in items {
            next[item.envelope.opId] = item
        }
        byOpId = next
    }

    public func get(_ opId: String) -> DurableSyncOutboxItem? {
        byOpId[opId]
    }

    public func list() -> [DurableSyncOutboxItem] {
        Array(byOpId.values)
    }

    public func listByState(_ state: OutboxItemState) -> [DurableSyncOutboxItem] {
        list().filter { $0.state == state }
    }

    public func committedOpIds() -> Set<String> {
        committed
    }

    /// Test helper mirroring the durable store's prune-to-ledger move.
    public func markCommittedAndRemove(_ opId: String) {
        byOpId.removeValue(forKey: opId)
        committed.insert(opId)
    }
}

public protocol SyncFrontierStore {
    var durability: StoreDurability { get }
    /// The stored frontier, or nil before the first successful pull.
    func get() -> ChangeToken?
    /// Persist a new frontier. Monotonicity is the ENGINE's job (`advanceFrontier`); a reset after
    /// a stale-token answer is the one legitimate non-monotonic write.
    func set(_ token: ChangeToken)
}

/// In-memory frontier. VOLATILE — TEST SEAM ONLY.
public final class VolatileSyncFrontierStore: SyncFrontierStore {
    public let durability: StoreDurability = .volatileMemory
    private var token: ChangeToken?

    public init() {}

    public func get() -> ChangeToken? {
        token
    }

    public func set(_ token: ChangeToken) {
        self.token = token
    }
}
