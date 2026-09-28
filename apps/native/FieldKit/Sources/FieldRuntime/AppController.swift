// Port of src/runtime/appController.ts — Composition-root controller: the one object screens talk
// to. Wires auth (token production), the durable stores, the Hub client, restart recovery, and the
// retry engine — while keeping every Hub truth question (clock gate, assignment, accept/reject)
// answered by Hub alone.
//
// Ordering invariant (spec req: restart recovery): `start()` sweeps orphaned in-flight evidence
// BEFORE the retry engine runs and before any submit can execute.
//
// Token discipline: every Hub call resolves the session first (`getValidSession` — refreshes when
// expiring). No valid session → the call resolves to a locked/auth state, never a hang and never a
// guess.
//
// ponytail: the TS single-flight session check is `this.sessionCheck ??= getValidSession(...).finally(...)`
// — a plain promise memoized on a mutable field, safe only because JS is single-threaded. Swift has
// real concurrency, so this is ported as a reentrant `actor` (`SessionCheckBox`) holding the
// in-flight `Task` instead: concurrent callers still await the ONE underlying call, but the
// invariant is enforced by the language, not by hoping nothing interleaves.
import Foundation
import FieldContracts
import FieldDomain

public struct TicketDraft: Sendable {
    public var serviceRequestId: String
    public var ticketNo: String
    public var quantityBbl: Double
    public var disposalTicketNo: String
    /// Full paper-ticket detail (gauges, times, rig #, line items); rides along additively.
    public var detail: FieldTicketDetail?

    public init(
        serviceRequestId: String, ticketNo: String, quantityBbl: Double, disposalTicketNo: String,
        detail: FieldTicketDetail? = nil
    ) {
        self.serviceRequestId = serviceRequestId
        self.ticketNo = ticketNo
        self.quantityBbl = quantityBbl
        self.disposalTicketNo = disposalTicketNo
        self.detail = detail
    }
}

public enum ControllerSubmitResult: Equatable, Sendable {
    case accepted(duplicate: Bool, snapshotDrift: Bool?, idempotencyKey: String)
    case blocked(rejectionCode: String, httpStatus: Int, detail: String?, idempotencyKey: String)
    case needsReview(rejectionCode: String, httpStatus: Int, detail: String?, idempotencyKey: String)
    case pendingRetry(reason: String, idempotencyKey: String)
    case authRequired(idempotencyKey: String)
    case notSubmitted(reason: SubmitFieldTicketResult.NotSubmittedReason, idempotencyKey: String)
    case notSignedIn
    /// No cached assignment (and therefore no snapshot_hash) for this SR — submit refused.
    case assignmentMissing(serviceRequestId: String)
    /// resubmitEvidence was asked for a key that has no stored evidence.
    case evidenceMissing(idempotencyKey: String)
}

private extension SubmitFieldTicketResult {
    var asControllerResult: ControllerSubmitResult {
        switch self {
        case .accepted(let duplicate, let snapshotDrift, let key):
            return .accepted(duplicate: duplicate, snapshotDrift: snapshotDrift, idempotencyKey: key)
        case .blocked(let code, let status, let detail, let key):
            return .blocked(rejectionCode: code, httpStatus: status, detail: detail, idempotencyKey: key)
        case .needsReview(let code, let status, let detail, let key):
            return .needsReview(rejectionCode: code, httpStatus: status, detail: detail, idempotencyKey: key)
        case .pendingRetry(let reason, let key):
            return .pendingRetry(reason: reason, idempotencyKey: key)
        case .authRequired(let key):
            return .authRequired(idempotencyKey: key)
        case .notSubmitted(let reason, let key):
            return .notSubmitted(reason: reason, idempotencyKey: key)
        }
    }
}

public typealias HubClient = SessionStatusSource & AssignmentSource & FieldTicketSubmitter

/// Mirrors the TS inline `identity` shape on `AppControllerDeps` — distinct from `WriteIdentity`
/// (no `generateUuid`; the controller carries that separately as its own top-level dep, matching
/// the original object shape).
public struct AppControllerIdentity {
    public var ensureDeviceInstanceId: (() -> String) -> String
    public var allocateLocalSeq: () -> Int

    public init(ensureDeviceInstanceId: @escaping (() -> String) -> String, allocateLocalSeq: @escaping () -> Int) {
        self.ensureDeviceInstanceId = ensureDeviceInstanceId
        self.allocateLocalSeq = allocateLocalSeq
    }
}

