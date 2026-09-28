// Port of src/runtime/uploadRunner.ts — Runtime driver for the ADR-004 UploadEngine — the
// blob-upload counterpart of SyncRunner.
//
// The UploadEngine is inert on its own; this thin adapter over the shared `PollingRunner` runs one
// pass — `processOnce()` (open session → chunked PATCH → hash-verify → enqueue attachment.link →
// reconcile link) and, when not paused for auth, `purgeOnce()` (drop local bytes once a blob is
// fully linked). See `PollingRunner` for the lifecycle (periodic drain, kick-on-capture via
// `notifyQueued`, pause-on-401 until `resumeAfterAuth`).
public struct UploadRunnerDeps {
    public var uploadEngine: UploadProcessing
    /// Fixed polling cadence (ms) that drains in-progress uploads; kick-on-capture handles fresh ones.
    public var intervalMs: Int?
    public var setTimer: ((@escaping () -> Void, Int) -> Any)?
    public var clearTimer: ((Any) -> Void)?
    /// Fired when an upload hit a 401/403 — the auth slice refreshes/re-logins, then resumes.
    public var onAuthRequired: (() -> Void)?
    /// Telemetry for a sweep throw; the loop re-arms on the next tick regardless.
    public var onSyncError: ((String, Error) -> Void)?

    public init(
        uploadEngine: UploadProcessing,
        intervalMs: Int? = nil,
        setTimer: ((@escaping () -> Void, Int) -> Any)? = nil,
        clearTimer: ((Any) -> Void)? = nil,
        onAuthRequired: (() -> Void)? = nil,
        onSyncError: ((String, Error) -> Void)? = nil
    ) {
        self.uploadEngine = uploadEngine
        self.intervalMs = intervalMs
        self.setTimer = setTimer
        self.clearTimer = clearTimer
        self.onAuthRequired = onAuthRequired
        self.onSyncError = onSyncError
    }
}

public final class UploadRunner: PollingRunner, @unchecked Sendable {
    public init(_ deps: UploadRunnerDeps) {
        super.init(
            PollingRunnerDeps(
                sweep: {
                    let report = try await deps.uploadEngine.processOnce()
                    if report.authRequired { return PollingSweepResult(authRequired: true) }
                    // Cheap, network-free: drop local bytes for blobs that are now fully linked.
                    _ = try await deps.uploadEngine.purgeOnce()
                    return PollingSweepResult(authRequired: false)
                },
                scope: "upload",
                intervalMs: deps.intervalMs,
                setTimer: deps.setTimer,
                clearTimer: deps.clearTimer,
                onAuthRequired: deps.onAuthRequired,
                onSyncError: deps.onSyncError
            ))
    }
}
