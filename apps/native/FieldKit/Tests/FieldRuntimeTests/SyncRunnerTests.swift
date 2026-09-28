import FieldContracts
import FieldDomain
// Port of __tests__/sync-runner.test.ts — SyncRunner: the runtime driver that makes the ADR-004
// SyncEngine actually drain. Mirrors the RetryEngine test discipline — scriptable fake transport,
// volatile stores, injected timers — so the schedule is fully deterministic. Proves it drives
// syncOnce on start, kicks on enqueue, re-arms periodically, backs off (never hammers), pauses on a
// 401 (push OR pull leg), resumes on re-auth, and stays inert before start / after stop.
import XCTest

@testable import FieldRuntime

private let SYNC_RUNNER_INTERVAL_MS = 30_000

private func envelope(_ opId: String, _ localSeq: Int) -> OperationEnvelope<JSONValue> {
    OperationEnvelope<JSONValue>(
        opId: opId, kind: .event, type: "dvir.submit", idempotencyKey: "gtr:devA:\(localSeq):\(opId)",
        localSeq: localSeq, dependsOn: [], payload: .object(["opId": .string(opId)]))
}

private func accepted(_ opId: String, _ commitSeq: Int) -> CommandResult<JSONValue> {
    .accepted(opId: opId, token: ChangeToken(authorityEpoch: 1, commitSeq: commitSeq))
}

private final class FakeTransport: SyncCommandTransport {
    private(set) var batches: [[OperationEnvelope<JSONValue>]] = []
    private(set) var pulls: [ChangeToken] = []
    var onSubmit: ([OperationEnvelope<JSONValue>]) throws -> [CommandResult<JSONValue>] = { batch in
        batch.enumerated().map { i, e in accepted(e.opId, i + 1) }
    }
    var onPull: (ChangeToken) throws -> ChangePage<JSONValue> = { since in ChangePage(token: since, changes: []) }

    func submitBatch(_ batch: [OperationEnvelope<JSONValue>]) async throws -> [CommandResult<JSONValue>] {
        batches.append(batch)
        return try onSubmit(batch)
    }

    func pullChanges(since: ChangeToken) async throws -> ChangePage<JSONValue> {
        pulls.append(since)
        return try onPull(since)
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

private struct SyncOutboxReadError: Error {}

private final class ReadFailingOutboxStore: SyncOutboxStore {
    let durability: StoreDurability = .volatileMemory

    func save(_ item: DurableSyncOutboxItem) throws {}
    func saveAll(_ items: [DurableSyncOutboxItem]) throws {}
    func get(_ opId: String) throws -> DurableSyncOutboxItem? { nil }
    func list() throws -> [DurableSyncOutboxItem] { throw SyncOutboxReadError() }
    func listByState(_ state: OutboxItemState) throws -> [DurableSyncOutboxItem] { [] }
    func committedOpIds() throws -> Set<String> { [] }
}

private func makeRunner() -> (
    runner: SyncRunner, engine: SyncEngine, outbox: VolatileSyncOutboxStore, transport: FakeTransport, timers: TimerLog,
    authReq: () -> Int
) {
    let outbox = VolatileSyncOutboxStore()
    let frontier = VolatileSyncFrontierStore()
    let transport = FakeTransport()
    let engine = SyncEngine(
        SyncEngineDeps(
            outbox: outbox, frontier: frontier, transport: transport, applyChanges: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }, random: { 0.5 }))
    let timers = TimerLog()
    let authRequired = Box<Int>()
    authRequired.items = [0]
    let runner = SyncRunner(
        SyncRunnerDeps(
            syncEngine: engine, intervalMs: SYNC_RUNNER_INTERVAL_MS, setTimer: timers.setTimer,
            clearTimer: timers.clearTimer,
            onAuthRequired: { authRequired.items[0] += 1 }))
    return (runner, engine, outbox, transport, timers, { authRequired.items[0] })
}

final class SyncRunnerTests: XCTestCase {
    func testDrivesAPushOnStartAndArmsThePeriodicTimer() async throws {
        let (runner, engine, _, transport, timers, _) = makeRunner()
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        XCTAssertEqual(transport.batches[0].map(\.opId), ["op-1"])
        XCTAssertEqual(timers.entries.last?.ms, SYNC_RUNNER_INTERVAL_MS)
        runner.stop()
    }

