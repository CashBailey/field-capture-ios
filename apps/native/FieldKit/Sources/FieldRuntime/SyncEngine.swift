// Port of src/runtime/syncEngine.ts — Full ADR 004 sync engine over the `SyncTransport` seam
// (`/sync/commands` + `/sync/changes`). Drives the durable generic outbox and the down-sync
// frontier. LAYERS BESIDE the V1 submit path — the V1 Hub client + `RetryEngine` keep serving the
// minimal ticket route untouched.
//
// Push (up-sync) invariants:
//  - Dispatch is dependency-ordered (`planDispatch`): an item ships only after every parent
//    committed; dead parents/cycles surface as `blocked` — reported, never dropped.
//  - Items go in-flight BEFORE the network is touched and every outcome is folded through the
//    contracts state machine (`applyCommandResult`) — an illegal transition throws rather than
//    corrupting evidence.
//  - A transport throw is transient for the WHOLE batch: every in-flight item returns to pending
//    with full-jitter backoff and the SAME envelope (identical idempotency key), so a replay can
//    never double-create on Hub. An auth failure returns items to pending WITHOUT a backoff stamp —
//    they are due the moment re-auth lands.
//  - Local state is preserved on every non-accepted outcome; only Hub's accept marks durable.
//
// Pull (down-sync) invariants:
//  - Pull strictly after the STORED frontier; the next frontier is validated (`advanceFrontier` —
//    monotonic, server-issued) BEFORE any change touches a local store.
//  - A stale token resets the frontier (Hub's `resetTo`, else the zero token) and re-pulls once —
//    never silently treated as an empty page.
//  - `applyChanges` + frontier-advance commit in one transaction (the `transaction` seam), so the
//    frontier never moves past changes that were not applied; `applyChanges` stays idempotent so a
//    crash before the commit lands simply replays the same page on the next pull.
//
// ponytail: the TS `transport: sync.SyncTransport` is the full generic interface (submitBatch +
// pullChanges + openUploadSession); this engine only ever calls the first two, so — mirroring the
// TS's own `Pick<sync.SyncTransport, 'openUploadSession'>` idiom used for `UploadEngineDeps` — the
// dependency is narrowed to `SyncCommandTransport`, fixed at the concrete `JSONValue` payload/change
// FieldDomain's `DurableSyncOutboxItem` already commits to. This keeps `SyncEngine` (and everything
// that holds one, like `AppController`) a plain non-generic type instead of viral over the
// transport's associated types.
import Foundation
import FieldContracts
import FieldDomain

/// Narrowed `SyncTransport` seam this engine actually drives (submit + pull), fixed at the
/// `JSONValue` payload/change FieldDomain's durable outbox and change ledger already use.
public protocol SyncCommandTransport {
    func submitBatch(_ batch: [OperationEnvelope<JSONValue>]) async throws -> [CommandResult<JSONValue>]
    func pullChanges(since: ChangeToken) async throws -> ChangePage<JSONValue>
}

public struct SyncEngineDeps {
    public var outbox: SyncOutboxStore
    public var frontier: SyncFrontierStore
    public var transport: SyncCommandTransport
    /// Apply one page of authoritative changes to local read stores. MUST be idempotent and throw
    /// if any change cannot be applied; a thrown error prevents the frontier from advancing.
    public var applyChanges: ([JSONValue]) throws -> Void
    /// Run `fn` atomically (apply + frontier-advance in one DB transaction). Optional: tests pass
    /// in-memory fakes and run `fn` directly. In production this wraps the SQLite driver's
    /// transaction so a crash can never advance the frontier past changes that were not applied.
    public var transaction: ((() throws -> Void) throws -> Void)?
    public var policy: RetryPolicy?
    public var now: (() -> Date)?
    public var random: (() -> Double)?
    /// Telemetry for non-fatal anomalies (e.g. Hub answered for an op we did not send).
    public var onError: ((String, Error) -> Void)?
    /// Fired when a NEW operation is enqueued — lets a runtime driver kick an immediate push.
    public var onEnqueue: (() -> Void)?
    /// Fired after a successful Hub exchange (commands or changes), for durable offline-policy state.
    public var onHubContact: ((Date) -> Void)?