public struct AppControllerDeps {
    public var evidenceStore: TicketEvidenceStore
    public var assignmentStore: AssignmentStore
    public var tokenStore: TokenStore
    public var authApi: AuthApi
    /// The ADR-004 V2 sync engine to drive in the background. `nil`: no sync runner is created and
    /// the controller behaves exactly as before.
    public var syncEngine: SyncEngine?
    /// The ADR-004 blob-upload engine to drive in the background. `nil`: no upload runner is
    /// created (uploads then run only via an explicit processOnce caller).
    ///
    /// ponytail: typed as the `UploadProcessing` seam (not the concrete `UploadEngine`) — mirrors
    /// the TS test suite substituting a bare `{processOnce, purgeOnce}` fake for the real engine
    /// (`as unknown as UploadEngine`); Swift has no structural-typing escape hatch, so the seam
    /// itself is the protocol `UploadRunner` already depends on. Any real `UploadEngine` conforms.
    public var uploadEngine: UploadProcessing?
    /// Durable 24h offline-policy baseline; optional for tests/legacy composition roots.
    public var offlinePolicyStore: OfflinePolicyStore?
    /// Build a Hub client bound to a live session token (tokens rotate; clients are cheap).
    public var hubClientFor: (String) -> HubClient
    public var identity: AppControllerIdentity
    public var generateUuid: () -> String
    public var now: (() -> Date)?
    public var random: (() -> Double)?
    public var setTimer: ((@escaping () -> Void, Int) -> Any)?
    public var clearTimer: ((Any) -> Void)?
    /// Surfaced when background retries need a re-login (engine is paused meanwhile).
    public var onAuthRequired: (() -> Void)?
    /// Telemetry hook for contained sweep errors (the retry loop continues regardless).
    public var onSweepError: ((String, Error) -> Void)?
    /// Telemetry for contained V2 SyncRunner/UploadRunner errors; the loops continue regardless.
    public var onSyncError: ((String, Error) -> Void)?
    /// Override the V2 sync driver polling cadence (ms). Defaults to the SyncRunner default (60s).
    public var syncIntervalMs: Int?

    public init(
        evidenceStore: TicketEvidenceStore, assignmentStore: AssignmentStore, tokenStore: TokenStore,
        authApi: AuthApi, syncEngine: SyncEngine? = nil, uploadEngine: UploadProcessing? = nil,
        offlinePolicyStore: OfflinePolicyStore? = nil, hubClientFor: @escaping (String) -> HubClient,
        identity: AppControllerIdentity, generateUuid: @escaping () -> String, now: (() -> Date)? = nil,
        random: (() -> Double)? = nil, setTimer: ((@escaping () -> Void, Int) -> Any)? = nil,
        clearTimer: ((Any) -> Void)? = nil, onAuthRequired: (() -> Void)? = nil,
        onSweepError: ((String, Error) -> Void)? = nil, onSyncError: ((String, Error) -> Void)? = nil,
        syncIntervalMs: Int? = nil
    ) {
        self.evidenceStore = evidenceStore
        self.assignmentStore = assignmentStore
        self.tokenStore = tokenStore
        self.authApi = authApi
        self.syncEngine = syncEngine
        self.uploadEngine = uploadEngine
        self.offlinePolicyStore = offlinePolicyStore
        self.hubClientFor = hubClientFor
        self.identity = identity
        self.generateUuid = generateUuid
        self.now = now
        self.random = random
        self.setTimer = setTimer
        self.clearTimer = clearTimer
        self.onAuthRequired = onAuthRequired
        self.onSweepError = onSweepError
        self.onSyncError = onSyncError
        self.syncIntervalMs = syncIntervalMs
    }
}

private struct ClosureFieldTicketSubmitter: FieldTicketSubmitter {
    let submit: (HubFieldTicketSubmission) async throws -> HubSubmitOutcome
    func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        try await submit(submission)
    }
}

