// Port of __tests__/upload-runner.test.ts — UploadRunner: the runtime driver that makes the
// ADR-004 UploadEngine drain blobs. Same discipline as SyncRunner — injected timers, scriptable
// engine — so the schedule is deterministic. Proves it drives processOnce (+purgeOnce) on start,
// kicks on capture, re-arms periodically, pauses on a 401 (authRequired), resumes on re-auth,
// survives a throw, and is inert before start / after stop.
import XCTest

@testable import FieldRuntime

private let UPLOAD_RUNNER_INTERVAL_MS = 30_000

private final class FakeUploadEngine: UploadProcessing {
    var processOnceCalls = 0
    var purgeOnceCalls = 0
    var nextReport = UploadSweepReport()
    var onProcess: (() throws -> Void)?
    var onPurge: (() throws -> Void)?

    func processOnce() async throws -> UploadSweepReport {
        processOnceCalls += 1
        try onProcess?()
        return nextReport
    }

    func purgeOnce() async throws -> [String] {
        purgeOnceCalls += 1
        try onPurge?()
        return []
    }
}

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
    func fireLast() { entries.last?.fn() }
}

private func makeRunner() -> (
    runner: UploadRunner, engine: FakeUploadEngine, timers: TimerLog, authReq: () -> Int, syncErrors: Box<String>
) {
    let engine = FakeUploadEngine()
    let timers = TimerLog()
    let authRequired = Box<Int>()
    authRequired.items = [0]
    let syncErrors = Box<String>()
    let runner = UploadRunner(
        UploadRunnerDeps(
            uploadEngine: engine, intervalMs: UPLOAD_RUNNER_INTERVAL_MS, setTimer: timers.setTimer,
            clearTimer: timers.clearTimer,
            onAuthRequired: { authRequired.items[0] += 1 },
            onSyncError: { _, error in syncErrors.items.append(String(describing: error)) }))
    return (runner, engine, timers, { authRequired.items[0] }, syncErrors)
}

final class UploadRunnerTests: XCTestCase {
    func testDrivesProcessOnceAndPurgeOnceOnStartAndArmsThePeriodicTimer() async {
        let (runner, engine, timers, _, _) = makeRunner()
        runner.start()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
        XCTAssertEqual(engine.purgeOnceCalls, 1)
        XCTAssertEqual(timers.entries.last?.ms, UPLOAD_RUNNER_INTERVAL_MS)
        runner.stop()
    }

    func testReSweepsWhenThePeriodicTimerFires() async {
        let (runner, engine, timers, _, _) = makeRunner()
        runner.start()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
        timers.fireLast()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 2)
        runner.stop()
    }

    func testKicksAnImmediateSweepOnNotifyQueued() async {
        let (runner, engine, _, _, _) = makeRunner()
        runner.start()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 2)
        runner.stop()
    }

    func testPausesOnAuthRequiredNoPurgeNoTimerNotifyQueuedInertUntilResume() async {
        let (runner, engine, timers, authReq, _) = makeRunner()
        engine.nextReport = UploadSweepReport(authRequired: true)
        runner.start()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
        XCTAssertEqual(engine.purgeOnceCalls, 0)  // paused before purge
        XCTAssertTrue(runner.isPausedForAuth())
        XCTAssertEqual(authReq(), 1)
        XCTAssertTrue(timers.entries.isEmpty)
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)  // still paused
        runner.stop()
    }

    func testResumesAndDrainsAfterResumeAfterAuthOnceAFreshTokenExists() async {
        let (runner, engine, _, _, _) = makeRunner()
        engine.nextReport = UploadSweepReport(authRequired: true)
        runner.start()
        await flushAsync()
        XCTAssertTrue(runner.isPausedForAuth())
        engine.nextReport = UploadSweepReport(uploaded: 1)
        runner.resumeAfterAuth()
        await flushAsync()
        XCTAssertFalse(runner.isPausedForAuth())
        XCTAssertEqual(engine.processOnceCalls, 2)
        XCTAssertEqual(engine.purgeOnceCalls, 1)
        runner.stop()
    }

    func testAProcessOnceThrowIsContainedAndTheLoopReArms() async {
        let (runner, engine, timers, _, syncErrors) = makeRunner()
        struct BoomError: Error {}
        engine.onProcess = { throw BoomError() }
        runner.start()
        await flushAsync()
        XCTAssertEqual(syncErrors.items.count, 1)
        XCTAssertEqual(engine.purgeOnceCalls, 0)
        XCTAssertEqual(timers.entries.last?.ms, UPLOAD_RUNNER_INTERVAL_MS)
        runner.stop()
    }

    func testIsInertBeforeStartAndAfterStop() async {
        let (runner, engine, _, _, _) = makeRunner()
        runner.notifyQueued()  // not started
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 0)

        runner.start()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
        runner.stop()
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(engine.processOnceCalls, 1)
    }
}
