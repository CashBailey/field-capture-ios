// Port of src/runtime/pollingRunner.ts — Shared self-scheduling drain loop behind `SyncRunner` and
// `UploadRunner` (they were line-for-line identical — same running/pausedForAuth/sweeping/resweep
// flags, timer plumbing, auth pause/resume). Only the per-pass work differs, injected as `sweep`.
// Mirrors `RetryEngine`'s lifecycle so all three drivers behave identically; all time is injected
// for deterministic tests.
//
//  - Periodic timer re-drives `sweep` on a fixed cadence (the engine self-skips not-yet-due work,
//    so ticking while offline is a safe no-op).
//  - `notifyQueued()` kicks an immediate pass when fresh work is enqueued (no whole-interval wait).
//  - When a pass reports `authRequired` (401/403) the loop PAUSES — hammering Hub with a dead token
//    turns one failure into N — until `resumeAfterAuth()` is called.
import Foundation

/// Production default timer seam: a cancellable `Task.sleep`. Mirrors the TS
/// `setTimeout`/`clearTimeout` default, but expressed with Swift concurrency instead of a real
/// per-call `Foundation.Timer` (no thread/run-loop dependency, and trivially cancellable).
private final class RuntimeTimerAction: @unchecked Sendable {
    let call: () -> Void

    init(_ call: @escaping () -> Void) {
        self.call = call
    }
}

enum RuntimeDefaultTimer {
    static func setTimer(_ fn: @escaping () -> Void, _ ms: Int) -> Any {
        let action = RuntimeTimerAction(fn)
        return Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            guard !Task.isCancelled else { return }
            action.call()
        }
    }

    static func clearTimer(_ handle: Any) {
        (handle as? Task<Void, Never>)?.cancel()
    }
}

public struct PollingSweepResult {
    public var authRequired: Bool
    public init(authRequired: Bool) {
        self.authRequired = authRequired
    }
}

public struct PollingRunnerDeps {
    /// One pass of runner-specific work; `authRequired` true pauses the loop until re-auth. A throw
    /// is reported via `onSyncError` and never kills the loop.
    public var sweep: () async throws -> PollingSweepResult
    /// Telemetry scope label for a sweep throw (e.g. "sync" | "upload").
    public var scope: String
    /// Fixed polling cadence (ms); kick-on-enqueue handles fresh work. Floored at 1s to never spin.
    public var intervalMs: Int?
    public var setTimer: ((@escaping () -> Void, Int) -> Any)?
    public var clearTimer: ((Any) -> Void)?
    /// Fired when a pass hit a 401/403 — the auth slice refreshes/re-logins, then resumes the loop.
    public var onAuthRequired: (() -> Void)?
    /// Telemetry for a sweep throw; the loop re-arms on the next tick regardless.
    public var onSyncError: ((String, Error) -> Void)?

    public init(
        sweep: @escaping () async throws -> PollingSweepResult,
        scope: String,
        intervalMs: Int? = nil,
        setTimer: ((@escaping () -> Void, Int) -> Any)? = nil,
        clearTimer: ((Any) -> Void)? = nil,
        onAuthRequired: (() -> Void)? = nil,
        onSyncError: ((String, Error) -> Void)? = nil
    ) {
        self.sweep = sweep
        self.scope = scope
        self.intervalMs = intervalMs
        self.setTimer = setTimer
        self.clearTimer = clearTimer
        self.onAuthRequired = onAuthRequired
        self.onSyncError = onSyncError
    }
}

private let DEFAULT_INTERVAL_MS = 60_000
/// Never poll faster than this — a misconfigured tiny interval must not busy-spin the network.
private let MIN_INTERVAL_MS = 1_000

public class PollingRunner: @unchecked Sendable {
    private let deps: PollingRunnerDeps
    private let intervalMs: Int
    private let setTimer: (@escaping () -> Void, Int) -> Any
    private let clearTimer: (Any) -> Void
    private let stateLock = NSLock()

    private var running = false
    private var pausedForAuth = false
    private var sweeping = false
    private var resweepRequested = false
    private var timer: Any?

    public init(_ deps: PollingRunnerDeps) {
        self.deps = deps
        self.intervalMs = max(MIN_INTERVAL_MS, deps.intervalMs ?? DEFAULT_INTERVAL_MS)
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
        if shouldStart { launchSweep() }
    }

    public func stop() {
        withStateLock {
            running = false
            resweepRequested = false
        }
        cancelTimer()
    }

    /// True while the runner is holding off because a pass hit a 401/403.
    public func isPausedForAuth() -> Bool {
        withStateLock { pausedForAuth }
    }

    /// Call whenever a valid session is (re)established — interactive login OR a silent refresh
    /// observed elsewhere. Idempotent and cheap when there is nothing to resume.
    public func resumeAfterAuth() {
        let shouldResume = withStateLock {
            guard running, pausedForAuth else { return false }
            pausedForAuth = false
            return true
        }
        if shouldResume { launchSweep() }
    }

    /// Re-arm immediately when new work enters the queue (fresh evidence / blob / print event).
    public func notifyQueued() {
        let shouldLaunch = withStateLock {
            guard running, !pausedForAuth else { return false }
            if sweeping {
                resweepRequested = true
                return false
            }
            return true
        }
        if shouldLaunch { launchSweep() }
    }

    /// One pass: run the injected sweep, pause on auth, otherwise re-arm the periodic timer.
    /// Public for tests and a user-facing "sync now". A throw never kills the loop.
    public func runSweep() async {
        let shouldRun = withStateLock {
            guard running, !pausedForAuth else { return false }
            if sweeping {
                // A sweep is in progress; run another full pass when it finishes instead of dropping this.
                resweepRequested = true
                return false
            }
            sweeping = true
            return true
        }
        guard shouldRun else { return }

        var pausedNow = false
        do {
            let result = try await deps.sweep()
            if result.authRequired {
                pausedNow = true
            }
        } catch {
            // A sweep must never kill the loop: the timer below re-arms regardless, so the queue
            // keeps draining on the next tick instead of silently freezing.
            deps.onSyncError?(deps.scope, error)
        }

        if pausedNow {
            let shouldNotify = withStateLock {
                sweeping = false
                resweepRequested = false
                guard running else { return false }
                pausedForAuth = true
                return true
            }
            if shouldNotify { deps.onAuthRequired?() }
            return  // paused — do NOT re-arm; resumeAfterAuth() restarts the loop
        }

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
        // Fixed cadence: the engine self-skips work still inside its backoff window, so a plain
        // interval is enough — no per-row due-time scan (unlike RetryEngine, which owns the schedule).
        let nextTimer = setTimer({ [weak self] in self?.launchSweep() }, intervalMs)
        let keptTimer = withStateLock {
            guard running, !pausedForAuth, timer == nil else { return false }
            timer = nextTimer
            return true
        }
        if !keptTimer { clearTimer(nextTimer) }
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
