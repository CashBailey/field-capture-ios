import Foundation
import FieldContracts
import FieldDomain
// Port of __tests__/app-controller.test.ts — composition-root controller: token production feeds
// every Hub call, snapshot hashes come from the cached assignment (missing -> submit REFUSED),
// restart recovery precedes the engine, and every path resolves to a state — signed out, offline,
// or Hub-down included.
import XCTest

@testable import FieldRuntime

private final class FakeTokenStore: TokenStore {
    let durability: StoreDurability = .volatileMemory
    private let lock = NSLock()
    private var storedSession: AuthSession?
    private var storedLoadHook: (() async -> Void)?

    var session: AuthSession? {
        get { withLock { storedSession } }
        set { withLock { storedSession = newValue } }
    }

    var loadHook: (() async -> Void)? {
        get { withLock { storedLoadHook } }
        set { withLock { storedLoadHook = newValue } }
    }

    func load() async throws -> AuthSession? {
        if let loadHook { await loadHook() }
        return session
    }
    func save(_ session: AuthSession) async throws { self.session = session }
    func clear() async throws { session = nil }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private let CLOCKED_IN = HubSessionStatus(
    clockedIn: true, clockedInSince: "2026-06-10T08:00:00Z", source: "timeclock", employeeId: "emp-1",
    assignmentsAvailable: true)

private func assignmentFixture() -> HubAssignment {
    HubAssignment(serviceRequestId: "sr-1", snapshotHash: "h1", snapshot: [:])
}

private final class FakeClient: HubClient {
    private let lock = NSLock()
    private var storedSubmitOutcome: HubSubmitOutcome
    let submits = Box<HubFieldTicketSubmission>()

    var submitOutcome: HubSubmitOutcome {
        get { withLock { storedSubmitOutcome } }
        set { withLock { storedSubmitOutcome = newValue } }
    }

    init(_ submitOutcome: HubSubmitOutcome) { self.storedSubmitOutcome = submitOutcome }
    func getSessionStatus(options: HubRequestOptions?) async throws -> HubSessionStatus { CLOCKED_IN }
    func getAssignments(options: HubRequestOptions?) async throws -> [HubAssignment] { [assignmentFixture()] }
    func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        submits.items.append(submission)
        return submitOutcome
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct FakeAuthApi: AuthApi {
    var loginResult: () async throws -> AuthApiResult = {
        .authenticated(session: AuthSession(sessionToken: "tok-new"))
    }
    var refreshResult: () async throws -> AuthApiResult = { .transient(reason: .network, detail: nil) }
    func login(_ credentials: AuthCredentials) async throws -> AuthApiResult { try await loginResult() }
    func refresh(_ refreshToken: String) async throws -> AuthApiResult { try await refreshResult() }
    func logout(sessionToken: String, refreshToken: String?) async throws {}
}

private struct ControllerFixture {
    let controller: AppController
    let evidenceStore: VolatileTicketEvidenceStore
    let assignmentStore: VolatileAssignmentStore
    let tokenStore: FakeTokenStore
    let client: FakeClient
    let usedTokens: Box<String>
}

private final class LockedIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func allocate() -> Int {
        lock.lock()
        defer {
            value += 1
            lock.unlock()
        }
        return value
    }

