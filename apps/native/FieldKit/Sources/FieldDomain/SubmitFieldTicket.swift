// Port of src/domain/submitFieldTicket.ts — Minimal field-ticket submit path (first real OpsHub
// integration slice).
//
// Invariants (cross-cutting #2 — never silently lose work, never pretend it is safe):
//  - Evidence is recorded locally BEFORE the network is touched, keyed by the idempotency key.
//  - The evidence reaches `.accepted` ONLY when Hub accepts (or replays a previous accept).
//  - Every other outcome preserves the evidence: transient/blocked/auth → back to `.pending`
//    (retryable with the SAME key, so retries can never double-create a ticket on Hub);
//    needs-review → frozen as evidence for manual resolution.
//
// State legality is enforced with the tested contracts state machine (`assertTransition`), and
// write identity with the contracts envelope + idempotency helpers.
import Foundation
import FieldContracts

private let TICKET_SUBMIT_OP: SyncOpType = "ticket.submit"

private func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// What the caller provides; the idempotency key is derived, never hand-rolled.
public struct FieldTicketInput: Equatable, Sendable {
    public var serviceRequestId: String
    /// Hash of the assignment snapshot this ticket was captured against (drift detection).
    public var snapshotHash: String
    public var ticketNo: String
    public var quantityBbl: Double
    public var disposalTicketNo: String
    /// Stable per-install id + per-device sequence + operation UUID → idempotency key.
    public var deviceInstanceId: String
    public var localSeq: Int
    public var opUuid: String
    /// Full paper-ticket detail (gauges, times, rig #, line items); rides along additively.
    public var detail: FieldTicketDetail?

    public init(
        serviceRequestId: String,
        snapshotHash: String,
        ticketNo: String,
        quantityBbl: Double,
        disposalTicketNo: String,
        deviceInstanceId: String,
        localSeq: Int,
        opUuid: String,
        detail: FieldTicketDetail? = nil
    ) {
        self.serviceRequestId = serviceRequestId
        self.snapshotHash = snapshotHash
        self.ticketNo = ticketNo
        self.quantityBbl = quantityBbl
        self.disposalTicketNo = disposalTicketNo
        self.deviceInstanceId = deviceInstanceId
        self.localSeq = localSeq
        self.opUuid = opUuid
        self.detail = detail
    }
}

/**
 * Local evidence of a submission attempt — the durable outbox row for the submit path. Wraps a
 * real contracts `OperationEnvelope` (validated by `assertEnvelopeConsistent`) so this record can
 * later migrate into the full ADR 004 outbox without reshaping.
 *
 * Outbox-shape mapping: id / idempotency_key = `envelope.idempotencyKey`, type = `envelope.type`,
 * payload = `envelope.payload`, status = `state` ("retry" ≙ `pending` with `attempts > 0`;
 * "failed" ≙ terminal `rejected` / `needs-review`), last_error = `lastDetail` /
 * `lastTransientReason`, created_at / updated_at below.
 */
public struct TicketEvidence: Equatable, Sendable {
    public var envelope: OperationEnvelope<HubFieldTicketSubmission>
    public var state: OutboxItemState
    public var attempts: Int
    /// ISO 8601 — when this evidence was first recorded / last changed.
    public var createdAt: String
    public var updatedAt: String
    /// Hub's most recent machine-readable rejection code, preserved verbatim.
    public var lastRejectionCode: String?
    /// Hub's human-readable detail for the most recent failure, preserved verbatim.
    public var lastDetail: String?
    /// HTTP status of the most recent non-accepted Hub answer.
    public var lastHttpStatus: Int?
    /// When the most recent Hub outcome landed (ISO 8601).
    public var lastOutcomeAt: String?
    /// 'network' | 'server' | 'malformed-response' (transient), 'auth-failed' (needs re-auth),
    /// 'client-error' (the submitter threw locally), or 'restart-interrupted' (boot sweep).
    public var lastTransientReason: String?
    /// Epoch ms before which the background retry engine must not redispatch (full-jitter backoff).
    public var nextAttemptAtMs: Int64?

    public init(
        envelope: OperationEnvelope<HubFieldTicketSubmission>,
        state: OutboxItemState,
        attempts: Int,
        createdAt: String,
        updatedAt: String,
        lastRejectionCode: String? = nil,
        lastDetail: String? = nil,
        lastHttpStatus: Int? = nil,
        lastOutcomeAt: String? = nil,
        lastTransientReason: String? = nil,
        nextAttemptAtMs: Int64? = nil
    ) {
        self.envelope = envelope
        self.state = state
        self.attempts = attempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRejectionCode = lastRejectionCode
        self.lastDetail = lastDetail
        self.lastHttpStatus = lastHttpStatus
        self.lastOutcomeAt = lastOutcomeAt
        self.lastTransientReason = lastTransientReason
        self.nextAttemptAtMs = nextAttemptAtMs
    }
}