    public init(
        outbox: SyncOutboxStore,
        frontier: SyncFrontierStore,
        transport: SyncCommandTransport,
        applyChanges: @escaping ([JSONValue]) throws -> Void,
        transaction: ((() throws -> Void) throws -> Void)? = nil,
        policy: RetryPolicy? = nil,
        now: (() -> Date)? = nil,
        random: (() -> Double)? = nil,
        onError: ((String, Error) -> Void)? = nil,
        onEnqueue: (() -> Void)? = nil,
        onHubContact: ((Date) -> Void)? = nil
    ) {
        self.outbox = outbox
        self.frontier = frontier
        self.transport = transport
        self.applyChanges = applyChanges
        self.transaction = transaction
        self.policy = policy
        self.now = now
        self.random = random
        self.onError = onError
        self.onEnqueue = onEnqueue
        self.onHubContact = onHubContact
    }
}

/// Invalid sync responses or incomplete local application that must not be acknowledged.
public enum SyncEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateCommandResult(opId: String)
    case skippedPulledChanges(count: Int)

    public var description: String {
        switch self {
        case .duplicateCommandResult(let opId):
            return "commands response contains duplicate result for op \(opId)"
        case .skippedPulledChanges(let count):
            let noun = count == 1 ? "change" : "changes"
            return "could not apply \(count) malformed pulled \(noun)"
        }
    }
}

public struct PushReport: Equatable, Sendable {
    /// Operations handed to the transport this pass.
    public var submitted: Int = 0
    public var accepted: Int = 0
    public var rejected: Int = 0
    public var needsReview: Int = 0
    /// Returned to pending with a backoff stamp (transport failure / missing result).
    public var rescheduled: Int = 0
    /// Ready but still inside their backoff window — untouched this pass.
    public var waitingBackoff: Int = 0
    /// Waiting on a dependency that may yet commit.
    public var waitingDependency: Int = 0
    /// Permanently blocked (dead parent / dependency cycle) — surfaced for manual review.
    public var blocked: [BlockedOp] = []
    /// True when the transport saw a 401/403 — items are pending and due; re-auth then re-push.
    public var authRequired: Bool = false

    public struct BlockedOp: Equatable, Sendable {
        public var opId: String
        public var reason: BlockReason
        public var deps: [String]
    }
}

public struct PullReport: Equatable, Sendable {
    public var applied: Int
    public var frontier: ChangeToken
    /// True when Hub declared the stored token stale and the frontier was reset before re-pulling.
    public var frontierReset: Bool
}

public struct SyncOnceReport {
    public var push: PushReport
    public var pull: PullReport?
}