/// Single-flight session resolution: concurrent Hub calls share ONE `getValidSession` call (and
/// therefore at most one refresh — no refresh storms, no stale-rejection-clears-fresh-token races).
/// Reentrant by construction (an `actor` suspended mid-await still services new calls), which is
/// exactly what makes the de-duplication work: a second caller arriving while the first still
/// awaits the in-flight task's result sees it already recorded and awaits the SAME task.
private actor SessionCheckBox {
    private var inFlight: Task<SessionState, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> SessionState) async throws -> SessionState {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

private struct TicketSubmissionKey: Hashable, Sendable {
    let serviceRequestId: String
    let ticketNo: String
}

/// Coalesces concurrent taps for the same logical ticket before either caller can allocate write
/// identity. `submitFieldTicket` persists evidence before network I/O, so this in-process gate only
/// needs to cover the pre-evidence awaits; crash recovery remains entirely store-driven.
private actor TicketSubmissionBox {
    private var inFlight: [TicketSubmissionKey: Task<ControllerSubmitResult, Error>] = [:]

    func run(
        _ key: TicketSubmissionKey,
        operation: @escaping @Sendable () async throws -> ControllerSubmitResult
    ) async throws -> ControllerSubmitResult {
        if let inFlight = inFlight[key] { return try await inFlight.value }

        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// Back-reference so the retry engine's submitter (built before `self` is fully initialized) can
/// reach the controller once it exists, without capturing `self` mid-`init`.
private final class ControllerBackref {
    weak var controller: AppController?
}

public final class AppController: @unchecked Sendable {
    private let deps: AppControllerDeps
    public let retryEngine: RetryEngine
    private let syncRunner: SyncRunner?
    private let uploadRunner: UploadRunner?
    private let lifecycleLock = NSLock()
    private var started = false
    private let sessionCheckBox = SessionCheckBox()
    private let ticketSubmissionBox = TicketSubmissionBox()

    public init(_ deps: AppControllerDeps) {
        self.deps = deps
        let backref = ControllerBackref()
        // The engine's submitter resolves the CURRENT session per dispatch — a token refreshed
        // mid-queue is picked up automatically; a dead session pauses the engine via auth-failed.
        let submitter = ClosureFieldTicketSubmitter { submission in
            guard let controller = backref.controller else {
                return .transient(reason: .network, httpStatus: nil, detail: "controller deallocated")
            }
            let session = try await controller.getSession()
            switch session {
            case .authRequired:
                return .authFailed(httpStatus: 401)
            case .unavailable(let reason):
                return .transient(reason: .network, httpStatus: nil, detail: reason)
            case .valid(let s):
                return try await deps.hubClientFor(s.sessionToken).submitFieldTicket(submission)
            }
        }
        self.retryEngine = RetryEngine(
            RetryEngineDeps(
                evidenceStore: deps.evidenceStore, submitter: submitter, now: deps.now, random: deps.random,
                setTimer: deps.setTimer, clearTimer: deps.clearTimer, onAuthRequired: deps.onAuthRequired,
                onSweepError: deps.onSweepError))
        // The V2 sync driver mirrors the RetryEngine lifecycle: same injected timers, same
        // pause-on-auth / resume-on-refresh hooks (wired in start/stop/getSession/login below).
        if let syncEngine = deps.syncEngine {
            self.syncRunner = SyncRunner(
                SyncRunnerDeps(
                    syncEngine: syncEngine, intervalMs: deps.syncIntervalMs, setTimer: deps.setTimer,
                    clearTimer: deps.clearTimer, onAuthRequired: deps.onAuthRequired, onSyncError: deps.onSyncError))
        } else {
            self.syncRunner = nil
        }
        // The blob-upload driver: same lifecycle + auth pause/resume as the sync driver.
        if let uploadEngine = deps.uploadEngine {
            self.uploadRunner = UploadRunner(
                UploadRunnerDeps(
                    uploadEngine: uploadEngine, intervalMs: deps.syncIntervalMs, setTimer: deps.setTimer,
                    clearTimer: deps.clearTimer, onAuthRequired: deps.onAuthRequired, onSyncError: deps.onSyncError))
        } else {
            self.uploadRunner = nil
        }
        backref.controller = self
    }

    private func authDeps() -> AuthDeps {
        AuthDeps(api: deps.authApi, tokenStore: deps.tokenStore, now: deps.now)
    }

    private func recordHubContact(_ at: Date? = nil) {
        let at = at ?? (deps.now?() ?? Date())
        deps.offlinePolicyStore?.recordHubContact(Int64(at.timeIntervalSince1970 * 1000))
    }

    /// Observing a valid session also resumes a retry engine paused for auth, so queued work
    /// recovers after a SILENT token refresh, not only after an interactive login.
    fileprivate func getSession() async throws -> SessionState {
        let state = try await sessionCheckBox.run { [self] in try await getValidSession(authDeps()) }
        if case .valid = state {
            // The one place a silent token refresh is observed — resume every engine that may be
            // paused for auth (V1 ticket retries, the V2 sync driver, and the upload driver).
            if retryEngine.isPausedForAuth() { retryEngine.resumeAfterAuth() }
            if let syncRunner, syncRunner.isPausedForAuth() { syncRunner.resumeAfterAuth() }
            if let uploadRunner, uploadRunner.isPausedForAuth() { uploadRunner.resumeAfterAuth() }
        }
        return state
    }

    /// Fresh bearer for the ADR-004 V2 sync transport's per-request token provider. Reuses the
    /// single-flight `getSession()` so the sync engine shares the SAME refresh as every other Hub
    /// call. THROWS when no token is available so the SyncEngine treats the batch as a transient
    /// failure — work stays queued, never dropped: auth-required -> HubAuthError (engine pauses for
    /// re-auth); offline/unavailable -> HubNetworkError (engine retries with backoff).
    public func getSyncSessionToken() async throws -> String {
        let session = try await getSession()
        switch session {
        case .valid(let s):
            return s.sessionToken
        case .authRequired(let reason):
            throw HubAuthError("sync session token unavailable: \(reason.rawValue)", httpStatus: 401)
        case .unavailable(let reason):
            throw HubNetworkError("sync session token unavailable: \(reason)")
        }
    }

    /// Submitter for a resolved session (`.valid` or `.unavailable` only — callers check
    /// `.authRequired` first): live client, or a durable offline fallback.
    private func submitterFor(_ session: SessionState) -> FieldTicketSubmitter {
        if case .valid(let s) = session {
            return deps.hubClientFor(s.sessionToken)
        }
        // Session refresh unavailable (offline): record the evidence locally as a transient failure
        // so the work is durable NOW and retries when connectivity returns.
        var reason = ""
        if case .unavailable(let r) = session { reason = r }
        return ClosureFieldTicketSubmitter { _ in .transient(reason: .network, httpStatus: nil, detail: reason) }
    }

    /// Boot: restart-recovery sweep FIRST, then the retry engine. Idempotent.
    @discardableResult
    public func start() throws -> EvidenceRecovery {
        lifecycleLock.lock()
        let shouldStart = !started
        started = true
        lifecycleLock.unlock()
        guard shouldStart else { return EvidenceRecovery(recoveredKeys: []) }

        do {
            let recovery = recoverEvidenceOnStartup(deps.evidenceStore, deps.now ?? { Date() })
            // Recover orphaned in-flight V2 outbox rows (same idempotency-key replay safety as V1)
            // before starting any driver. A storage failure leaves startup retryable and prevents a
            // runner from observing a partially recovered outbox.
            _ = try deps.syncEngine?.recoverOnStartup()
            retryEngine.start()
            syncRunner?.start()
            uploadRunner?.start()
            return recovery
        } catch {
            lifecycleLock.lock()
            started = false
            lifecycleLock.unlock()
            throw error
        }
    }

    public func stop() {
        retryEngine.stop()
        syncRunner?.stop()
        uploadRunner?.stop()
    }

    /// Kick the background sync driver to run a sweep now — used both when fresh V2 evidence is
    /// enqueued and when the app returns to the foreground. No-op when there is no runner wired, or
    /// while the runner is paused for auth (a dead token is never hammered).
    public func notifyQueuedSync() {
        syncRunner?.notifyQueued()
    }

    /// Kick the background upload driver to run a sweep now — used when a fresh blob is registered
    /// (kick-on-capture). No-op when there is no runner wired, or while it is paused for auth.
    public func notifyQueuedUpload() {
        uploadRunner?.notifyQueued()
    }

    /// The app returned to the foreground. Re-validate the session FIRST: a silent refresh observed
    /// here resumes any runner that paused for auth while backgrounded. Then kick the sync + upload
    /// drivers so a still-valid session drains promptly. Best-effort: a failed refresh leaves the
    /// runners paused (correct).
    public func onForeground() async throws {
        let session = try await getSession()
        if case .valid = session {
            notifyQueuedSync()
            notifyQueuedUpload()
        }
    }

    public func login(_ credentials: AuthCredentials) async throws -> LoginResult {
        let result = try await FieldDomain.login(authDeps(), credentials: credentials)
        if case .signedIn = result {
            recordHubContact()
            retryEngine.resumeAfterAuth()  // queued work held back by a dead token can go now
            syncRunner?.resumeAfterAuth()
            uploadRunner?.resumeAfterAuth()
        }
        return result
    }

    public func currentUserProfile() async throws -> UserProfile? {
        (try await deps.tokenStore.load())?.userProfile
    }

    /// Sign out. Unsynced evidence stays in the durable store for the next sign-in.
    public func logout() async throws {
        try await FieldDomain.logout(authDeps())
    }

    /// One refresh cycle: clock gate, then assignments (only when unlocked). Without a valid
    /// session this resolves to locked(auth-failed) — a state, not a spinner, not a throw.
    public func refreshSession() async throws -> FieldSessionResult {
        let session = try await getSession()
        switch session {
        case .authRequired(let reason):
            return FieldSessionResult(
                gate: .locked(reason: .authFailed, detail: "sign in (\(reason.rawValue))"),
                assignments: .notPulled)
        case .unavailable(let reason):
            return FieldSessionResult(gate: .locked(reason: .hubUnreachable, detail: reason), assignments: .notPulled)
        case .valid(let s):
            let client = deps.hubClientFor(s.sessionToken)
            let result = try await refreshFieldSession(
                statusSource: client, assignmentSource: client, store: deps.assignmentStore)
            if isUnlockedOrNotClockedIn(result.gate) { recordHubContact() }
            return result
        }
    }

    /// The current gate alone (no assignment pull) — for cheap re-checks.
    public func checkGate() async throws -> FieldWorkGate {
        let session = try await getSession()
        switch session {
        case .authRequired(let reason):
            return .locked(reason: .authFailed, detail: "sign in (\(reason.rawValue))")
        case .unavailable(let reason):
            return .locked(reason: .hubUnreachable, detail: reason)
        case .valid(let s):
            let gate = try await evaluateClockGate(deps.hubClientFor(s.sessionToken))
            if isUnlockedOrNotClockedIn(gate) { recordHubContact() }
            return gate
        }
    }

    private func isUnlockedOrNotClockedIn(_ gate: FieldWorkGate) -> Bool {
        switch gate {
        case .unlocked: return true
        case .locked(let reason, _): return reason == .notClockedIn
        }
    }

    public func offlinePolicy(_ now: Date? = nil) -> OfflinePolicy? {
        guard let state = deps.offlinePolicyStore?.getState() else { return nil }
        let nowDate = now ?? (deps.now?() ?? Date())
        return evaluateOfflinePolicy(
            OfflinePolicyInput(
                lastHubContactAtMs: state.lastHubContactAtMs, nowMs: Int64(nowDate.timeIntervalSince1970 * 1000),
                windowHours: state.windowHours))
    }

    /// Submit a new field ticket. The snapshot hash is resolved from the cached assignment — a
    /// missing assignment (no hash) REFUSES the submit (spec req 7: the hash is the only drift
    /// protection). Write identity (device id + local_seq) is allocated durably — but ONLY for a
    /// genuinely new draft: if evidence already exists for the same (SR, ticketNo), it is
    /// resubmitted with its ORIGINAL idempotency key. A double-tap or user-initiated retry must
    /// never mint a second key for the same ticket — Hub would create a duplicate.
    public func submitNewTicket(_ draft: TicketDraft) async throws -> ControllerSubmitResult {
        let key = TicketSubmissionKey(serviceRequestId: draft.serviceRequestId, ticketNo: draft.ticketNo)
        return try await ticketSubmissionBox.run(key) { [self] in
            try await performSubmitNewTicket(draft)
        }
    }

    private func performSubmitNewTicket(_ draft: TicketDraft) async throws -> ControllerSubmitResult {
        if let existing = deps.evidenceStore.list().first(where: {
            $0.envelope.payload.serviceRequestId == draft.serviceRequestId
                && $0.envelope.payload.ticketNo == draft.ticketNo
        }) {
            return try await resubmitEvidence(existing.envelope.idempotencyKey)
        }

        let session = try await getSession()
        if case .authRequired = session { return .notSignedIn }
        guard let snapshotHash = deps.assignmentStore.getSnapshotHash(draft.serviceRequestId),
            !snapshotHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .assignmentMissing(serviceRequestId: draft.serviceRequestId)
        }
        let deviceInstanceId = deps.identity.ensureDeviceInstanceId(deps.generateUuid)
        let localSeq = deps.identity.allocateLocalSeq()
        let opUuid = deps.generateUuid()

        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: submitterFor(session), evidenceStore: deps.evidenceStore, now: deps.now),
            FieldTicketInput(
                serviceRequestId: draft.serviceRequestId, snapshotHash: snapshotHash, ticketNo: draft.ticketNo,
                quantityBbl: draft.quantityBbl, disposalTicketNo: draft.disposalTicketNo,
                deviceInstanceId: deviceInstanceId, localSeq: localSeq, opUuid: opUuid, detail: draft.detail))
        if case .pendingRetry = result { retryEngine.notifyQueued() }
        return result.asControllerResult
    }

    /// Resubmit existing evidence with its ORIGINAL idempotency key — the manual retry path for
    /// blocked (403/409) rows after the user acts, and the dedupe target for repeated submits of
    /// the same draft. Frozen rows (needs-review / rejected) are NOT resubmitted: their stored
    /// status is returned instead, preserving the manual-review discipline.
    public func resubmitEvidence(_ idempotencyKey: String) async throws -> ControllerSubmitResult {
        guard let evidence = deps.evidenceStore.get(idempotencyKey) else {
            return .evidenceMissing(idempotencyKey: idempotencyKey)
        }
        if evidence.state == .needsReview || evidence.state == .rejected {
            return .needsReview(
                rejectionCode: evidence.lastRejectionCode ?? "frozen", httpStatus: evidence.lastHttpStatus ?? 0,
                detail: evidence.lastDetail, idempotencyKey: idempotencyKey)
        }
        let session = try await getSession()
        if case .authRequired = session { return .notSignedIn }
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: submitterFor(session), evidenceStore: deps.evidenceStore, now: deps.now),
            try inputFromEvidence(evidence))
        if case .pendingRetry = result { retryEngine.notifyQueued() }
        return result.asControllerResult
    }

    /// Per-SR rollup of ticket-submit work for the inbox / Today read path (spec 7.5) — DISPLAY-ONLY,
    /// derived from the SAME durable evidence store as outboxSummary(). It never triggers a refetch
    /// and never mutates anything. SRs with no local ticket work are simply absent from the map (the
    /// screen defaults them to 'no-local-work').
    public func srSyncStateById() -> [String: SrSyncState] {
        perSrSyncState(
            deps.evidenceStore.list().map {
                SrSyncItem(serviceRequestId: $0.envelope.payload.serviceRequestId, state: $0.state)
            })
    }

    /// Sync Center rollup (spec 7.15) across local drafts (`draftCount` — ticket + receipt drafts,
    /// counted by the caller) and the durable ticket-submit evidence. Honest by construction: only
    /// Hub-accepted rows land in 'accepted-by-hub'. Form/blob/print events fold in as those outboxes
    /// gain per-SR attribution.
    public func syncCenterSummary(_ draftCount: Int) -> SyncCenterSummary {
        summarizeSyncCenter(
            SyncCenterInput(
                draftCount: draftCount,
                evidence: deps.evidenceStore.list().map {
                    SyncCenterEvidence(state: $0.state, lastRejectionCode: $0.lastRejectionCode)
                }))
    }

    public struct OutboxSummary: Equatable, Sendable {
        public var pending: Int
        public var blocked: Int
        public var needsReview: Int
        public var accepted: Int
        public var inFlight: Int
    }

    /// Outbox counts for the UI — pending/blocked/review/accepted, never a spinner.
    public func outboxSummary() -> OutboxSummary {
        let items = deps.evidenceStore.list()
        return OutboxSummary(
            pending: items.filter { $0.state == .pending && $0.lastRejectionCode == nil }.count,
            blocked: items.filter { $0.state == .pending && $0.lastRejectionCode != nil }.count,
            needsReview: items.filter { $0.state == .needsReview }.count,
            accepted: items.filter { $0.state == .accepted }.count,
            inFlight: items.filter { $0.state == .inFlight }.count)
    }
}
