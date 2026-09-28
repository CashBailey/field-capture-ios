// Port of src/runtime/restartRecovery.ts — Boot-time restart recovery (spec: pending → retry,
// in-flight → retry, failed → stays failed, accepted → done).
//
// An app killed mid-submit leaves durable evidence `in-flight` with the Hub outcome unknown.
// Re-sending is safe — the SAME idempotency key means Hub dedupes — so those orphans are swept
// back to `pending` here. Terminal rows (`accepted` / `rejected` / `needs-review`) are never
// touched, and `pending` rows simply remain queued for the retry engine.
//
// MUST run before the retry engine starts and before any submit path executes: a stale in-flight
// row would otherwise deadlock against the double-submit guard ("already-in-flight") forever.
// `AppController.start()` enforces this ordering.
import Foundation
import FieldContracts
import FieldDomain

public struct EvidenceRecovery {
    /// Idempotency keys of orphaned in-flight rows returned to pending.
    public var recoveredKeys: [String]

    public init(recoveredKeys: [String]) {
        self.recoveredKeys = recoveredKeys
    }
}

public func recoverEvidenceOnStartup(
    _ store: TicketEvidenceStore,
    _ now: () -> Date = { Date() }
) -> EvidenceRecovery {
    var recoveredKeys: [String] = []
    for evidence in store.list() {
        guard evidence.state == .inFlight else { continue }
        // The guard establishes the legal in-flight -> pending recovery transition.
        let at = isoStamp(now())
        var next = evidence
        next.state = .pending
        next.attempts += 1  // the interrupted attempt counts — it may have reached Hub
        next.updatedAt = at
        next.lastTransientReason = "restart-interrupted"
        store.save(next)
        recoveredKeys.append(evidence.envelope.idempotencyKey)
    }
    return EvidenceRecovery(recoveredKeys: recoveredKeys)
}

/// ISO-8601 with fractional seconds, matching the rest of the runtime's timestamp stamping.
func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