    func uuid() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "uuid-\(value)"
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private func makeController(
    signedIn: Bool = true,
    submitOutcome: HubSubmitOutcome = .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil),
    authApi: FakeAuthApi = FakeAuthApi(), syncEngine: SyncEngine? = nil, uploadEngine: UploadProcessing? = nil,
    offlinePolicyStore: OfflinePolicyStore? = nil, now: @escaping () -> Date = { TEST_APP_CONTROLLER_NOW }
) -> ControllerFixture {
    let evidenceStore = VolatileTicketEvidenceStore()
    let assignmentStore = VolatileAssignmentStore()
    let tokenStore = FakeTokenStore()
    if signedIn { tokenStore.session = AuthSession(sessionToken: "tok-live") }
    let client = FakeClient(submitOutcome)
    let usedTokens = Box<String>()
    let identitySequence = LockedIdentitySequence()
    let controller = AppController(
        AppControllerDeps(
            evidenceStore: evidenceStore, assignmentStore: assignmentStore, tokenStore: tokenStore, authApi: authApi,
            syncEngine: syncEngine, uploadEngine: uploadEngine, offlinePolicyStore: offlinePolicyStore,
            hubClientFor: { token in
                usedTokens.items.append(token)
                return client
            },
            identity: AppControllerIdentity(
                ensureDeviceInstanceId: { _ in "dev-fixed" },
                allocateLocalSeq: identitySequence.allocate),
            generateUuid: identitySequence.uuid, now: now, setTimer: { _, _ in 0 }, clearTimer: { _ in }))
    return ControllerFixture(
        controller: controller, evidenceStore: evidenceStore, assignmentStore: assignmentStore, tokenStore: tokenStore,
        client: client, usedTokens: usedTokens)
}

private let TEST_APP_CONTROLLER_NOW = ISO8601DateFormatter.parseUtc("2026-06-10T20:00:00Z")

/// Minimal V2 sync transport: records pushed batches, accepts everything, empty pulls.
private final class FakeSyncTransport: SyncCommandTransport {
    private(set) var batches: [[OperationEnvelope<JSONValue>]] = []
    func submitBatch(_ batch: [OperationEnvelope<JSONValue>]) async throws -> [CommandResult<JSONValue>] {
        batches.append(batch)
        return batch.enumerated().map { i, e in
            .accepted(opId: e.opId, token: ChangeToken(authorityEpoch: 1, commitSeq: i + 1))
        }
    }
    func pullChanges(since: ChangeToken) async throws -> ChangePage<JSONValue> {
        ChangePage(token: since, changes: [])
    }
}

private func syncEnvelope(_ opId: String, _ localSeq: Int) -> OperationEnvelope<JSONValue> {
    OperationEnvelope<JSONValue>(
        opId: opId, kind: .event, type: "dvir.submit", idempotencyKey: "gtr:dev:\(localSeq):\(opId)",
        localSeq: localSeq, dependsOn: [], payload: .object(["opId": .string(opId)]))
}

private enum StartupOutboxError: Error, Equatable {
    case read
}

private final class StartupFailingOutboxStore: SyncOutboxStore {
    let durability: StoreDurability = .volatileMemory
    var failReads = true
    private let backing = VolatileSyncOutboxStore()

    func save(_ item: DurableSyncOutboxItem) throws { backing.save(item) }
    func saveAll(_ items: [DurableSyncOutboxItem]) throws { backing.saveAll(items) }
    func get(_ opId: String) throws -> DurableSyncOutboxItem? { backing.get(opId) }
    func list() throws -> [DurableSyncOutboxItem] {
        if failReads { throw StartupOutboxError.read }
        return backing.list()
    }
    func listByState(_ state: OutboxItemState) throws -> [DurableSyncOutboxItem] {
        backing.listByState(state)
    }
    func committedOpIds() throws -> Set<String> { backing.committedOpIds() }
}

/// Wire a real SyncEngine to a real AppController exactly as the (later-ported) composition root
/// does (onEnqueue -> controller.notifyQueuedSync), so the kick path is exercised end-to-end. Fake
/// timers (from makeController) mean the runner only acts on start()/notifyQueued, never a real
/// interval.
private final class SyncControllerFixture {
    let controller: AppController
    let engine: SyncEngine
    let outbox: VolatileSyncOutboxStore
    let transport: FakeSyncTransport

    init() {
        let outbox = VolatileSyncOutboxStore()
        let transport = FakeSyncTransport()
        self.outbox = outbox
        self.transport = transport
        let box = Box<AppController>()
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: VolatileSyncFrontierStore(), transport: transport, applyChanges: { _ in },
                now: { TEST_APP_CONTROLLER_NOW }, random: { 0.5 }, onEnqueue: { box.items.first?.notifyQueuedSync() }))
        self.engine = engine
        self.controller = makeController(syncEngine: engine).controller
        box.items = [controller]
    }
}

private func flushSync() async {
    for _ in 0..<4 { try? await Task.sleep(nanoseconds: 5_000_000) }
}

