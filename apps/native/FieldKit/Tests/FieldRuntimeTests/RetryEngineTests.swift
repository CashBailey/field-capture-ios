import FieldContracts
import FieldDomain
// Port of __tests__/runtime.test.ts (RetryEngine.sweepOnce describe block) — background retry
// engine: exponential backoff on transients; NEVER auto-retries blocked (403/409) or frozen
// (412/422) work; pauses on auth failure instead of hammering a dead token.
import XCTest

@testable import FieldRuntime

private func makeEngine(
    _ store: VolatileTicketEvidenceStore, _ submitter: FieldTicketSubmitter,
    onAuthRequired: (() -> Void)? = nil, onSweepError: ((String, Error) -> Void)? = nil,
    setTimer: ((@escaping () -> Void, Int) -> Any)? = nil, clearTimer: ((Any) -> Void)? = nil
) -> RetryEngine {
    RetryEngine(
        RetryEngineDeps(
            evidenceStore: store, submitter: submitter, policy: RetryPolicy(baseDelayMs: 1_000, maxDelayMs: 60_000),
            now: { RUNTIME_TEST_T0 }, random: { 0.5 }, setTimer: setTimer, clearTimer: clearTimer,
            onAuthRequired: onAuthRequired, onSweepError: onSweepError))
}

