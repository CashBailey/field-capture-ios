// Port of src/runtime/retryEngine.ts — Background retry engine (spec req: retry loop + exponential
// backoff).
//
// What it auto-retries — ONLY transient failures (network / 5xx / 429), i.e. pending evidence with
// no rejection code, once its full-jitter backoff window has elapsed.
//
// What it must NEVER auto-retry:
//  - 403/409 "blocked" rows: pending but carrying `lastRejectionCode` — user-action-gated (clock in
//    / wait out the in-progress original). A manual resubmission clears the code on its next
//    outcome.
//  - 412/422 "needs-review" and `rejected` rows: terminal, frozen for manual review (the contracts
//    state machine throws on any transition out of them).
//  - `auth-failed` rows: the engine PAUSES instead — hammering Hub with a dead token converts one
//    failure into N. `resumeAfterAuth()` restarts it once a fresh token exists.
//
// All time and randomness are injected so the schedule is deterministic under test.
import Foundation
import FieldContracts
import FieldDomain

/// Reconstruct the original submit input from the durable envelope (identity included).
public func inputFromEvidence(_ evidence: TicketEvidence) throws -> FieldTicketInput {
    let identity = try parseIdempotencyKey(evidence.envelope.idempotencyKey)
    let payload = evidence.envelope.payload
    return FieldTicketInput(
        serviceRequestId: payload.serviceRequestId,
        snapshotHash: payload.snapshotHash,
        ticketNo: payload.ticketNo,
        quantityBbl: payload.quantityBbl,
        disposalTicketNo: payload.disposalTicketNo,
        deviceInstanceId: identity.deviceInstanceId,
        localSeq: identity.localSeq,
        opUuid: identity.opUuid,
        detail: payload.detail
    )
}

/// Pending, not user-action-gated, not waiting on re-auth. (Due-ness is checked separately.)
public func isAutoRetryable(_ evidence: TicketEvidence) -> Bool {
    evidence.state == .pending
        && evidence.lastRejectionCode == nil
        && evidence.lastTransientReason != "auth-failed"
}

public struct SweepReport: Equatable, Sendable {
    public var attempted: Int = 0
    public var accepted: Int = 0
    /// Still pending on a transient failure — rescheduled with backoff.
    public var rescheduled: Int = 0
    /// Pending but user-action-gated (blocked rejection) or not yet due — left alone.
    public var skipped: Int = 0
    /// True when the sweep hit an auth failure and the engine paused.
    public var pausedForAuth: Bool = false
}

public struct RetryEngineDeps {
    public var evidenceStore: TicketEvidenceStore
    public var submitter: FieldTicketSubmitter
    public var policy: RetryPolicy?
    public var now: (() -> Date)?
    public var random: (() -> Double)?
    /// `(fn, ms) -> handle`. Defaults to a `Task.sleep`-based timer in production.
    public var setTimer: ((@escaping () -> Void, Int) -> Any)?
    public var clearTimer: ((Any) -> Void)?
    /// Fired when a retry hit a 401 — the auth slice should refresh/re-login, then resume.
    public var onAuthRequired: (() -> Void)?
    /// Fired when a sweep or one row's dispatch threw (telemetry); the loop continues either way.
    public var onSweepError: ((String, Error) -> Void)?

    public init(
        evidenceStore: TicketEvidenceStore,
        submitter: FieldTicketSubmitter,
        policy: RetryPolicy? = nil,
        now: (() -> Date)? = nil,
        random: (() -> Double)? = nil,
        setTimer: ((@escaping () -> Void, Int) -> Any)? = nil,
        clearTimer: ((Any) -> Void)? = nil,
        onAuthRequired: (() -> Void)? = nil,
        onSweepError: ((String, Error) -> Void)? = nil
    ) {
        self.evidenceStore = evidenceStore
        self.submitter = submitter
        self.policy = policy
        self.now = now
        self.random = random
        self.setTimer = setTimer
        self.clearTimer = clearTimer
        self.onAuthRequired = onAuthRequired
        self.onSweepError = onSweepError
    }
}