private func waitUntil(timeoutSeconds: TimeInterval = 2, condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

final class SyncRunnerIntegrationViaAppControllerTests: XCTestCase {
    func testStartPropagatesRecoveryStorageFailureAndRemainsRetryable() throws {
        let outbox = StartupFailingOutboxStore()
        let engine = SyncEngine(
            SyncEngineDeps(
                outbox: outbox, frontier: VolatileSyncFrontierStore(),
                transport: FakeSyncTransport(), applyChanges: { _ in }))
        let controller = makeController(syncEngine: engine).controller

        XCTAssertThrowsError(try controller.start()) { error in
            XCTAssertEqual(error as? StartupOutboxError, .read)
        }

        outbox.failReads = false
        XCTAssertNoThrow(try controller.start())
        controller.stop()
    }

    func testStartRecoversOrphanedInFlightV2RowsAndTheRunnerPushesPendingWork() async throws {
        let f = SyncControllerFixture()
        _ = try f.engine.enqueue(syncEnvelope("op-pending", 1))
        // An orphaned in-flight row (the app died before Hub answered last run).
        let orphan = try f.engine.enqueue(syncEnvelope("op-orphan", 2))
        var inFlightOrphan = orphan
        inFlightOrphan.state = .inFlight
        f.outbox.save(inFlightOrphan)

        try f.controller.start()
        await flushSync()

        XCTAssertEqual(f.transport.batches.flatMap { $0 }.map(\.opId).sorted(), ["op-orphan", "op-pending"])
        f.controller.stop()
    }

    func testKicksAnImmediatePushWhenFreshEvidenceIsEnqueued() async throws {
        let f = SyncControllerFixture()
        try f.controller.start()
        await flushSync()
        // ignore the empty initial sweep by checking only what's pushed after this point
        let priorBatchCount = f.transport.batches.count

        _ = try f.engine.enqueue(syncEnvelope("op-1", 1))
        await flushSync()

        XCTAssertEqual(f.transport.batches[priorBatchCount...].flatMap { $0 }.map(\.opId), ["op-1"])
        f.controller.stop()
    }
}

private final class FakeUploadEngineForController: UploadProcessing {
    private let lock = NSLock()
    private var processOnceCallsValue = 0
    private var authRequiredValue = false

    var processOnceCalls: Int {
        withLock { processOnceCallsValue }
    }

    var authRequired: Bool {
        get { withLock { authRequiredValue } }
        set { withLock { authRequiredValue = newValue } }
    }

    func processOnce() async -> UploadSweepReport {
        withLock {
            processOnceCallsValue += 1
            return UploadSweepReport(authRequired: authRequiredValue)
        }
    }
    func purgeOnce() async throws -> [String] { [] }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

final class UploadRunnerIntegrationViaAppControllerTests: XCTestCase {
    func testStartStartsTheUploadRunnerNotifyQueuedUploadKicksASweep() async throws {
        let engine = FakeUploadEngineForController()
        let f = makeController(uploadEngine: engine)
        try f.controller.start()
        await flushSync()
        XCTAssertEqual(engine.processOnceCalls, 1)  // runner started + drove a sweep
        f.controller.notifyQueuedUpload()
        await flushSync()
        XCTAssertEqual(engine.processOnceCalls, 2)  // the kick drove another
        f.controller.stop()
    }

    func testOnForegroundReValidatesTheSessionAndResumesARunnerThatPausedForAuth() async throws {
        let engine = FakeUploadEngineForController()
        engine.authRequired = true  // the first sweep pauses the runner (dead token)
        let f = makeController(uploadEngine: engine)
        try f.controller.start()
        await flushSync()
        XCTAssertEqual(engine.processOnceCalls, 1)  // ran once, then paused-for-auth

        engine.authRequired = false  // a silent refresh would now succeed
        try await f.controller.onForeground()  // valid session -> getSession resumes the paused runner + kicks
        await flushSync()
        XCTAssertGreaterThanOrEqual(engine.processOnceCalls, 2)  // resumed and swept again
        f.controller.stop()
    }

    func testOnForegroundDoesNotResumeWhileStillSignedOut() async throws {
        let engine = FakeUploadEngineForController()
        engine.authRequired = true
        let f = makeController(signedIn: false, uploadEngine: engine)
        try f.controller.start()
        await flushSync()
        let afterStart = engine.processOnceCalls  // paused-for-auth

        try await f.controller.onForeground()  // session still auth-required -> no resume, no kick
        await flushSync()
        XCTAssertEqual(engine.processOnceCalls, afterStart)
        f.controller.stop()
    }
}

final class GetSyncSessionTokenTests: XCTestCase {
    func testReturnsTheLiveSessionTokenWhenSignedIn() async throws {
        let f = makeController()
        let token = try await f.controller.getSyncSessionToken()
        XCTAssertEqual(token, "tok-live")
    }

    func testThrowsHubAuthErrorWhenSignedOut() async throws {
        let f = makeController(signedIn: false)
        do {
            _ = try await f.controller.getSyncSessionToken()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is HubAuthError)
        }
    }

    func testThrowsHubNetworkErrorWhenSessionUnavailable() async throws {
        let f = makeController()
        // Expiring session (now is 2026-06-10T20:00:00Z, so this is inside the 60s margin) + the
        // default authApi.refresh returning transient/network => getValidSession resolves
        // 'unavailable'. Distinct from the auth-pause path.
        f.tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T19:59:30.000Z", refreshToken: "r")
        do {
            _ = try await f.controller.getSyncSessionToken()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is HubNetworkError)
        }
    }
}