final class RetryEngineTests: XCTestCase {
    func testRetriesADueTransientRowWithTheSameIdempotencyKeyAndMarksAcceptance() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending, lastTransientReason: "network", attempts: 1))
        let sub = QueueSubmitter([.accepted(duplicate: false, snapshotDrift: nil, ticketId: nil)])
        let report = await makeEngine(store, sub).sweepOnce()
        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(report.rescheduled, 0)
        XCTAssertEqual(sub.calls.items.first?.idempotencyKey, "gtr:devA:0:op-0")
        XCTAssertEqual(store.get("gtr:devA:0:op-0")?.state, .accepted)
    }

    func testNeverAutoRetriesBlockedRowsTheyWaitForTheUser() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending, lastRejectionCode: "not_clocked_in"))
        store.save(runtimeTestEvidence(1, .pending, lastRejectionCode: "in_progress"))
        let sub = QueueSubmitter([])
        let report = await makeEngine(store, sub).sweepOnce()
        XCTAssertEqual(report.attempted, 0)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(sub.calls.items.count, 0)
    }

    func testNeverTouchesFrozenOrTerminalRows() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .needsReview, lastRejectionCode: "stale_version"))
        store.save(runtimeTestEvidence(1, .rejected))
        store.save(runtimeTestEvidence(2, .accepted))
        let sub = QueueSubmitter([])
        let report = await makeEngine(store, sub).sweepOnce()
        XCTAssertEqual(report.attempted, 0)
        XCTAssertEqual(sub.calls.items.count, 0)
    }

    func testRespectsTheBackoffScheduleNotDueYetSkippedDueSent() async {
        let store = VolatileTicketEvidenceStore()
        let nowMs = Int64(RUNTIME_TEST_T0.timeIntervalSince1970 * 1000)
        store.save(runtimeTestEvidence(0, .pending, nextAttemptAtMs: nowMs + 5_000))  // future
        store.save(runtimeTestEvidence(1, .pending, nextAttemptAtMs: nowMs - 1))  // past
        let sub = QueueSubmitter([.accepted(duplicate: false, snapshotDrift: nil, ticketId: nil)])
        let report = await makeEngine(store, sub).sweepOnce()
        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(sub.calls.items.first?.idempotencyKey, "gtr:devA:1:op-1")
    }

    func testReschedulesATransientFailureWithExponentialFullJitterBackoff() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending, lastTransientReason: "server", attempts: 2))
        let sub = QueueSubmitter([.transient(reason: .network, httpStatus: nil, detail: nil)])
        let report = await makeEngine(store, sub).sweepOnce()
        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.rescheduled, 1)
        let row = store.get("gtr:devA:0:op-0")
        XCTAssertEqual(row?.state, .pending)
        XCTAssertEqual(row?.attempts, 3)
        // retryCount = attempts-1 = 2 -> window = 1000 * 2^2 = 4000; random 0.5 -> +2000ms
        let nowMs = Int64(RUNTIME_TEST_T0.timeIntervalSince1970 * 1000)
        XCTAssertEqual(row?.nextAttemptAtMs, nowMs + 2_000)
    }

    func testPausesOnAuthFailureOneDeadTokenMustNotFailEveryQueuedRow() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending))
        store.save(runtimeTestEvidence(1, .pending))
        var authRequiredCalls = 0
        let sub = QueueSubmitter([.authFailed(httpStatus: 401)])
        let report = await makeEngine(store, sub, onAuthRequired: { authRequiredCalls += 1 }).sweepOnce()
        XCTAssertTrue(report.pausedForAuth)
        XCTAssertEqual(authRequiredCalls, 1)
        XCTAssertEqual(sub.calls.items.count, 1)  // second row NOT attempted
        // ponytail: FieldDomain's VolatileTicketEvidenceStore is Dictionary-backed (unlike the TS
        // Map, Swift Dictionary iteration order is unspecified), so — unlike the TS original, which
        // asserts specifically on op-0 — this only asserts that EXACTLY ONE of the two rows was
        // touched (the one `sweepOnce` happened to reach first) and it carries the auth-failed
        // marker; the other is untouched. The behavior under test (one dead token stops the pass
        // after the first hit, not both) is unaffected by which row that was.
        let touched = [store.get("gtr:devA:0:op-0"), store.get("gtr:devA:1:op-1")]
            .compactMap { $0 }.filter { $0.lastTransientReason == "auth-failed" }
        XCTAssertEqual(touched.count, 1)
        XCTAssertEqual(touched.first?.state, .pending)
    }

    func testSurvivesAThrowingSubmitterTheRowGoesBackToPendingAndTheLoopReArms() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending))
        let timers = Box<Int>()
        let errors = Box<(String, Error)>()
        struct ThrowingSubmitter: FieldTicketSubmitter {
            func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
                -> HubSubmitOutcome
            {
                struct StoreExploded: Error {}
                throw StoreExploded()
            }
        }
        let engine = RetryEngine(
            RetryEngineDeps(
                evidenceStore: store, submitter: ThrowingSubmitter(),
                policy: RetryPolicy(baseDelayMs: 1_000, maxDelayMs: 60_000), now: { RUNTIME_TEST_T0 }, random: { 0.5 },
                setTimer: { _, ms in
                    timers.items.append(ms)
                    return timers.items.count
                },
                clearTimer: { _ in },
                onSweepError: { scope, error in errors.items.append((scope, error)) }))
        engine.start()
        await flushAsync()
        // the throw was contained by submitFieldTicket: row back to pending, marked client-error
        let row = store.get("gtr:devA:0:op-0")
        XCTAssertEqual(row?.state, .pending)
        XCTAssertEqual(row?.lastTransientReason, "client-error")
        // and the loop re-armed a timer instead of dying silently
        XCTAssertGreaterThan(timers.items.count, 0)
        engine.stop()
    }

    func testStartUnGatesRowsMarkedAuthFailedFromAPreviousRunNoPermanentStarvation() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending, lastTransientReason: "auth-failed"))
        let sub = QueueSubmitter([.accepted(duplicate: false, snapshotDrift: nil, ticketId: nil)])
        let engine = makeEngine(store, sub, setTimer: { _, _ in 0 }, clearTimer: { _ in })
        engine.start()
        await flushAsync()
        XCTAssertEqual(store.get("gtr:devA:0:op-0")?.state, .accepted)
        engine.stop()
    }

    func testResumeAfterAuthClearsTheAuthGateAndRetriesTheHeldBackRows() async {
        let store = VolatileTicketEvidenceStore()
        store.save(runtimeTestEvidence(0, .pending, lastTransientReason: "auth-failed"))
        let sub = QueueSubmitter([.accepted(duplicate: false, snapshotDrift: nil, ticketId: nil)])
        let engine = makeEngine(store, sub, setTimer: { _, _ in 0 }, clearTimer: { _ in })
        XCTAssertFalse(isAutoRetryable(store.get("gtr:devA:0:op-0")!))
        engine.start()  // empty initial sweep (row gated)
        engine.resumeAfterAuth()
        await flushAsync()
        XCTAssertEqual(store.get("gtr:devA:0:op-0")?.state, .accepted)
    }
}
