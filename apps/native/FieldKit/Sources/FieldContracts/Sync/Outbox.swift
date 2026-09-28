// Port of sync/outbox.ts — Outbox behaviour (ADR 004): the durable, ordered, dependency-aware
// queue of commands/events the phone submits to Hub. Pure contracts only — NO persistence, NO
// network. This module owns:
//
//   1. Envelope consistency invariants (write identity is internally coherent before it queues).
//   2. The outbox item state machine (which transitions are legal).
//   3. Dispatch planning: which items may be sent now, in `local_seq` order, gated on their
//      dependencies — and which are permanently blocked (a parent that can never commit, or a
//      dependency cycle), so they surface for review instead of retrying forever.
//
// Cross-cutting invariant #2 ("never silently lose work"): a blocked item is never dropped; it is
// reported so a later engine slice can route it to manual review (report 03: "any command depends
// on a parent object that never committed" → manual review).

public struct OutboxError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

// ---- envelope consistency ----

/**
 * Assert one envelope is internally coherent before it enters the outbox. This is write-identity
 * hygiene, not business validation (Hub still authoritatively validates the operation):
 * - opId non-empty;
 * - idempotencyKey parses AND its embedded local_seq matches the envelope's (one source of truth);
 * - dependsOn has no self-reference and no duplicates;
 * - immutable events carry no version precondition (append-only; preconditions are for mutable edits).
 *
 * ponytail: TS also asserts `localSeq` is a non-negative integer via `Number.isInteger`; `localSeq`
 * is Swift `Int` here, so only the non-negativity half is meaningful (kept below).
 */
public func assertEnvelopeConsistent<Payload>(_ env: OperationEnvelope<Payload>) throws {
    guard !env.opId.isEmpty else {
        throw OutboxError("envelope.opId must be non-empty")
    }
    guard env.localSeq >= 0 else {
        throw OutboxError("envelope.localSeq must be a non-negative integer")
    }
    // Throws IdempotencyKeyError if malformed — a malformed key IS an identity error.
    let parsed = try parseIdempotencyKey(env.idempotencyKey)
    guard parsed.localSeq == env.localSeq else {
        throw OutboxError(
            "idempotencyKey local_seq (\(parsed.localSeq)) disagrees with envelope.localSeq (\(env.localSeq))"
        )
    }
    guard !env.dependsOn.contains(env.opId) else {
        throw OutboxError("envelope \(env.opId) depends on itself")
    }
    guard Set(env.dependsOn).count == env.dependsOn.count else {
        throw OutboxError("envelope \(env.opId) has duplicate dependsOn entries")
    }
    guard !(env.kind == .event && env.precondition != nil) else {
        throw OutboxError("immutable event \(env.opId) must not carry a version precondition (append-only)")
    }
}

// ---- state machine ----

/**
 * Legal outbox transitions. `pending` → dispatched (`in-flight`) or locally retired
 * (`rejected`/`needs-review`, e.g. a dead dependency). `in-flight` → a Hub outcome, or back to
 * `pending` for a transient retry. `accepted`/`rejected`/`needs-review` are terminal.
 */
private let OUTBOX_TRANSITIONS: [OutboxItemState: [OutboxItemState]] = [
    .pending: [.inFlight, .rejected, .needsReview],
    .inFlight: [.accepted, .rejected, .needsReview, .pending],
    .accepted: [],
    .rejected: [],
    .needsReview: [],
]

public func canTransition(_ from: OutboxItemState, _ to: OutboxItemState) -> Bool {
    (OUTBOX_TRANSITIONS[from] ?? []).contains(to)
}

public func assertTransition(_ from: OutboxItemState, _ to: OutboxItemState) throws {
    guard canTransition(from, to) else {
        throw OutboxError("illegal outbox transition: \(from.rawValue) -> \(to.rawValue)")
    }
}

