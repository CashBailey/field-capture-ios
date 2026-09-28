// Port of __tests__/polling-runner.test.ts — the shared self-scheduling drain loop behind
// SyncRunner/UploadRunner. Injected timers make the schedule deterministic. Proves the interval
// floor (never busy-spin), the pause-on-auth / resume cycle, and that a thrown sweep never kills
// the loop.
import XCTest

@testable import FieldRuntime

private final class TimerLog {
    struct Entry {
        let fn: () -> Void
        let ms: Int
    }
    private(set) var entries: [Entry] = []

    func setTimer(_ fn: @escaping () -> Void, _ ms: Int) -> Any {
        entries.append(Entry(fn: fn, ms: ms))
        return entries.count - 1
    }

    func clearTimer(_ handle: Any) {}

    func fireLast() {
        entries.last?.fn()
    }
}

private func makeRunner(
    sweep: @escaping () async throws -> PollingSweepResult,
    intervalMs: Int? = nil,
    onSyncError: ((String, Error) -> Void)? = nil,
    onAuthRequired: (() -> Void)? = nil
) -> (runner: PollingRunner, timers: TimerLog) {
    let timers = TimerLog()
    let runner = PollingRunner(
        PollingRunnerDeps(
            sweep: sweep, scope: "test", intervalMs: intervalMs,
            setTimer: timers.setTimer, clearTimer: timers.clearTimer,
            onAuthRequired: onAuthRequired, onSyncError: onSyncError))
    return (runner, timers)
}

final class PollingRunnerTests: XCTestCase {
    func testFloorsATooSmallIntervalAt1sSoTheLoopNeverBusySpins() async {
        let (runner, timers) = makeRunner(sweep: { PollingSweepResult(authRequired: false) }, intervalMs: 10)
        runner.start()
        await flushAsync()
        XCTAssertEqual(timers.entries.last?.ms, 1_000)  // 10ms request floored to 1000ms
        runner.stop()
    }

    func testDefaultsToThe60sCadenceWhenNoIntervalIsGiven() async {
        let (runner, timers) = makeRunner(sweep: { PollingSweepResult(authRequired: false) })
        runner.start()
        await flushAsync()
        XCTAssertEqual(timers.entries.last?.ms, 60_000)
        runner.stop()
    }

    func testHonorsASaneIntervalUnchanged() async {
        let (runner, timers) = makeRunner(sweep: { PollingSweepResult(authRequired: false) }, intervalMs: 30_000)
        runner.start()
        await flushAsync()
        XCTAssertEqual(timers.entries.last?.ms, 30_000)
        runner.stop()
    }

    func testPausesOnAuthRequiredNoReArmAndResumesOnResumeAfterAuth() async {
        final class Box { var auth = true }
        let box = Box()
        var authRequiredCalls = 0
        let (runner, timers) = makeRunner(
            sweep: { PollingSweepResult(authRequired: box.auth) },
            onAuthRequired: { authRequiredCalls += 1 })
        runner.start()
        await flushAsync()
        XCTAssertEqual(authRequiredCalls, 1)
        XCTAssertTrue(runner.isPausedForAuth())
        XCTAssertTrue(timers.entries.isEmpty)  // paused → did NOT arm a periodic timer

        box.auth = false
        runner.resumeAfterAuth()
        await flushAsync()
        XCTAssertFalse(runner.isPausedForAuth())
        XCTAssertEqual(timers.entries.last?.ms, 60_000)  // resumed and re-armed
        runner.stop()
    }

    func testAThrownSweepIsReportedWithTheScopeAndNeverKillsTheLoop() async {
        final class Box { var blowUp = true }
        let box = Box()
        struct BoomError: Error {}
        final class Errors { var items: [(scope: String, error: Error)] = [] }
        let errors = Errors()
        let (runner, timers) = makeRunner(
            sweep: {
                if box.blowUp { throw BoomError() }
                return PollingSweepResult(authRequired: false)
            },
            onSyncError: { scope, error in errors.items.append((scope, error)) })
        runner.start()
        await flushAsync()
        XCTAssertEqual(errors.items.count, 1)
        XCTAssertEqual(errors.items.first?.scope, "test")
        XCTAssertEqual(timers.entries.last?.ms, 60_000)  // re-armed despite the throw

        box.blowUp = false
        timers.fireLast()  // the next tick drains cleanly
        await flushAsync()
        XCTAssertEqual(errors.items.count, 1)  // no new error
        runner.stop()
    }
}
