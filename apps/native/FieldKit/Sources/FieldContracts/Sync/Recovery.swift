// Port of sync/recovery.ts — Restart recovery (ADR 004): what happens to durable outbox rows when
// the app comes back up after being killed. Pure — takes rows, returns rows; persistence is the
// caller's job.
//
// Policy (ops-triad-contract.md "in-flight orphan recovery on restart"):
//   pending      -> stays pending (the dispatch loop will pick it up)
//   in-flight    -> swept back to pending for retry (the app died before Hub's answer landed;
//                   the SAME idempotency key makes the re-send safe — Hub dedupes)
//   accepted     -> stays accepted (done)
//   rejected / needs-review -> stay frozen (terminal; manual review, never silent resubmission)
//
// The sweep MUST run before any dispatch path executes, or orphaned in-flight rows deadlock
// against the double-submit guard ("already-in-flight") forever.

public struct RestartRecovery<Payload: Sendable>: Sendable {
    /// Every input row, post-sweep, in input order.
    public var items: [OutboxItem<Payload>]
    /// opIds that were orphaned in-flight and have been returned to pending.
    public var recoveredOpIds: [String]
}
extension RestartRecovery: Equatable where Payload: Equatable {}

public func recoverOutboxOnRestart<Payload>(_ items: [OutboxItem<Payload>]) -> RestartRecovery<Payload> {
    var recoveredOpIds: [String] = []
    let swept = items.map { item -> OutboxItem<Payload> in
        guard item.state == .inFlight else { return item }
        recoveredOpIds.append(item.envelope.opId)
        // The guard above establishes the only legal recovery transition. Apply its two state
        // changes directly so this total recovery function cannot trap.
        var recovered = item
        recovered.state = .pending
        recovered.retryCount += 1  // the interrupted attempt counts
        return recovered
    }
    return RestartRecovery(items: swept, recoveredOpIds: recoveredOpIds)
}