public protocol TicketEvidenceStore {
    var durability: StoreDurability { get }
    func save(_ evidence: TicketEvidence)
    func get(_ idempotencyKey: String) -> TicketEvidence?
    func list() -> [TicketEvidence]
}

/**
 * In-memory evidence store. VOLATILE: lost on app restart. TEST SEAM ONLY — production uses
 * FieldData's durable SQLite ticket-evidence store (SQLCipher in real builds). Never wire this
 * into the app shell; the UI must not present its contents as saved.
 */
public final class VolatileTicketEvidenceStore: TicketEvidenceStore {
    public let durability: StoreDurability = .volatileMemory
    private let lock = NSLock()
    private var byKey: [String: TicketEvidence] = [:]

    public init() {}

    public func save(_ evidence: TicketEvidence) {
        withLock { byKey[evidence.envelope.idempotencyKey] = evidence }
    }

    public func get(_ idempotencyKey: String) -> TicketEvidence? {
        withLock { byKey[idempotencyKey] }
    }

    public func list() -> [TicketEvidence] {
        withLock { Array(byKey.values) }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// The user-visible result. Only `.accepted` means the work is durable on Hub.
public enum SubmitFieldTicketResult: Equatable, Sendable {
    public enum NotSubmittedReason: String, Equatable, Sendable {
        case missingSnapshotHash = "missing-snapshot-hash"
    }

    case accepted(duplicate: Bool, snapshotDrift: Bool?, idempotencyKey: String)
    case blocked(rejectionCode: String, httpStatus: Int, detail: String?, idempotencyKey: String)
    case needsReview(rejectionCode: String, httpStatus: Int, detail: String?, idempotencyKey: String)
    case pendingRetry(reason: String, idempotencyKey: String)
    case authRequired(idempotencyKey: String)
    /// Refused locally before any evidence or network I/O — fix the input and resubmit.
    case notSubmitted(reason: NotSubmittedReason, idempotencyKey: String)
}

/**
 * Rebuild the evidence record for a new Hub outcome. Each outcome REPLACES the previous failure
 * detail (a stale rejection code must not linger once a later attempt failed differently — the
 * retry engine reads `lastRejectionCode` as "user-action-gated") while `createdAt`, the envelope,
 * and the idempotency key never change. `nextAttemptAtMs` is dropped; the retry engine recomputes
 * it after each transient failure.
 */
private func withOutcome(
    _ evidence: TicketEvidence,
    state: OutboxItemState,
    at: String,
    attemptsDelta: Int = 0,
    rejectionCode: String? = nil,
    detail: String? = nil,
    httpStatus: Int? = nil,
    transientReason: String? = nil
) -> TicketEvidence {
    TicketEvidence(
        envelope: evidence.envelope,
        state: state,
        attempts: evidence.attempts + attemptsDelta,
        createdAt: evidence.createdAt,
        updatedAt: at,
        lastRejectionCode: rejectionCode,
        lastDetail: detail,
        lastHttpStatus: httpStatus,
        lastOutcomeAt: at,
        lastTransientReason: transientReason,
        nextAttemptAtMs: nil
    )
}

public struct SubmitFieldTicketDeps {
    public var submitter: FieldTicketSubmitter
    public var evidenceStore: TicketEvidenceStore
    /// Clock for evidence timestamps; injectable for tests. Defaults to the real clock.
    public var now: (() -> Date)?

    public init(submitter: FieldTicketSubmitter, evidenceStore: TicketEvidenceStore, now: (() -> Date)? = nil) {
        self.submitter = submitter
        self.evidenceStore = evidenceStore
        self.now = now
    }
}

public func submitFieldTicket(
    _ deps: SubmitFieldTicketDeps,
    _ input: FieldTicketInput
) async throws -> SubmitFieldTicketResult {
    func stamp() -> String { isoStamp((deps.now ?? { Date() })()) }

    // Throws IdempotencyKeyError on bad identity inputs — before any evidence or network I/O.
    let idempotencyKey = try buildIdempotencyKey(input.deviceInstanceId, input.localSeq, input.opUuid)

    // Never submit without the assignment's snapshot hash — it is the only drift protection
    // (Hub's 412 guard). A blank hash means the assignment was never pulled or the caller lost
    // it; submitting anyway would silently disarm drift detection.
    if input.snapshotHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .notSubmitted(reason: .missingSnapshotHash, idempotencyKey: idempotencyKey)
    }

    var evidence: TicketEvidence
    if let existing = deps.evidenceStore.get(idempotencyKey) {
        if existing.state == .accepted {
            // Hub already accepted this operation; replaying locally is safe and adds nothing.
            return .accepted(duplicate: true, snapshotDrift: nil, idempotencyKey: idempotencyKey)
        }
        if existing.state == .inFlight {
            // A submission of this exact operation is already awaiting Hub's answer (e.g. a
            // double-tap). Never race a second network call with the same key — back off; the
            // first call will land the outcome and the evidence is preserved either way.
            return .pendingRetry(reason: "already-in-flight", idempotencyKey: idempotencyKey)
        }
        evidence = existing
    } else {
        let envelope = OperationEnvelope<HubFieldTicketSubmission>(
            opId: input.opUuid,
            kind: .command,
            type: TICKET_SUBMIT_OP,
            idempotencyKey: idempotencyKey,
            localSeq: input.localSeq,
            dependsOn: [],
            payload: HubFieldTicketSubmission(
                idempotencyKey: idempotencyKey,
                serviceRequestId: input.serviceRequestId,
                snapshotHash: input.snapshotHash,
                ticketNo: input.ticketNo,
                quantityBbl: input.quantityBbl,
                disposalTicketNo: input.disposalTicketNo,
                detail: input.detail
            )
        )
        try assertEnvelopeConsistent(envelope)
        let createdAt = stamp()
        evidence = TicketEvidence(
            envelope: envelope, state: .pending, attempts: 0, createdAt: createdAt, updatedAt: createdAt)
        deps.evidenceStore.save(evidence)
    }

    // pending → in-flight (assertTransition throws on a frozen needs-review/rejected record:
    // frozen evidence must go through manual review, never silent resubmission). The in-flight
    // and accepted states were already handled above, so only frozen states can throw here.
    try assertTransition(evidence.state, .inFlight)
    evidence.state = .inFlight
    evidence.updatedAt = stamp()
    deps.evidenceStore.save(evidence)

    let outcome: HubSubmitOutcome
    do {
        outcome = try await deps.submitter.submitFieldTicket(evidence.envelope.payload)
    } catch {
        // The Hub client never throws for expected conditions, but the submitter seam can still
        // reject (keychain failure resolving the token, a wrapper bug). Without this catch the
        // evidence would be stranded in-flight — deadlocking the double-submit guard until the
        // next restart sweep. Map the throw to the transient arm: pending, retryable, same key.
        try assertTransition(evidence.state, .pending)
        deps.evidenceStore.save(
            withOutcome(
                evidence, state: .pending, at: stamp(), attemptsDelta: 1,
                detail: String(describing: error), transientReason: "client-error"
            )
        )
        return .pendingRetry(reason: "client-error", idempotencyKey: idempotencyKey)
    }

    // Exhaustive over HubSubmitOutcome's cases (cross-cutting #2): an unknown wire outcome cannot
    // be constructed as a real Swift enum case, so — unlike the TS `default: throw` — there is no
    // unreachable branch to port here.
    switch outcome {
    case .accepted(let duplicate, let snapshotDrift, _):
        try assertTransition(evidence.state, .accepted)
        deps.evidenceStore.save(withOutcome(evidence, state: .accepted, at: stamp()))
        return .accepted(
            duplicate: duplicate,
            snapshotDrift: snapshotDrift == true ? true : nil,
            idempotencyKey: idempotencyKey
        )
    case .transient(let reason, let httpStatus, let detail):
        try assertTransition(evidence.state, .pending)
        deps.evidenceStore.save(
            withOutcome(
                evidence, state: .pending, at: stamp(), attemptsDelta: 1,
                detail: detail, httpStatus: httpStatus, transientReason: reason.rawValue
            )
        )
        return .pendingRetry(reason: reason.rawValue, idempotencyKey: idempotencyKey)
    case .authFailed(let httpStatus):
        try assertTransition(evidence.state, .pending)
        deps.evidenceStore.save(
            withOutcome(
                evidence, state: .pending, at: stamp(), attemptsDelta: 1,
                httpStatus: httpStatus, transientReason: "auth-failed"
            )
        )
        return .authRequired(idempotencyKey: idempotencyKey)
    case .rejected(let kind, let httpStatus, let rejectionCode, let detail):
        if kind == .blocked {
            // Retryable after the user acts (clock in / wait out the in-progress original). The
            // rejection code on the evidence marks it user-action-gated: the background retry
            // engine must NOT auto-redispatch it (spec: never auto-retry 403/409).
            try assertTransition(evidence.state, .pending)
            deps.evidenceStore.save(
                withOutcome(
                    evidence, state: .pending, at: stamp(), attemptsDelta: 1,
                    rejectionCode: rejectionCode, detail: detail, httpStatus: httpStatus
                )
            )
            return .blocked(
                rejectionCode: rejectionCode, httpStatus: httpStatus, detail: detail, idempotencyKey: idempotencyKey)
        }
        // needs-review: freeze the evidence for manual resolution; never auto-resubmit.
        try assertTransition(evidence.state, .needsReview)
        deps.evidenceStore.save(
            withOutcome(
                evidence, state: .needsReview, at: stamp(),
                rejectionCode: rejectionCode, detail: detail, httpStatus: httpStatus
            )
        )
        return .needsReview(
            rejectionCode: rejectionCode, httpStatus: httpStatus, detail: detail, idempotencyKey: idempotencyKey)
    }
}