private actor RetrySweepGate {
    private var inFlight: Task<SweepReport, Never>?

    func run(_ operation: @escaping @Sendable () async -> SweepReport) async -> SweepReport {
        if let inFlight { return await inFlight.value }

        let task = Task { await operation() }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }
}

public final class RetryEngine: @unchecked Sendable {
    private let deps: RetryEngineDeps
    private let policy: RetryPolicy
    private let now: () -> Date
    private let random: () -> Double
    private let setTimer: (@escaping () -> Void, Int) -> Any
    private let clearTimer: (Any) -> Void
    private let stateLock = NSLock()
    private let sweepGate = RetrySweepGate()

    private var running = false
    private var pausedForAuth = false
    private var sweeping = false
    private var resweepRequested = false
    private var timer: Any?

    public init(_ deps: RetryEngineDeps) {
        self.deps = deps
        self.policy = deps.policy ?? DEFAULT_RETRY_POLICY
        self.now = deps.now ?? { Date() }
        self.random = deps.random ?? { Double.random(in: 0..<1) }
        self.setTimer = deps.setTimer ?? RuntimeDefaultTimer.setTimer
        self.clearTimer = deps.clearTimer ?? RuntimeDefaultTimer.clearTimer
    }

    public func start() {
        let shouldStart = withStateLock {
            guard !running else { return false }
            running = true
            pausedForAuth = false
            return true
        }
        guard shouldStart else { return }

        // Rows gated 'auth-failed' in a previous run must not starve forever: the token situation
        // may have changed across the restart, so they get one fresh chance now. A still-dead
        // token re-pauses the engine on the first dispatch.
        _ = clearAuthGates()
        if withStateLock({ running }) { launchSweep() }
    }

    public func stop() {
        withStateLock {
            running = false
            resweepRequested = false
        }
        cancelTimer()
    }

    /// True while the engine is holding off because a dispatch hit a 401.
    public func isPausedForAuth() -> Bool {
        withStateLock { pausedForAuth }
    }

    /// Call whenever a valid session is (re)established — interactive login OR a silent refresh
    /// observed elsewhere. Idempotent and cheap when there is nothing to resume.
    public func resumeAfterAuth() {
        guard withStateLock({ running }) else { return }
        let hadGates = clearAuthGates()
        let shouldResume = withStateLock {
            guard running, pausedForAuth || hadGates else { return false }
            pausedForAuth = false
            return true
        }
        if shouldResume { launchSweep() }
    }

    /// Un-gate pending rows whose last failure was auth. Returns whether any row was un-gated.
    @discardableResult
    private func clearAuthGates() -> Bool {
        var cleared = false
        for evidence in deps.evidenceStore.list() {
            if evidence.state == .pending && evidence.lastTransientReason == "auth-failed" {
                var next = evidence
                next.lastTransientReason = nil
                next.updatedAt = isoStamp(now())
                deps.evidenceStore.save(next)
                cleared = true
            }
        }
        return cleared
    }

    /// One pass: submit every due auto-retryable row, reschedule transients with backoff, pause on
    /// auth failure. Public for tests and for a user-facing "sync now" action.
    @discardableResult
    public func sweepOnce() async -> SweepReport {
        await sweepGate.run { [self] in await performSweepOnce() }
    }