/// Mark an item dispatched. Must be `pending`. Returns a new item (inputs are never mutated).
public func markInFlight<Payload>(_ item: OutboxItem<Payload>) throws -> OutboxItem<Payload> {
    try assertTransition(item.state, .inFlight)
    var next = item
    next.state = .inFlight
    return next
}

/// Return an in-flight item to the queue for a transient retry (network/5xx/429), bumping retryCount.
public func markForRetry<Payload>(_ item: OutboxItem<Payload>) throws -> OutboxItem<Payload> {
    try assertTransition(item.state, .pending)
    var next = item
    next.state = .pending
    next.retryCount += 1
    return next
}

/**
 * Fold a Hub `CommandResult` into the outbox item. The item must be `in-flight`. `accepted` records
 * the committed change token; `rejected` records the machine-readable code; `needs-review` freezes
 * it for manual resolution. Never auto-merges (ADR 004).
 *
 * ponytail: TS has a `default` branch that throws on an unrecognized `.outcome` string (defense
 * against a wire-deserialized value escaping the type system). `CommandResult` is a real Swift
 * enum, so an "unknown outcome" case cannot be constructed — the switch below is exhaustive at
 * compile time and that branch (and its ported test) is dropped as unreachable.
 */
public func applyCommandResult<Payload>(
    _ item: OutboxItem<Payload>,
    _ result: CommandResult<Payload>
) throws -> OutboxItem<Payload> {
    guard result.opId == item.envelope.opId else {
        throw OutboxError("CommandResult opId \(result.opId) does not match item \(item.envelope.opId)")
    }
    switch result {
    case .accepted(_, let token):
        try assertTransition(item.state, .accepted)
        var next = item
        next.state = .accepted
        next.committedToken = token
        return next
    case .rejected(_, let rejectionCode, _, _):
        try assertTransition(item.state, .rejected)
        var next = item
        next.state = .rejected
        next.rejectionCode = rejectionCode
        return next
    case .needsReview:
        try assertTransition(item.state, .needsReview)
        var next = item
        next.state = .needsReview
        return next
    }
}

// ---- dispatch planning ----

public enum BlockReason: String, Equatable, Sendable {
    case deadDependency = "dead-dependency"
    case dependencyCycle = "dependency-cycle"
}

public struct BlockedItem<Payload: Sendable>: Sendable {
    public var item: OutboxItem<Payload>
    public var reason: BlockReason
    /// The dependency opIds responsible for the block (dead parents, or cycle members).
    public var deps: [String]
}
extension BlockedItem: Equatable where Payload: Equatable {}

public struct DispatchPlan<Payload: Sendable>: Sendable {
    /// `pending` items whose dependencies are all satisfied — send these, in `local_seq` order.
    public var ready: [OutboxItem<Payload>]
    /// `pending` items still waiting on a dependency that may yet commit.
    public var waiting: [OutboxItem<Payload>]
    /// `pending` items that can never proceed (dead parent or cycle) — route to review, never retry.
    public var blocked: [BlockedItem<Payload>]
}
extension DispatchPlan: Equatable where Payload: Equatable {}

/**
 * Kahn's algorithm over the *pending* sub-graph. Any node left with a positive in-degree is in a
 * dependency cycle or transitively behind one — i.e. it can never be topologically ordered, so it
 * can never become ready. In-flight items are deliberately excluded: an item only reaches in-flight
 * after a prior plan found it `ready` (all deps satisfied), so it cannot be a live cycle member, and
 * its Hub outcome is still unknown — a pending item behind it should `wait`, not be declared a
 * permanent cycle.
 */
