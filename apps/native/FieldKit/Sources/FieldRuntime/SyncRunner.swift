// Port of src/runtime/syncRunner.ts — Runtime driver for the ADR-004 SyncEngine (spec: the V2
// outbox must actually drain).
//
// The SyncEngine is inert on its own — it only acts when something calls `syncOnce()`. This runner
// is that something: a thin adapter over the shared `PollingRunner` that maps one sync pass to the
// loop's `authRequired` signal. See `PollingRunner` for the lifecycle (periodic drain, kick-on-
// enqueue via `notifyQueued`, pause-on-401 until `resumeAfterAuth`).
public struct SyncRunnerDeps {
    public var syncEngine: SyncEngine
    /// Fixed polling cadence (ms) that drains backed-off rows; kick-on-enqueue handles fresh work.
    public var intervalMs: Int?
    public var setTimer: ((@escaping () -> Void, Int) -> Any)?
    public var clearTimer: ((Any) -> Void)?
    /// Fired when a push hit a 401/403 — the auth slice refreshes/re-logins, then resumes the loop.
    public var onAuthRequired: (() -> Void)?
    /// Telemetry for a sweep throw; the loop re-arms on the next tick regardless.
    public var onSyncError: ((String, Error) -> Void)?

    public init(
        syncEngine: SyncEngine,
        intervalMs: Int? = nil,
        setTimer: ((@escaping () -> Void, Int) -> Any)? = nil,
        clearTimer: ((Any) -> Void)? = nil,
        onAuthRequired: (() -> Void)? = nil,
        onSyncError: ((String, Error) -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.intervalMs = intervalMs
        self.setTimer = setTimer
        self.clearTimer = clearTimer
        self.onAuthRequired = onAuthRequired
        self.onSyncError = onSyncError
    }
}

public final class SyncRunner: PollingRunner, @unchecked Sendable {
    public init(_ deps: SyncRunnerDeps) {
        super.init(
            PollingRunnerDeps(
                sweep: {
                    let report = try await deps.syncEngine.syncOnce()
                    return PollingSweepResult(authRequired: report.push.authRequired)
                },
                scope: "sync",
                intervalMs: deps.intervalMs,
                setTimer: deps.setTimer,
                clearTimer: deps.clearTimer,
                onAuthRequired: deps.onAuthRequired,
                onSyncError: deps.onSyncError
            ))
    }
}
