import FieldContracts
import FieldData
import FieldDomain
// Port of __tests__/sync-engine.test.ts — full sync engine behaviour (ADR 004): durable outbox
// dispatch over /sync/commands, authoritative pull over /sync/changes, dependency ordering,
// idempotent replay, backoff, frontier advancement, stale-token reset, and restart recovery.
// Hardware-free: fake transport, volatile stores, injected clock/randomness.
import XCTest

@testable import FieldRuntime

private func envelope(_ opId: String, _ localSeq: Int, dependsOn: [String] = []) -> OperationEnvelope<JSONValue> {
    OperationEnvelope<JSONValue>(
        opId: opId, kind: .event, type: "test.op", idempotencyKey: "gtr:devA:\(localSeq):\(opId)",
        localSeq: localSeq, dependsOn: dependsOn, payload: .object(["opId": .string(opId)]))
}

private func accepted(_ opId: String, _ commitSeq: Int) -> CommandResult<JSONValue> {
    .accepted(opId: opId, token: ChangeToken(authorityEpoch: 1, commitSeq: commitSeq))
}

/// Scriptable fake transport recording every batch and pull.
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

/// Epoch-ms clock, mirroring the TS `makeEngine`'s `now: () => new Date(overrides?.nowMs?.() ?? 1_000_000)`.
private func makeEngine(
    transport: FakeTransport = FakeTransport(), applyChanges: (([JSONValue]) throws -> Void)? = nil,
    nowMs: (() -> Double)? = nil, onHubContact: ((Date) -> Void)? = nil
) -> (
    engine: SyncEngine, outbox: VolatileSyncOutboxStore, frontier: VolatileSyncFrontierStore, transport: FakeTransport,
    applied: Box<JSONValue>
) {
    let outbox = VolatileSyncOutboxStore()
    let frontier = VolatileSyncFrontierStore()
    let applied = Box<JSONValue>()
    let engine = SyncEngine(
        SyncEngineDeps(
            outbox: outbox, frontier: frontier, transport: transport,
            applyChanges: applyChanges ?? { changes in applied.items.append(contentsOf: changes) },
            now: { Date(timeIntervalSince1970: (nowMs?() ?? 1_000_000) / 1_000) }, random: { 0.5 },
            onHubContact: onHubContact))
    return (engine, outbox, frontier, transport, applied)
}

private enum InjectedTransactionError: Error {
    case afterWrites
}

private enum InjectedOutboxError: Error, Equatable {
    case read
    case write
}

/// Transactional failing store used to prove the engine never mistakes an I/O error for an empty
/// outbox or advances only part of a batch. The volatile store remains the source of truth; a
/// configured failure is thrown before that source is mutated.
private final class FailingOutboxStore: SyncOutboxStore {
    enum Operation: Hashable {
        case save
        case saveAll
        case get
        case list
        case listByState
        case committedOpIds
    }

    let durability: StoreDurability = .volatileMemory
    private let backing = VolatileSyncOutboxStore()
    private var successfulCallsBeforeFailure: [Operation: Int] = [:]

    func fail(_ operation: Operation, afterSuccessfulCalls count: Int = 0) {
        successfulCallsBeforeFailure[operation] = count
    }

    func seed(_ item: DurableSyncOutboxItem) {
        backing.save(item)
    }

    func stored(_ opId: String) -> DurableSyncOutboxItem? {
        backing.get(opId)
    }

    private func check(_ operation: Operation, error: InjectedOutboxError) throws {
        guard let remaining = successfulCallsBeforeFailure[operation] else { return }
        if remaining == 0 {
            successfulCallsBeforeFailure.removeValue(forKey: operation)
            throw error
        }
        successfulCallsBeforeFailure[operation] = remaining - 1
    }

    func save(_ item: DurableSyncOutboxItem) throws {
        try check(.save, error: .write)
        backing.save(item)
    }

    func saveAll(_ items: [DurableSyncOutboxItem]) throws {
        try check(.saveAll, error: .write)
        backing.saveAll(items)
    }