private func unorderableOpIds<Payload>(_ items: [OutboxItem<Payload>]) -> Set<String> {
    var nodeIds = Set<String>()
    for it in items where it.state == .pending { nodeIds.insert(it.envelope.opId) }

    var indegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    for id in nodeIds {
        indegree[id] = 0
        dependents[id] = []
    }
    for it in items {
        let id = it.envelope.opId
        guard nodeIds.contains(id) else { continue }
        for dep in it.envelope.dependsOn {
            guard nodeIds.contains(dep) else { continue }  // only in-set deps form cycle edges
            indegree[id] = (indegree[id] ?? 0) + 1
            dependents[dep, default: []].append(id)
        }
    }

    var queue: [String] = indegree.filter { $0.value == 0 }.map(\.key)
    var head = 0
    while head < queue.count {
        let id = queue[head]
        head += 1
        for succ in dependents[id] ?? [] {
            let deg = (indegree[succ] ?? 0) - 1
            indegree[succ] = deg
            if deg == 0 { queue.append(succ) }
        }
    }

    var unorderable = Set<String>()
    for (id, deg) in indegree where deg > 0 { unorderable.insert(id) }
    return unorderable
}

/**
 * Classify every `pending` item as ready / waiting / blocked, gated on its dependencies. A
 * dependency is *satisfied* if it already committed (in `committedOpIds`, for parents already
 * pruned from the outbox) or is present and `accepted`; *dead* if present and terminally
 * rejected/under-review, or absent entirely (a parent that never committed); otherwise it is still
 * in flight and the dependent *waits*. `ready` is returned in ascending `local_seq` order (report
 * 03: process in `local_seq` order). In-flight and terminal items are not returned — they are not
 * candidates for dispatch. Throws on a duplicate opId (the outbox must have unique write identity).
 */
public func planDispatch<Payload>(
    _ items: [OutboxItem<Payload>],
    committedOpIds: Set<String> = []
) throws -> DispatchPlan<Payload> {
    var byOpId: [String: OutboxItem<Payload>] = [:]
    for it in items {
        guard byOpId[it.envelope.opId] == nil else {
            throw OutboxError("duplicate opId in outbox: \(it.envelope.opId)")
        }
        byOpId[it.envelope.opId] = it
    }

    let unorderable = unorderableOpIds(items)
    var ready: [OutboxItem<Payload>] = []
    var waiting: [OutboxItem<Payload>] = []
    var blocked: [BlockedItem<Payload>] = []

    for it in items {
        guard it.state == .pending else { continue }
        let opId = it.envelope.opId

        if unorderable.contains(opId) {
            // Report every culprit: cycle members AND any genuinely-dead parent (absent, or
            // terminally rejected/under-review), so a reviewer sees the full reason — not just the
            // cycle edge.
            let culprits = it.envelope.dependsOn.filter { dep in
                if committedOpIds.contains(dep) { return false }
                if unorderable.contains(dep) { return true }
                let parent = byOpId[dep]
                return parent == nil || parent?.state == .rejected || parent?.state == .needsReview
            }
            blocked.append(BlockedItem(item: it, reason: .dependencyCycle, deps: culprits))
            continue
        }

        var dead: [String] = []
        var anyWaiting = false
        for dep in it.envelope.dependsOn {
            if committedOpIds.contains(dep) { continue }  // already committed and pruned
            guard let parent = byOpId[dep] else {
                dead.append(dep)  // never committed, not in outbox
                continue
            }
            if parent.state == .accepted {
                continue  // satisfied
            } else if parent.state == .rejected || parent.state == .needsReview {
                dead.append(dep)  // will never commit
            } else {
                anyWaiting = true  // pending / in-flight — may yet commit
            }
        }

        if !dead.isEmpty {
            blocked.append(BlockedItem(item: it, reason: .deadDependency, deps: dead))
        } else if anyWaiting {
            waiting.append(it)
        } else {
            ready.append(it)
        }
    }

    ready.sort { $0.envelope.localSeq < $1.envelope.localSeq }
    return DispatchPlan(ready: ready, waiting: waiting, blocked: blocked)
}

/// Convenience: the committed change tokens of all `accepted` items, in commit order.
public func committedTokens<Payload>(_ items: [OutboxItem<Payload>]) -> [ChangeToken] {
    var tokens: [ChangeToken] = []
    for it in items where it.state == .accepted {
        if let token = it.committedToken { tokens.append(token) }
    }
    return tokens
}