    func testReSweepsWhenThePeriodicTimerFires() async throws {
        let (runner, engine, _, transport, timers, _) = makeRunner()
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        _ = try engine.enqueue(envelope("op-2", 2))
        timers.fireLast()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 2)
        runner.stop()
    }

    func testKicksAnImmediatePushOnNotifyQueued() async throws {
        let (runner, engine, _, transport, _, _) = makeRunner()
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 0)
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        runner.stop()
    }

    func testBacksOffAndDoesNotHammer() async throws {
        let (runner, engine, _, transport, timers, _) = makeRunner()
        transport.onSubmit = { _ in throw HubNetworkError("offline") }
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        timers.fireLast()  // next tick — but the row is inside its backoff window (clock frozen)
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)  // engine skips the backed-off row; no hammering
        runner.stop()
    }

    func testPausesOnAPush401AndStopsSchedulingUntilReAuth() async throws {
        let (runner, engine, _, transport, timers, authReq) = makeRunner()
        transport.onSubmit = { _ in throw HubAuthError("dead token", httpStatus: 401) }
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        XCTAssertTrue(runner.isPausedForAuth())
        XCTAssertEqual(authReq(), 1)
        XCTAssertTrue(timers.entries.isEmpty)
        _ = try engine.enqueue(envelope("op-2", 2))
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        runner.stop()
    }

    func testResumesAndDrainsAfterResumeAfterAuthOnceAFreshTokenExists() async throws {
        let (runner, engine, _, transport, _, _) = makeRunner()
        transport.onSubmit = { _ in throw HubAuthError("dead token", httpStatus: 401) }
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.start()
        await flushAsync()
        XCTAssertTrue(runner.isPausedForAuth())
        transport.onSubmit = { batch in batch.map { accepted($0.opId, 1) } }
        runner.resumeAfterAuth()
        await flushAsync()
        XCTAssertFalse(runner.isPausedForAuth())
        XCTAssertEqual(transport.batches.count, 2)
        runner.stop()
    }

    func testIsInertBeforeStartAndAfterStop() async throws {
        let (runner, engine, _, transport, timers, _) = makeRunner()
        _ = try engine.enqueue(envelope("op-1", 1))
        runner.notifyQueued()  // not started yet
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 0)

        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
        runner.stop()
        _ = try engine.enqueue(envelope("op-2", 2))
        timers.fireLast()  // a stale timer firing after stop must do nothing
        runner.notifyQueued()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 1)
    }

    func testPausesOnAPullLeg401TooNoPushWorkPull401s() async throws {
        let (runner, _, _, transport, _, _) = makeRunner()
        transport.onPull = { _ in throw HubAuthError("dead token", httpStatus: 401) }
        runner.start()
        await flushAsync()
        XCTAssertEqual(transport.batches.count, 0)
        XCTAssertGreaterThanOrEqual(transport.pulls.count, 1)
        XCTAssertTrue(runner.isPausedForAuth())
        runner.stop()
    }

    func testOutboxReadFailureReachesTheRunnerErrorChannelAndTheLoopRearms() async {
        let transport = FakeTransport()
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: ReadFailingOutboxStore(), frontier: VolatileSyncFrontierStore(),
                transport: transport, applyChanges: { _ in }))
        let timers = TimerLog()
        let errors = Box<String>()
        let runner = SyncRunner(
            SyncRunnerDeps(
                syncEngine: engine, intervalMs: SYNC_RUNNER_INTERVAL_MS,
                setTimer: timers.setTimer, clearTimer: timers.clearTimer,
                onSyncError: { _, error in errors.items.append(String(describing: error)) }))

        runner.start()
        await flushAsync()

        XCTAssertEqual(errors.items.count, 1)
        XCTAssertEqual(timers.entries.last?.ms, SYNC_RUNNER_INTERVAL_MS)
        XCTAssertTrue(transport.batches.isEmpty)
        runner.stop()
    }
}