    private func performSweepOnce() async -> SweepReport {
        var report = SweepReport()
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        for evidence in deps.evidenceStore.list() {
            guard evidence.state == .pending else { continue }
            guard isAutoRetryable(evidence) else {
                report.skipped += 1
                continue
            }
            if let due = evidence.nextAttemptAtMs, due > nowMs {
                report.skipped += 1
                continue
            }
            report.attempted += 1
            let result: SubmitFieldTicketResult
            do {
                result = try await dispatch(evidence)
            } catch {
                // submitFieldTicket contains submitter throws itself; this guards the residue (a
                // store write failing, a frozen row mutated mid-sweep). One bad row must never kill
                // the sweep for the healthy rows behind it.
                report.skipped += 1
                deps.onSweepError?(evidence.envelope.idempotencyKey, error)
                continue
            }
            switch result {
            case .accepted:
                report.accepted += 1
            case .pendingRetry:
                report.rescheduled += 1
            case .authRequired:
                withStateLock { pausedForAuth = true }
                report.pausedForAuth = true
                deps.onAuthRequired?()
                return report  // a dead token fails every row identically — stop the pass
            case .blocked, .needsReview, .notSubmitted:
                // submitFieldTicket already recorded the outcome; nothing to do.
                break
            }
        }
        return report
    }

    private func dispatch(_ evidence: TicketEvidence) async throws -> SubmitFieldTicketResult {
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: deps.submitter, evidenceStore: deps.evidenceStore, now: now),
            try inputFromEvidence(evidence)
        )
        if case .pendingRetry = result {
            // Stamp the next attempt time with full-jitter exponential backoff. Re-read the row:
            // submitFieldTicket just rewrote it (attempts, failure detail).
            if let fresh = deps.evidenceStore.get(evidence.envelope.idempotencyKey), fresh.state == .pending {
                let retryCount = max(0, fresh.attempts - 1)
                var next = fresh
                next.nextAttemptAtMs = try computeNextAttemptAtMs(
                    Int64(now().timeIntervalSince1970 * 1000), retryCount, random, policy)
                deps.evidenceStore.save(next)
            }
        }
        return result
    }

    private func runSweep() async {
        let shouldRun = withStateLock {
            guard running, !pausedForAuth else { return false }
            if sweeping {
                // A sweep is in progress; run another full pass when it finishes (e.g. resumeAfterAuth
                // landed mid-sweep) instead of silently dropping the request.
                resweepRequested = true
                return false
            }
            sweeping = true
            return true
        }
        guard shouldRun else { return }

        _ = await sweepOnce()
        let shouldResweep = withStateLock {
            sweeping = false
            guard running, !pausedForAuth else {
                resweepRequested = false
                return false
            }
            guard resweepRequested else { return false }
            resweepRequested = false
            return true
        }
        if shouldResweep {
            await runSweep()
            return
        }
        scheduleNext()
    }

    private func scheduleNext() {
        cancelTimer()
        guard withStateLock({ running && !pausedForAuth }) else { return }
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        var nextDueMs: Int64?
        for evidence in deps.evidenceStore.list() {
            guard isAutoRetryable(evidence) else { continue }
            let due = evidence.nextAttemptAtMs ?? nowMs
            if nextDueMs == nil || due < nextDueMs! { nextDueMs = due }
        }
        guard let nextDueMs else { return }  // queue drained — start() or an enqueue re-arms
        let delay = max(1_000, Int(nextDueMs - nowMs))  // floor: never busy-spin
        let nextTimer = setTimer({ [weak self] in self?.launchSweep() }, delay)
        let keptTimer = withStateLock {
            guard running, !pausedForAuth, timer == nil else { return false }
            timer = nextTimer
            return true
        }
        if !keptTimer { clearTimer(nextTimer) }
    }

    /// Re-arm after new work enters the queue (e.g. a fresh submit failed while offline).
    public func notifyQueued() {
        let shouldSchedule = withStateLock { running && !pausedForAuth && !sweeping }
        if shouldSchedule { scheduleNext() }
    }

    private func cancelTimer() {
        let currentTimer = withStateLock {
            defer { timer = nil }
            return timer
        }
        if let currentTimer { clearTimer(currentTimer) }
    }

    private func launchSweep() {
        Task { [weak self] in await self?.runSweep() }
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}