private func rawEvidence(
    _ opId: String, _ serviceRequestId: String, _ state: OutboxItemState, _ localSeq: Int = 0,
    rejectionCode: String? = nil, device: String = "dev"
) -> TicketEvidence {
    let idempotencyKey = "gtr:\(device):\(localSeq):\(opId)"
    return TicketEvidence(
        envelope: OperationEnvelope<HubFieldTicketSubmission>(
            opId: opId, kind: .command, type: "ticket.submit", idempotencyKey: idempotencyKey,
            localSeq: localSeq, dependsOn: [],
            payload: HubFieldTicketSubmission(
                idempotencyKey: idempotencyKey, serviceRequestId: serviceRequestId, snapshotHash: "h1",
                ticketNo: "T-\(opId)", quantityBbl: 1, disposalTicketNo: "D-\(opId)")),
        state: state, attempts: 0, createdAt: "2026-06-10T19:00:00.000Z", updatedAt: "2026-06-10T19:00:00.000Z",
        lastRejectionCode: rejectionCode)
}

final class AppControllerTests: XCTestCase {
    func testStartSweepsOrphanedInFlightEvidenceBeforeTheRetryEngineRuns() async throws {
        let f = makeController()
        f.evidenceStore.save(rawEvidence("op-0", "sr-1", .inFlight, 0, device: "dev-fixed"))

        let recovery = try f.controller.start()
        XCTAssertEqual(recovery.recoveredKeys, ["gtr:dev-fixed:0:op-0"])
        // The sweep unblocked the orphan (in-flight would deadlock the double-submit guard), and
        // the engine then retried it with the SAME key — Hub accepted, so it lands durable.
        await flushSync()
        XCTAssertEqual(f.evidenceStore.get("gtr:dev-fixed:0:op-0")?.state, .accepted)
        XCTAssertEqual(try f.controller.start().recoveredKeys, [])  // idempotent
        f.controller.stop()
    }