    func get(_ opId: String) throws -> DurableSyncOutboxItem? {
        try check(.get, error: .read)
        return backing.get(opId)
    }

    func list() throws -> [DurableSyncOutboxItem] {
        try check(.list, error: .read)
        return backing.list()
    }

    func listByState(_ state: OutboxItemState) throws -> [DurableSyncOutboxItem] {
        try check(.listByState, error: .read)
        return backing.listByState(state)
    }

    func committedOpIds() throws -> Set<String> {
        try check(.committedOpIds, error: .read)
        return backing.committedOpIds()
    }
}

private func makeEngine(outbox: SyncOutboxStore, transport: FakeTransport = FakeTransport()) -> SyncEngine {
    SyncEngine(
        SyncEngineDeps(
            outbox: outbox, frontier: VolatileSyncFrontierStore(), transport: transport,
            applyChanges: { _ in }, now: { Date(timeIntervalSince1970: 1_000) }, random: { 0.5 }))
}

final class SyncEngineTests: XCTestCase {
    // MARK: pullOnce — atomic apply + frontier advance

    func testAppliesChangesAndAdvancesTheFrontierInsideOneTransaction() async throws {
        let outbox = VolatileSyncOutboxStore()
        let frontier = VolatileSyncFrontierStore()
        let transport = FakeTransport()
        let order = Box<String>()
        let applied = Box<JSONValue>()
        let txDepth = Box<Int>()
        txDepth.items = [0]
        let appliedInTx = Box<Bool>()
        let frontierInTx = Box<Bool>()
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: frontier, transport: transport,
                applyChanges: { changes in
                    applied.items.append(contentsOf: changes)
                    order.items.append("apply")
                    if txDepth.items[0] > 0 { appliedInTx.items.append(true) }
                },
                transaction: { fn in
                    txDepth.items[0] += 1
                    order.items.append("tx-start")
                    try fn()
                    txDepth.items[0] -= 1
                    order.items.append("tx-end")
                },
                now: { Date(timeIntervalSince1970: 1_000) }, random: { 0.5 }))
        transport.onPull = { _ in
            order.items.append("frontier-pending")
            return ChangePage(
                token: ChangeToken(authorityEpoch: 1, commitSeq: 5),
                changes: [
                    .object([
                        "authority_epoch": .number(1), "commit_seq": .number(5),
                        "change_type": .string("assignment.upsert"),
                    ])
                ])
        }
        _ = try await engine.pullOnce()

        XCTAssertTrue(appliedInTx.items.contains(true))
        XCTAssertEqual(
            order.items.filter { $0 == "tx-start" || $0 == "apply" || $0 == "tx-end" }, ["tx-start", "apply", "tx-end"])
        XCTAssertEqual(applied.items.count, 1)
        _ = frontierInTx
    }

    func testMalformedChangeRollsBackEarlierChangesAndDoesNotAdvanceFrontier() async throws {
        let db = try SystemSqliteDriver(
            path: NSTemporaryDirectory() + "fieldkit-sync-malformed-\(UUID().uuidString).db")
        try migrate(db)
        let outbox = VolatileSyncOutboxStore()
        let frontier = SqliteSyncFrontierStore(db, .durablePlain)
        let ledger = SqliteSyncChangeLedger(db, .durablePlain)
        let transport = FakeTransport()
        let initialFrontier = ChangeToken(authorityEpoch: 1, commitSeq: 0)
        frontier.set(initialFrontier)
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: frontier, transport: transport,
                applyChanges: { try recordAllPulledChanges($0, in: ledger) },
                transaction: { fn in try db.transaction { try fn() } }))
        transport.onPull = { _ in
            ChangePage(
                token: ChangeToken(authorityEpoch: 1, commitSeq: 2),
                changes: [
                    .object([
                        "authority_epoch": .number(1), "commit_seq": .number(1),
                        "change_type": .string("assignment.upsert"),
                    ]),
                    .object(["junk": .bool(true)]),
                ])
        }

        do {
            _ = try await engine.pullOnce()
            XCTFail("expected malformed pull to throw")
        } catch {
            XCTAssertEqual(error as? SyncEngineError, .skippedPulledChanges(count: 1))
        }
        XCTAssertEqual(ledger.count(), 0)
        XCTAssertEqual(frontier.get(), initialFrontier)
    }

    func testTransactionFailureAfterWritesRollsBackChangesAndFrontier() async throws {
        let db = try SystemSqliteDriver(
            path: NSTemporaryDirectory() + "fieldkit-sync-transaction-\(UUID().uuidString).db")
        try migrate(db)
        let outbox = VolatileSyncOutboxStore()
        let frontier = SqliteSyncFrontierStore(db, .durablePlain)
        let ledger = SqliteSyncChangeLedger(db, .durablePlain)
        let transport = FakeTransport()
        let initialFrontier = ChangeToken(authorityEpoch: 1, commitSeq: 4)
        frontier.set(initialFrontier)
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: frontier, transport: transport,
                applyChanges: { try recordAllPulledChanges($0, in: ledger) },
                transaction: { fn in
                    try db.transaction {
                        try fn()
                        throw InjectedTransactionError.afterWrites
                    }
                }))
        transport.onPull = { _ in
            ChangePage(
                token: ChangeToken(authorityEpoch: 1, commitSeq: 5),
                changes: [
                    .object([
                        "authority_epoch": .number(1), "commit_seq": .number(5),
                        "change_type": .string("assignment.upsert"),
                    ])
                ])
        }

        do {
            _ = try await engine.pullOnce()
            XCTFail("expected transaction failure to throw")
        } catch {
            XCTAssertTrue(error is InjectedTransactionError)
        }
        XCTAssertEqual(ledger.count(), 0)
        XCTAssertEqual(frontier.get(), initialFrontier)
    }

    // MARK: enqueue

    func testPersistsAPendingDurableRowWithTimestamps() throws {
        let (engine, outbox, _, _, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        let item = outbox.get("op-1")
        XCTAssertEqual(item?.state, .pending)
        XCTAssertEqual(item?.retryCount, 0)
        XCTAssertNotNil(item?.createdAt)
    }

    func testIsIdempotentOnOpIdADifferentEnvelopeUnderTheSameOpIdThrows() throws {
        let (engine, _, _, _, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        XCTAssertEqual(try engine.enqueue(envelope("op-1", 1)).envelope.localSeq, 1)
        XCTAssertThrowsError(try engine.enqueue(envelope("op-1", 2)))
    }

    func testRefusesAnInconsistentEnvelopeBeforeAnythingIsStored() {
        let (engine, outbox, _, _, _) = makeEngine()
        var bad = envelope("op-1", 1)
        bad.idempotencyKey = "gtr:devA:9:op-1"
        XCTAssertThrowsError(try engine.enqueue(bad))
        XCTAssertEqual(outbox.list().count, 0)
    }

    func testEnqueueWriteFailurePropagatesWithoutStoringOrKickingTheRunner() {
        let outbox = FailingOutboxStore()
        outbox.fail(.save)
        let kicks = Box<Bool>()
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: VolatileSyncFrontierStore(), transport: FakeTransport(),
                applyChanges: { _ in }, onEnqueue: { kicks.items.append(true) }))

        XCTAssertThrowsError(try engine.enqueue(envelope("op-1", 1))) { error in
            XCTAssertEqual(error as? InjectedOutboxError, .write)
        }
        XCTAssertNil(outbox.stored("op-1"))
        XCTAssertTrue(kicks.items.isEmpty)
    }

    func testEnqueueReadFailurePropagatesInsteadOfBeingTreatedAsAnEmptyOutbox() {
        let outbox = FailingOutboxStore()
        outbox.fail(.get)
        let engine = makeEngine(outbox: outbox)

        XCTAssertThrowsError(try engine.enqueue(envelope("op-1", 1))) { error in
            XCTAssertEqual(error as? InjectedOutboxError, .read)
        }
        XCTAssertNil(outbox.stored("op-1"))
    }

    // MARK: pushOnce — command submit

    func testSubmitsReadyItemsInLocalSeqOrderAndFoldsAcceptedOutcomes() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-b", 2))
        _ = try engine.enqueue(envelope("op-a", 1))

        let report = try await engine.pushOnce()

        XCTAssertEqual(transport.batches[0].map(\.opId), ["op-a", "op-b"])
        XCTAssertEqual(report.submitted, 2)
        XCTAssertEqual(report.accepted, 2)
        XCTAssertEqual(outbox.get("op-a")?.state, .accepted)
        XCTAssertEqual(outbox.get("op-a")?.committedToken, ChangeToken(authorityEpoch: 1, commitSeq: 1))
    }

    func testDispatchWriteFailurePropagatesBeforeTheNetworkAndLeavesEveryItemPending() async throws {
        let outbox = FailingOutboxStore()
        let transport = FakeTransport()
        let engine = makeEngine(outbox: outbox, transport: transport)
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        outbox.fail(.saveAll)

        do {
            _ = try await engine.pushOnce()
            XCTFail("expected dispatch persistence to throw")
        } catch {
            XCTAssertEqual(error as? InjectedOutboxError, .write)
        }
        XCTAssertTrue(transport.batches.isEmpty)
        XCTAssertEqual(outbox.stored("op-1")?.state, .pending)
        XCTAssertEqual(outbox.stored("op-2")?.state, .pending)
    }

    func testOutcomeWriteFailurePropagatesWithoutPartiallyAcceptingTheBatch() async throws {
        let outbox = FailingOutboxStore()
        let transport = FakeTransport()
        let engine = makeEngine(outbox: outbox, transport: transport)
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        // First saveAll marks the complete batch in-flight; fail the second, which folds Hub's
        // accepted outcomes. Startup recovery can safely replay those in-flight rows.
        outbox.fail(.saveAll, afterSuccessfulCalls: 1)

        do {
            _ = try await engine.pushOnce()
            XCTFail("expected outcome persistence to throw")
        } catch {
            XCTAssertEqual(error as? InjectedOutboxError, .write)
        }
        XCTAssertEqual(transport.batches.count, 1)
        XCTAssertEqual(outbox.stored("op-1")?.state, .inFlight)
        XCTAssertEqual(outbox.stored("op-2")?.state, .inFlight)
    }

    func testRecordsAHubContactAfterACommandsExchangeSucceeds() async throws {
        let contacts = Box<Date>()
        let (engine, _, _, _, _) = makeEngine(
            nowMs: { ISO8601DateFormatter.parseUtc("2026-06-10T20:00:00Z").timeIntervalSince1970 * 1000 },
            onHubContact: { contacts.items.append($0) })
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try await engine.pushOnce()
        XCTAssertEqual(contacts.items.count, 1)
        XCTAssertEqual(contacts.items.first, ISO8601DateFormatter.parseUtc("2026-06-10T20:00:00Z"))
    }

    func testDuplicateReplayATransientFailureResendsTheSameEnvelopeAndLandsAccepted() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))

        transport.onSubmit = { _ in throw HubNetworkError("offline") }
        _ = try await engine.pushOnce()
        XCTAssertEqual(outbox.get("op-1")?.state, .pending)
        XCTAssertEqual(outbox.get("op-1")?.retryCount, 1)

        transport.onSubmit = { batch in batch.map { accepted($0.opId, 7) } }
        let dueAt = outbox.get("op-1")?.nextAttemptAtMs ?? 0
        let engineLater = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: VolatileSyncFrontierStore(), transport: transport,
                applyChanges: { _ in }, now: { Date(timeIntervalSince1970: Double(dueAt + 1) / 1000) }, random: { 0.5 })
        )
        let report = try await engineLater.pushOnce()

        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(transport.batches.count, 2)
        XCTAssertEqual(transport.batches[0][0].idempotencyKey, transport.batches[1][0].idempotencyKey)
        XCTAssertEqual(outbox.get("op-1")?.state, .accepted)
    }

    func testARejectedCommandFreezesTerminallyWithItsCodeAndDetailTheEnvelopeIsPreserved() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        transport.onSubmit = { _ in [.rejected(opId: "op-1", rejectionCode: "locked_sr", detail: "SR locked by hub")] }

        let report = try await engine.pushOnce()

        XCTAssertEqual(report.rejected, 1)
        let item = outbox.get("op-1")
        XCTAssertEqual(item?.state, .rejected)
        XCTAssertEqual(item?.rejectionCode, "locked_sr")
        XCTAssertEqual(item?.lastError, "SR locked by hub")
        XCTAssertEqual(item?.envelope.payload, .object(["opId": .string("op-1")]))

        transport.onSubmit = { _ in [] }
        _ = try await engine.pushOnce()
        XCTAssertEqual(transport.batches.count, 1)
    }

    func testNeedsReviewFreezesTheItemWithTheReviewReasonNeverAutoResubmitted() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        transport.onSubmit = { _ in [.needsReview(opId: "op-1", reviewReason: "assignment_changed")] }

        let report = try await engine.pushOnce()

        XCTAssertEqual(report.needsReview, 1)
        XCTAssertEqual(outbox.get("op-1")?.state, .needsReview)
        XCTAssertEqual(outbox.get("op-1")?.lastError, "assignment_changed")
        transport.onSubmit = { _ in [] }
        _ = try await engine.pushOnce()
        XCTAssertEqual(transport.batches.count, 1)
    }

    func testAMissingPerOpResultReschedulesOnlyThatOp() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        transport.onSubmit = { _ in [accepted("op-1", 1)] }

        let report = try await engine.pushOnce()

        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(report.rescheduled, 1)
        XCTAssertEqual(outbox.get("op-1")?.state, .accepted)
        XCTAssertEqual(outbox.get("op-2")?.state, .pending)
        XCTAssertEqual(outbox.get("op-2")?.retryCount, 1)
    }

    func testDuplicateCommandResultsThrowAndLeaveTheWholeBatchRetryable() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        transport.onSubmit = { _ in
            [
                accepted("op-1", 1),
                .needsReview(opId: "op-1", reviewReason: "conflicting duplicate"),
                accepted("op-2", 2),
            ]
        }

        do {
            _ = try await engine.pushOnce()
            XCTFail("expected duplicate command result to throw")
        } catch {
            XCTAssertEqual(error as? SyncEngineError, .duplicateCommandResult(opId: "op-1"))
        }
        for opId in ["op-1", "op-2"] {
            XCTAssertEqual(outbox.get(opId)?.state, .pending)
            XCTAssertEqual(outbox.get(opId)?.retryCount, 1)
            XCTAssertNotNil(outbox.get(opId)?.nextAttemptAtMs)
        }
    }

    // MARK: pushOnce — retry, backoff, auth

    func testATransportFailureReturnsTheWholeBatchToPendingWithABackoffStamp() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        transport.onSubmit = { _ in throw HubNetworkError("offline") }

        let report = try await engine.pushOnce()

        XCTAssertEqual(report.rescheduled, 1)
        let item = outbox.get("op-1")
        XCTAssertEqual(item?.state, .pending)
        XCTAssertEqual(item?.retryCount, 1)
        XCTAssertGreaterThan(item!.nextAttemptAtMs!, 1_000_000)
    }

    func testRetryWriteFailurePropagatesAndLeavesTheWholeBatchInFlightForRecovery() async throws {
        let outbox = FailingOutboxStore()
        let transport = FakeTransport()
        transport.onSubmit = { _ in throw HubNetworkError("offline") }
        let engine = makeEngine(outbox: outbox, transport: transport)
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        outbox.fail(.saveAll, afterSuccessfulCalls: 1)

        do {
            _ = try await engine.pushOnce()
            XCTFail("expected retry persistence to throw")
        } catch {
            XCTAssertEqual(error as? InjectedOutboxError, .write)
        }
        XCTAssertEqual(transport.batches.count, 1)
        XCTAssertEqual(outbox.stored("op-1")?.state, .inFlight)
        XCTAssertEqual(outbox.stored("op-2")?.state, .inFlight)
    }

    func testItemsInsideTheirBackoffWindowAreNotRedispatchedDueItemsAre() async throws {
        var nowMs: Double = 1_000_000
        let (engine, outbox, _, transport, _) = makeEngine(nowMs: { nowMs })
        _ = try engine.enqueue(envelope("op-1", 1))
        transport.onSubmit = { _ in throw HubNetworkError("offline") }
        _ = try await engine.pushOnce()

        transport.onSubmit = { batch in batch.map { accepted($0.opId, 1) } }
        let early = try await engine.pushOnce()
        XCTAssertEqual(early.submitted, 0)
        XCTAssertEqual(early.waitingBackoff, 1)

        nowMs = Double((outbox.get("op-1")?.nextAttemptAtMs ?? 0) + 1)
        let due = try await engine.pushOnce()
        XCTAssertEqual(due.submitted, 1)
        XCTAssertEqual(due.accepted, 1)
    }

    func testAnAuthFailureReportsAuthRequiredAndLeavesItemsPendingWithoutBackoff() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        transport.onSubmit = { _ in throw HubAuthError("dead token", httpStatus: 401) }

        let report = try await engine.pushOnce()

        XCTAssertTrue(report.authRequired)
        let item = outbox.get("op-1")
        XCTAssertEqual(item?.state, .pending)
        XCTAssertNil(item?.nextAttemptAtMs)
    }

    // MARK: pushOnce — dependency ordering

    func testAChildWaitsWhileItsParentIsUnresolvedThenShipsAfterTheParentCommits() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("parent", 1))
        _ = try engine.enqueue(envelope("child", 2, dependsOn: ["parent"]))

        transport.onSubmit = { batch in
            if batch.contains(where: { $0.opId == "parent" }) { throw HubNetworkError("offline") }
            return []
        }
        let first = try await engine.pushOnce()
        XCTAssertEqual(transport.batches[0].map(\.opId), ["parent"])
        XCTAssertEqual(first.waitingDependency, 1)

        let dueAt = (outbox.get("parent")?.nextAttemptAtMs ?? 0) + 1
        let engineLater = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: VolatileSyncFrontierStore(), transport: transport,
                applyChanges: { _ in }, now: { Date(timeIntervalSince1970: Double(dueAt) / 1000) }, random: { 0.5 }))
        transport.onSubmit = { batch in batch.map { accepted($0.opId, 1) } }
        _ = try await engineLater.pushOnce()
        XCTAssertEqual(transport.batches[1].map(\.opId), ["parent"])
        _ = try await engineLater.pushOnce()
        XCTAssertEqual(transport.batches[2].map(\.opId), ["child"])
        XCTAssertEqual(outbox.get("child")?.state, .accepted)
    }

    func testAChildOfATerminallyRejectedParentSurfacesAsBlockedNeverDispatched() async throws {
        let (engine, _, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("parent", 1))
        _ = try engine.enqueue(envelope("child", 2, dependsOn: ["parent"]))
        transport.onSubmit = { _ in [.rejected(opId: "parent", rejectionCode: "locked_sr")] }
        _ = try await engine.pushOnce()

        let report = try await engine.pushOnce()
        XCTAssertEqual(report.blocked, [PushReport.BlockedOp(opId: "child", reason: .deadDependency, deps: ["parent"])])
        XCTAssertFalse(transport.batches.flatMap { $0 }.contains { $0.opId == "child" })
    }

    func testAParentPrunedToTheCommittedOpLedgerStillSatisfiesItsChild() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("parent", 1))
        transport.onSubmit = { batch in batch.map { accepted($0.opId, 1) } }
        _ = try await engine.pushOnce()
        outbox.markCommittedAndRemove("parent")

        _ = try engine.enqueue(envelope("child", 2, dependsOn: ["parent"]))
        let report = try await engine.pushOnce()
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(outbox.get("child")?.state, .accepted)
    }

    // MARK: pullOnce — change-token advancement

    func testPullsAfterTheStoredFrontierAppliesChangesThenPersistsTheNewFrontier() async throws {
        let (engine, _, frontier, transport, applied) = makeEngine()
        frontier.set(ChangeToken(authorityEpoch: 1, commitSeq: 10))
        transport.onPull = { _ in
            ChangePage(
                token: ChangeToken(authorityEpoch: 1, commitSeq: 12),
                changes: [
                    .object(["entity": .string("assignment")]), .object(["entity": .string("sr")]),
                ])
        }

        let report = try await engine.pullOnce()

        XCTAssertEqual(transport.pulls[0], ChangeToken(authorityEpoch: 1, commitSeq: 10))
        XCTAssertEqual(applied.items.count, 2)
        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.frontier, ChangeToken(authorityEpoch: 1, commitSeq: 12))
        XCTAssertFalse(report.frontierReset)
        XCTAssertEqual(frontier.get(), ChangeToken(authorityEpoch: 1, commitSeq: 12))
    }

    func testRecordsAHubContactAfterAChangesPullSucceeds() async throws {
        let contacts = Box<Date>()
        let (engine, _, _, _, _) = makeEngine(
            nowMs: { ISO8601DateFormatter.parseUtc("2026-06-10T20:00:00Z").timeIntervalSince1970 * 1000 },
            onHubContact: { contacts.items.append($0) })
        _ = try await engine.pullOnce()
        XCTAssertEqual(contacts.items, [ISO8601DateFormatter.parseUtc("2026-06-10T20:00:00Z")])
    }

    func testFirstPullEverStartsFromTheZeroToken() async throws {
        let (engine, _, _, transport, _) = makeEngine()
        _ = try await engine.pullOnce()
        XCTAssertEqual(transport.pulls[0], ZERO_CHANGE_TOKEN)
    }

    func testARegressedPageTokenThrowsBeforeAnyChangeIsAppliedOrPersisted() async throws {
        let (engine, _, frontier, transport, applied) = makeEngine()
        frontier.set(ChangeToken(authorityEpoch: 1, commitSeq: 10))
        transport.onPull = { _ in
            ChangePage(
                token: ChangeToken(authorityEpoch: 1, commitSeq: 9),
                changes: [.object(["entity": .string("assignment")])])
        }

        do {
            _ = try await engine.pullOnce()
            XCTFail("expected pullOnce to throw")
        } catch {
            XCTAssertTrue(error is ChangeTokenError)
        }
        XCTAssertEqual(applied.items.count, 0)
        XCTAssertEqual(frontier.get(), ChangeToken(authorityEpoch: 1, commitSeq: 10))
    }

    func testAHigherEpochWithARestartedCommitSeqIsALegitimateAdvance() async throws {
        let (engine, _, frontier, transport, _) = makeEngine()
        frontier.set(ChangeToken(authorityEpoch: 1, commitSeq: 10))
        transport.onPull = { _ in ChangePage(token: ChangeToken(authorityEpoch: 2, commitSeq: 1), changes: []) }
        let report = try await engine.pullOnce()
        XCTAssertEqual(report.frontier, ChangeToken(authorityEpoch: 2, commitSeq: 1))
    }

    // MARK: pullOnce — stale token handling

    func testResetsTheFrontierToHubsSuggestionAndRePullsInTheSamePass() async throws {
        let (engine, _, frontier, transport, applied) = makeEngine()
        frontier.set(ChangeToken(authorityEpoch: 1, commitSeq: 99))
        let first = Box<Bool>()
        transport.onPull = { since in
            if first.items.isEmpty {
                first.items.append(true)
                throw StaleChangeTokenError("stale", resetTo: ChangeToken(authorityEpoch: 2, commitSeq: 0))
            }
            XCTAssertEqual(since, ChangeToken(authorityEpoch: 2, commitSeq: 0))
            return ChangePage(
                token: ChangeToken(authorityEpoch: 2, commitSeq: 3), changes: [.object(["entity": .string("sr")])])
        }

        let report = try await engine.pullOnce()

        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.frontier, ChangeToken(authorityEpoch: 2, commitSeq: 3))
        XCTAssertTrue(report.frontierReset)
        XCTAssertEqual(applied.items.count, 1)
        XCTAssertEqual(frontier.get(), ChangeToken(authorityEpoch: 2, commitSeq: 3))
    }

    func testWithoutASuggestedResetItRestartsFromTheZeroTokenFullResync() async throws {
        let (engine, _, _, transport, _) = makeEngine()
        let first = Box<Bool>()
        transport.onPull = { _ in
            if first.items.isEmpty {
                first.items.append(true)
                throw StaleChangeTokenError("stale")
            }
            return ChangePage(token: ChangeToken(authorityEpoch: 1, commitSeq: 1), changes: [])
        }
        let report = try await engine.pullOnce()
        XCTAssertEqual(transport.pulls[1], ZERO_CHANGE_TOKEN)
        XCTAssertTrue(report.frontierReset)
    }

    // MARK: restart recovery

    func testOrphanedInFlightRowsReturnToPendingTerminalRowsStayFrozen() async throws {
        let (engine, outbox, _, transport, _) = makeEngine()
        _ = try engine.enqueue(envelope("op-1", 1))
        _ = try engine.enqueue(envelope("op-2", 2))
        transport.onSubmit = { _ in [accepted("op-1", 1), .needsReview(opId: "op-2", reviewReason: "drift")] }
        _ = try await engine.pushOnce()
        // Simulate a crash mid-flight for a third op.
        _ = try engine.enqueue(envelope("op-3", 3))
        var item = outbox.get("op-3")!
        item.state = .inFlight
        outbox.save(item)

        let recovered = try engine.recoverOnStartup()

        XCTAssertEqual(recovered, ["op-3"])
        XCTAssertEqual(outbox.get("op-3")?.state, .pending)
        XCTAssertEqual(outbox.get("op-3")?.retryCount, 1)
        XCTAssertEqual(outbox.get("op-1")?.state, .accepted)
        XCTAssertEqual(outbox.get("op-2")?.state, .needsReview)
    }

    func testRecoveryWriteFailurePropagatesAndLeavesEveryOrphanInFlight() throws {
        let outbox = FailingOutboxStore()
        let at = "2026-06-10T10:00:00.000Z"
        for (opId, sequence) in [("op-1", 1), ("op-2", 2)] {
            outbox.seed(
                DurableSyncOutboxItem(
                    envelope: envelope(opId, sequence), state: .inFlight, createdAt: at,
                    updatedAt: at))
        }
        outbox.fail(.saveAll)
        let engine = makeEngine(outbox: outbox)

        XCTAssertThrowsError(try engine.recoverOnStartup()) { error in
            XCTAssertEqual(error as? InjectedOutboxError, .write)
        }
        XCTAssertEqual(outbox.stored("op-1")?.state, .inFlight)
        XCTAssertEqual(outbox.stored("op-2")?.state, .inFlight)
    }

    func testSyncOncePropagatesOutboxReadFailure() async throws {
        let outbox = FailingOutboxStore()
        outbox.fail(.list)
        let engine = makeEngine(outbox: outbox)

        do {
            _ = try await engine.syncOnce()
            XCTFail("expected outbox read to throw")
        } catch {
            XCTAssertEqual(error as? InjectedOutboxError, .read)
        }
    }
}