/// ponytail: `DurableSyncOutboxItem` (FieldDomain) carries extra durable-only fields (notably
/// `nextAttemptAtMs`) that the generic contracts `OutboxItem<Payload>` has no room for. TS gets this
/// for free — object spread + structural typing lets a durable row stand in for the narrower
/// interface and vice versa (see the `syncOutbox.ts` port comment). Swift's nominal typing needs an
/// explicit shim so the actual tested contracts functions (`markInFlight`, `markForRetry`,
/// `applyCommandResult`, `planDispatch`) are reused rather than re-implemented against the durable
/// type.
private extension DurableSyncOutboxItem {
    var asOutboxItem: OutboxItem<JSONValue> {
        OutboxItem(
            envelope: envelope, state: state, retryCount: retryCount, committedToken: committedToken,
            rejectionCode: rejectionCode, lastError: lastError, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// Fold the generic contracts result back onto this durable row — the durable-only fields
    /// (`nextAttemptAtMs`) survive untouched; the fields the two types share are overwritten.
    func folding(_ generic: OutboxItem<JSONValue>) -> DurableSyncOutboxItem {
        var next = self
        next.envelope = generic.envelope
        next.state = generic.state
        next.retryCount = generic.retryCount
        next.committedToken = generic.committedToken
        next.rejectionCode = generic.rejectionCode
        next.lastError = generic.lastError
        return next
    }
}

public final class SyncEngine {
    private let deps: SyncEngineDeps
    private let policy: RetryPolicy
    private let now: () -> Date
    private let random: () -> Double

    public init(_ deps: SyncEngineDeps) {
        self.deps = deps
        self.policy = deps.policy ?? DEFAULT_RETRY_POLICY
        self.now = deps.now ?? { Date() }
        self.random = deps.random ?? { Double.random(in: 0..<1) }
    }

    /// Add one operation to the durable outbox. Validates write identity
    /// (`assertEnvelopeConsistent`) and is idempotent on opId: re-enqueueing the same envelope
    /// returns the existing row; a DIFFERENT envelope under the same opId throws.
    @discardableResult
    public func enqueue(_ envelope: OperationEnvelope<JSONValue>) throws -> DurableSyncOutboxItem {
        try assertEnvelopeConsistent(envelope)
        if let existing = try deps.outbox.get(envelope.opId) {
            guard existing.envelope.idempotencyKey == envelope.idempotencyKey else {
                throw OutboxError("opId \(envelope.opId) is already queued with a different idempotency key")
            }
            return existing
        }
        let at = isoStamp(now())
        let item = DurableSyncOutboxItem(
            envelope: envelope, state: .pending, retryCount: 0, createdAt: at, updatedAt: at)
        try deps.outbox.save(item)
        deps.onEnqueue?()  // kick a runtime driver (if any) to push the fresh work promptly
        return item
    }

    /// Boot sweep: orphaned in-flight rows (the app died before Hub's answer landed) return to
    /// pending — the SAME idempotency key makes the re-send safe. MUST run before any push.
    @discardableResult
    public func recoverOnStartup() throws -> [String] {
        let items = try deps.outbox.list()
        let byOpId = Dictionary(uniqueKeysWithValues: items.map { ($0.envelope.opId, $0) })
        let recovery = recoverOutboxOnRestart(items.map(\.asOutboxItem))
        let recoveredByOpId = Dictionary(
            uniqueKeysWithValues: recovery.items.map { ($0.envelope.opId, $0) })
        let at = isoStamp(now())
        let recoveredItems = try recovery.recoveredOpIds.map { opId in
            guard let durable = byOpId[opId], let recovered = recoveredByOpId[opId] else {
                throw OutboxError("restart recovery lost outbox row \(opId)")
            }
            var next = durable.folding(recovered)
            next.updatedAt = at
            return next
        }
        try deps.outbox.saveAll(recoveredItems)
        return recovery.recoveredOpIds
    }

    /// One push pass: dispatch every due, dependency-satisfied pending item as a single batch.
    public func pushOnce() async throws -> PushReport {
        var report = PushReport()

        let items = try deps.outbox.list()
        let byOpId = Dictionary(uniqueKeysWithValues: items.map { ($0.envelope.opId, $0) })
        let committedOpIds = try deps.outbox.committedOpIds()
        let plan = try planDispatch(items.map(\.asOutboxItem), committedOpIds: committedOpIds)
        report.waitingDependency = plan.waiting.count
        report.blocked = plan.blocked.map {
            PushReport.BlockedOp(opId: $0.item.envelope.opId, reason: $0.reason, deps: $0.deps)
        }

        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        var due: [DurableSyncOutboxItem] = []
        for ready in plan.ready {
            guard let durable = byOpId[ready.envelope.opId] else {
                throw OutboxError("dispatch plan referenced missing outbox row \(ready.envelope.opId)")
            }
            if let nextAttempt = durable.nextAttemptAtMs, nextAttempt > nowMs {
                report.waitingBackoff += 1
            } else {
                due.append(durable)
            }
        }
        guard !due.isEmpty else { return report }

        let at = isoStamp(now())
        let inFlight = try due.map { item in
            // markInFlight spreads its input, so the durable fields survive; `folding` restores the
            // narrower durable type the generic contracts signature cannot carry.
            var next = item.folding(try markInFlight(item.asOutboxItem))
            next.updatedAt = at
            return next
        }
        // Commit the entire dispatch transition before touching the network. A failed write leaves
        // every row pending and therefore safe to retry on a later pass.
        try deps.outbox.saveAll(inFlight)
        report.submitted = inFlight.count

        let results: [CommandResult<JSONValue>]
        do {
            results = try await deps.transport.submitBatch(inFlight.map(\.envelope))
        } catch {
            let auth = error is HubAuthError
            try rescheduleAfterTransportFailure(inFlight, error, authFailure: auth)
            if auth {
                report.authRequired = true
            } else {
                report.rescheduled = inFlight.count
            }
            return report
        }
        deps.onHubContact?(now())

        // Validate the whole response before folding any outcome. A duplicate result is
        // ambiguous (the two outcomes may conflict), so retry the idempotent batch intact instead
        // of crashing or partially committing it.
        var resultByOpId: [String: CommandResult<JSONValue>] = [:]
        for result in results {
            guard resultByOpId[result.opId] == nil else {
                let error = SyncEngineError.duplicateCommandResult(opId: result.opId)
                try rescheduleAfterTransportFailure(inFlight, error, authFailure: false)
                throw error
            }
            resultByOpId[result.opId] = result
        }

        var persistedOutcomes: [DurableSyncOutboxItem] = []
        var accepted = 0
        var rejected = 0
        var needsReview = 0
        var rescheduled = 0
        for item in inFlight {
            guard let result = resultByOpId[item.envelope.opId] else {
                // Hub answered the batch but omitted this op — transient for THIS op only.
                persistedOutcomes.append(
                    try itemAfterTransportFailure(
                        item, OutboxError("no result for op in commands response"), authFailure: false))
                rescheduled += 1
                continue
            }
            resultByOpId.removeValue(forKey: item.envelope.opId)
            var next = item.folding(try applyCommandResult(item.asOutboxItem, result))
            next.updatedAt = isoStamp(now())
            // Preserve Hub's reason verbatim where the state machine has no field for it.
            switch result {
            case .needsReview(_, let reviewReason):
                next.lastError = reviewReason
            case .rejected(_, _, let detail, _):
                if let detail { next.lastError = detail }
            case .accepted:
                break
            }
            persistedOutcomes.append(next)
            switch result {
            case .accepted: accepted += 1
            case .rejected: rejected += 1
            case .needsReview: needsReview += 1
            }
        }

        // Fold the complete response atomically. If persistence fails, no row can appear accepted
        // while another row from the same Hub response remains in-flight.
        try deps.outbox.saveAll(persistedOutcomes)
        report.accepted = accepted
        report.rejected = rejected
        report.needsReview = needsReview
        report.rescheduled = rescheduled
        for orphan in resultByOpId.keys {
            deps.onError?("push", OutboxError("Hub returned a result for unknown op \(orphan)"))
        }
        return report
    }

    /// Return an in-flight item to pending. Auth failures skip the backoff stamp — the item is due
    /// the moment a fresh token exists; everything else gets full-jitter backoff.
    private func itemAfterTransportFailure(
        _ item: DurableSyncOutboxItem, _ error: Error, authFailure: Bool
    ) throws -> DurableSyncOutboxItem {
        var next = item.folding(try markForRetry(item.asOutboxItem))
        next.nextAttemptAtMs = nil
        next.updatedAt = isoStamp(now())
        next.lastError = String(describing: error)
        if !authFailure {
            next.nextAttemptAtMs = try computeNextAttemptAtMs(
                Int64(now().timeIntervalSince1970 * 1000), max(0, next.retryCount - 1), random, policy)
        }
        return next
    }

    private func rescheduleAfterTransportFailure(
        _ items: [DurableSyncOutboxItem], _ error: Error, authFailure: Bool
    ) throws {
        let rescheduled = try items.map {
            try itemAfterTransportFailure($0, error, authFailure: authFailure)
        }
        try deps.outbox.saveAll(rescheduled)
    }

    /// One pull pass: fetch the page after the stored frontier, validate the next token, apply,
    /// persist. On a stale token: reset the frontier and re-pull once in the same pass.
    public func pullOnce() async throws -> PullReport {
        let since = deps.frontier.get() ?? ZERO_CHANGE_TOKEN
        var frontierReset = false
        var effectiveSince = since
        var page: ChangePage<JSONValue>
        do {
            page = try await deps.transport.pullChanges(since: since)
        } catch let error as StaleChangeTokenError {
            effectiveSince = error.resetTo ?? ZERO_CHANGE_TOKEN
            deps.frontier.set(effectiveSince)  // the one legitimate non-monotonic write
            frontierReset = true
            page = try await deps.transport.pullChanges(since: effectiveSince)
        }
        deps.onHubContact?(now())
        // Validate BEFORE applying — a regressed/garbage token must not let changes touch stores.
        let nextFrontier = try advanceFrontier(effectiveSince, page.token)
        // Apply + advance the frontier atomically: the frontier must never move past changes that
        // were not durably applied. Without a transaction seam (test fakes) the two run back-to-back
        // and the engine's idempotent re-delivery still covers a crash between them.
        let commit: () throws -> Void = { [deps] in
            try deps.applyChanges(page.changes)
            deps.frontier.set(nextFrontier)
        }
        if let transaction = deps.transaction {
            try transaction(commit)
        } else {
            try commit()
        }
        return PullReport(applied: page.changes.count, frontier: nextFrontier, frontierReset: frontierReset)
    }

    /// Push then pull. Push failures propagate to the runner's throwing sweep seam, so durable
    /// storage errors cannot masquerade as an empty successful pass. A pull failure is reported
    /// via `onError` and never masks an already-completed push report.
    public func syncOnce() async throws -> SyncOnceReport {
        var push = try await pushOnce()
        do {
            let pull = try await pullOnce()
            return SyncOnceReport(push: push, pull: pull)
        } catch {
            // A pull-leg auth failure must pause the driver too: pushOnce sets authRequired on the
            // push leg, but a pass with nothing to push would otherwise 401 on pull every tick.
            if error is HubAuthError { push.authRequired = true }
            deps.onError?("pull", error)
            return SyncOnceReport(push: push, pull: nil)
        }
    }
}