    func testRefusesToSubmitWhenNoCachedAssignmentProvidesTheSnapshotHash() async throws {
        let f = makeController()
        let result = try await f.controller.submitNewTicket(
            TicketDraft(
                serviceRequestId: "sr-unknown", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        guard case .assignmentMissing(let srId) = result else {
            return XCTFail("expected assignmentMissing, got \(result)")
        }
        XCTAssertEqual(srId, "sr-unknown")
        XCTAssertEqual(f.client.submits.items.count, 0)
        XCTAssertEqual(f.evidenceStore.list().count, 0)
    }

    func testResolvesTheSnapshotHashFromTheAssignmentStoreAndEchoesItOnTheWire() async throws {
        let f = makeController()
        f.assignmentStore.putAssignments([assignmentFixture()])
        let result = try await f.controller.submitNewTicket(
            TicketDraft(
                serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        guard case .accepted = result else { return XCTFail("expected accepted, got \(result)") }
        XCTAssertEqual(f.client.submits.items.first?.serviceRequestId, "sr-1")
        XCTAssertEqual(f.client.submits.items.first?.snapshotHash, "h1")
        XCTAssertEqual(f.client.submits.items.first?.idempotencyKey, "gtr:dev-fixed:0:uuid-1")
    }

    func testSignedOutNotSignedInNothingRecordedNothingSent() async throws {
        let f = makeController(signedIn: false)
        let result = try await f.controller.submitNewTicket(
            TicketDraft(
                serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        guard case .notSignedIn = result else { return XCTFail("expected notSignedIn, got \(result)") }
        XCTAssertEqual(f.client.submits.items.count, 0)
        XCTAssertEqual(f.evidenceStore.list().count, 0)
    }

    func testSessionRefreshUnavailableOfflineEvidenceRecordedDurablePendingNoWireCall() async throws {
        let f = makeController()
        f.assignmentStore.putAssignments([assignmentFixture()])
        f.tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T20:00:30.000Z", refreshToken: "r")
        let result = try await f.controller.submitNewTicket(
            TicketDraft(
                serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        guard case .pendingRetry = result else { return XCTFail("expected pendingRetry, got \(result)") }
        XCTAssertEqual(f.client.submits.items.count, 0)  // never used a token it could not validate
        let saved = f.evidenceStore.list()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.state, .pending)
        XCTAssertEqual(saved.first?.attempts, 1)
    }

    func testRefreshSessionResolvesToLockedAuthFailedWhenSignedOut() async throws {
        let f = makeController(signedIn: false)
        let result = try await f.controller.refreshSession()
        guard case .locked(let reason, _) = result.gate else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, .authFailed)
        guard case .notPulled = result.assignments else { return XCTFail("expected notPulled") }
    }

    func testRefreshSessionPullsGateAndAssignmentsWithTheLiveTokenWhenSignedIn() async throws {
        let f = makeController()
        let result = try await f.controller.refreshSession()
        guard case .unlocked = result.gate else { return XCTFail("expected unlocked") }
        guard case .synced(let count) = result.assignments else { return XCTFail("expected synced") }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(f.assignmentStore.getSnapshotHash("sr-1"), "h1")
        XCTAssertEqual(f.usedTokens.items, ["tok-live"])
    }

    func testRecordsDurableLastHubContactOnSuccessfulSessionRefreshButNotSignedOutOfflineStates() async throws {
        let offlinePolicyStore = VolatileOfflinePolicyStore()
        let f = makeController(offlinePolicyStore: offlinePolicyStore)
        _ = try await f.controller.refreshSession()
        XCTAssertEqual(
            offlinePolicyStore.getState().lastHubContactAtMs,
            Int64(TEST_APP_CONTROLLER_NOW.timeIntervalSince1970 * 1000))

        let signedOutStore = VolatileOfflinePolicyStore()
        let signedOut = makeController(signedIn: false, offlinePolicyStore: signedOutStore)
        _ = try await signedOut.controller.refreshSession()
        XCTAssertNil(signedOutStore.getState().lastHubContactAtMs)

        let offlineStore = VolatileOfflinePolicyStore()
        let offlineFixture = makeController(offlinePolicyStore: offlineStore)
        offlineFixture.tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T19:59:30.000Z", refreshToken: "r")
        _ = try await offlineFixture.controller.refreshSession()
        XCTAssertNil(offlineStore.getState().lastHubContactAtMs)
    }

    func testLoginAndCheckGateRecordDurableHubContactAndExposeTheEvaluatedOfflinePolicy() async throws {
        let offlinePolicyStore = VolatileOfflinePolicyStore()
        let f = makeController(signedIn: false, offlinePolicyStore: offlinePolicyStore)

        _ = try await f.controller.login(AuthCredentials(username: "driver", password: "pw"))
        XCTAssertEqual(
            offlinePolicyStore.getState().lastHubContactAtMs,
            Int64(TEST_APP_CONTROLLER_NOW.timeIntervalSince1970 * 1000))
        offlinePolicyStore.recordHubContact(
            Int64(ISO8601DateFormatter.parseUtc("2026-06-10T18:00:00Z").timeIntervalSince1970 * 1000))
        _ = try await f.controller.checkGate()
        XCTAssertEqual(
            offlinePolicyStore.getState().lastHubContactAtMs,
            Int64(TEST_APP_CONTROLLER_NOW.timeIntervalSince1970 * 1000))
        let policy = f.controller.offlinePolicy(ISO8601DateFormatter.parseUtc("2026-06-10T21:00:00Z"))
        XCTAssertEqual(policy?.state, .offlineWithinLimit)
    }

    func testLoginStoresTheNewSessionLogoutClearsItButPreservesUnsyncedEvidence() async throws {
        let f = makeController(
            signedIn: false, submitOutcome: .transient(reason: .network, httpStatus: nil, detail: nil))
        guard case .signedIn = try await f.controller.login(AuthCredentials(username: "driver", password: "pw")) else {
            return XCTFail("expected signedIn")
        }
        XCTAssertEqual(f.tokenStore.session, AuthSession(sessionToken: "tok-new"))

        f.assignmentStore.putAssignments([assignmentFixture()])
        _ = try await f.controller.submitNewTicket(
            TicketDraft(serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        XCTAssertEqual(f.evidenceStore.list().count, 1)

        try await f.controller.logout()
        XCTAssertNil(f.tokenStore.session)
        XCTAssertEqual(f.evidenceStore.list().count, 1)  // sign-out never destroys field work
    }

    func testDoubleTapRepeatedSubmitOfTheSameDraftNeverMintsASecondIdempotencyKey() async throws {
        let f = makeController(submitOutcome: .transient(reason: .network, httpStatus: nil, detail: nil))
        f.assignmentStore.putAssignments([assignmentFixture()])
        let draft = TicketDraft(serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9")
        guard case .pendingRetry = try await f.controller.submitNewTicket(draft) else {
            return XCTFail("expected pendingRetry")
        }
        guard case .pendingRetry = try await f.controller.submitNewTicket(draft) else {
            return XCTFail("expected pendingRetry")
        }
        // ONE evidence row, ONE key, both wire calls (if any) under the same key
        XCTAssertEqual(f.evidenceStore.list().count, 1)
        let keys = Set(f.client.submits.items.map(\.idempotencyKey))
        XCTAssertEqual(keys.count, 1)
    }

    func testConcurrentDoubleTapSharesOneSubmissionAndOneIdempotencyKey() async throws {
        let f = makeController()
        f.assignmentStore.putAssignments([assignmentFixture()])
        let draft = TicketDraft(serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9")
        let sessionLoadStarted = expectation(description: "session load started")
        let sessionGate = TestAsyncGate()
        f.tokenStore.loadHook = {
            sessionLoadStarted.fulfill()
            await sessionGate.wait()
        }
        let controller = f.controller
        let evidenceStore = f.evidenceStore
        let client = f.client

        async let first = controller.submitNewTicket(draft)
        async let second = controller.submitNewTicket(draft)

        await fulfillment(of: [sessionLoadStarted], timeout: 2)
        await sessionGate.open()
        let results = try await [first, second]

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(evidenceStore.list().count, 1)
        XCTAssertEqual(client.submits.items.count, 1)
        XCTAssertEqual(Set(client.submits.items.map(\.idempotencyKey)).count, 1)
    }

    func testResubmitEvidenceRetriesABlockedRowWithItsOriginalKeyAfterTheUserActs() async throws {
        let f = makeController(
            submitOutcome: .rejected(kind: .blocked, httpStatus: 403, rejectionCode: "not_clocked_in", detail: nil))
        f.assignmentStore.putAssignments([assignmentFixture()])
        let draft = TicketDraft(serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9")
        guard case .blocked(let rejectionCode, _, _, let key) = try await f.controller.submitNewTicket(draft) else {
            return XCTFail("expected blocked")
        }
        XCTAssertEqual(rejectionCode, "not_clocked_in")
        // driver clocks in; Hub now accepts.
        f.client.submits.items.removeAll()
        f.client.submitOutcome = .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil)
        guard case .accepted(_, _, let acceptedKey) = try await f.controller.resubmitEvidence(key) else {
            return XCTFail("expected accepted")
        }
        XCTAssertEqual(acceptedKey, key)
        XCTAssertEqual(f.client.submits.items.first?.idempotencyKey, key)  // SAME key on the wire
        XCTAssertEqual(f.evidenceStore.list().count, 1)
    }

    func testResubmitEvidenceNeverResubmitsFrozenRowsAndReportsAMissingKeyAsAState() async throws {
        let f = makeController(
            submitOutcome: .rejected(kind: .needsReview, httpStatus: 412, rejectionCode: "stale_version", detail: nil))
        f.assignmentStore.putAssignments([assignmentFixture()])
        guard
            case .needsReview(_, _, _, let key) = try await f.controller.submitNewTicket(
                TicketDraft(
                    serviceRequestId: "sr-1", ticketNo: "T-9", quantityBbl: 5, disposalTicketNo: "D-9"))
        else {
            return XCTFail("expected needsReview")
        }
        guard case .needsReview(let rejectionCode, _, _, _) = try await f.controller.resubmitEvidence(key) else {
            return XCTFail("expected needsReview")
        }
        XCTAssertEqual(rejectionCode, "stale_version")
        guard case .evidenceMissing(let missingKey) = try await f.controller.resubmitEvidence("gtr:nope:0:x") else {
            return XCTFail("expected evidenceMissing")
        }
        XCTAssertEqual(missingKey, "gtr:nope:0:x")
    }

    func testObservingAValidSessionResumesARetryEnginePausedForAuthSilentRefreshCase() async throws {
        let f = makeController(signedIn: false)
        f.assignmentStore.putAssignments([assignmentFixture()])
        try f.controller.start()
        // engine pauses: a queued row dispatches against no session -> auth-failed
        f.evidenceStore.save(rawEvidence("op-q", "sr-1", .pending, 7, device: "dev-fixed"))
        _ = await f.controller.retryEngine.sweepOnce()
        XCTAssertTrue(f.controller.retryEngine.isPausedForAuth())
        // a session appears WITHOUT an interactive login (e.g. restored externally)
        f.tokenStore.session = AuthSession(sessionToken: "tok-restored")
        _ = try await f.controller.refreshSession()  // observes valid -> resumes the engine
        let accepted = await waitUntil {
            f.evidenceStore.get("gtr:dev-fixed:7:op-q")?.state == .accepted
        }
        XCTAssertFalse(f.controller.retryEngine.isPausedForAuth())
        XCTAssertTrue(accepted)
        XCTAssertEqual(f.evidenceStore.get("gtr:dev-fixed:7:op-q")?.state, .accepted)
        f.controller.stop()
    }

    func testOutboxSummaryReportsFiniteCountsByStateSplittingBlockedFromRetryablePending() {
        let f = makeController()
        f.evidenceStore.save(rawEvidence("op-0", "sr-1", .pending, 0))
        f.evidenceStore.save(rawEvidence("op-1", "sr-1", .pending, 1, rejectionCode: "not_clocked_in"))
        f.evidenceStore.save(rawEvidence("op-2", "sr-1", .needsReview, 2))
        f.evidenceStore.save(rawEvidence("op-3", "sr-1", .accepted, 3))
        let summary = f.controller.outboxSummary()
        XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(summary.blocked, 1)
        XCTAssertEqual(summary.needsReview, 1)
        XCTAssertEqual(summary.accepted, 1)
        XCTAssertEqual(summary.inFlight, 0)
    }

    func testSrSyncStateByIdRollsTicketEvidenceUpPerSrWorstStateFirst() {
        let f = makeController()
        // sr-A has both accepted AND still-owed pending -> worst-first makes it needs-sync.
        f.evidenceStore.save(rawEvidence("op-0", "sr-A", .accepted, 0))
        f.evidenceStore.save(rawEvidence("op-1", "sr-A", .pending, 1))
        f.evidenceStore.save(rawEvidence("op-2", "sr-B", .accepted, 2))
        f.evidenceStore.save(rawEvidence("op-3", "sr-C", .needsReview, 3))

        let byId = f.controller.srSyncStateById()
        XCTAssertEqual(byId["sr-A"], .needsSync)
        XCTAssertEqual(byId["sr-B"], .synced)
        XCTAssertEqual(byId["sr-C"], .needsReview)
        XCTAssertNil(byId["sr-never"])  // SRs with no local work are simply absent
    }

    func testSyncCenterSummaryBucketsLocalDraftsAndEvidenceIntoWorkerFacingCategories() {
        let f = makeController()
        f.evidenceStore.save(rawEvidence("op-0", "sr-A", .pending, 0))  // waiting-to-sync
        // waiting-on-you
        f.evidenceStore.save(rawEvidence("op-1", "sr-B", .pending, 1, rejectionCode: "not_clocked_in"))
        f.evidenceStore.save(rawEvidence("op-2", "sr-C", .accepted, 2))  // accepted-by-hub
        f.evidenceStore.save(rawEvidence("op-3", "sr-D", .needsReview, 3))  // needs-review

        let summary = f.controller.syncCenterSummary(2)  // 2 local drafts not yet submitted
        XCTAssertEqual(summary.counts[.savedOnPhone], 2)
        XCTAssertEqual(summary.counts[.waitingToSync], 1)
        XCTAssertEqual(summary.counts[.waitingOnYou], 1)
        XCTAssertEqual(summary.counts[.acceptedByHub], 1)
        XCTAssertEqual(summary.counts[.needsReview], 1)
        XCTAssertEqual(summary.counts[.rejectedByHub], 0)
        XCTAssertTrue(summary.hasOutstanding)
    }
}
