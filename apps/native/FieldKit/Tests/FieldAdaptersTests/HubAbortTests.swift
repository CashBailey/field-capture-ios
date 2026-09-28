import FieldDomain
// Port of apps/mobile/__tests__/hub-abort.test.ts (request abort/cancellation).
//
// Deviation from the TS: the TS threads an explicit `AbortSignal` through a per-call `options`
// parameter. Swift has no such object — structured concurrency's Task cancellation is the
// platform-native equivalent (see `BoundedFetch.swift`'s header), so "the caller cancels this
// specific call" becomes "the caller cancels the `Task` running this specific call" below. What
// must still hold, ported 1:1:
//  - a timeout ABORTS the underlying network work (the fetch observes cancellation), not just a
//    local race that leaves the socket draining battery/data;
//  - canceling the calling Task cancels an in-flight request promptly;
//  - an aborted submit never strands its evidence in-flight — the row returns to `pending` and a
//    later retry with the SAME idempotency key succeeds;
//  - a fetch implementation that ignores cancellation is still time-bounded (race backstop).
import XCTest

@testable import FieldAdapters

private func jsonResponse(_ status: Int, _ body: Any) -> HubHttpResponse {
    let data = try! JSONSerialization.data(withJSONObject: body)
    return HubHttpResponse(status: status, body: data)
}

/// A fetch that never resolves on its own but throws once its (ambient) Task is canceled — the
/// Swift analog of the TS `signalAwareHungFetch` (which rejects when `init.signal` fires abort).
private func signalAwareHungFetch() -> (fetchFn: HubFetch, observedCancellation: LockedBox<[Bool]>) {
    let seen = LockedBox<[Bool]>([])
    let fetchFn: HubFetch = { _, _ in
        // `Task.sleep` itself throws `CancellationError` the instant it notices cancellation
        // (rather than returning normally), so a plain `while !Task.isCancelled { try await
        // Task.sleep(...) }` would propagate that throw straight out of the sleep call and never
        // reach the `seen.mutate` below. Swallow that particular throw with `try?` and let the
        // loop's own `Task.isCancelled` check (next line) observe and record the cancellation.
        while true {
            if Task.isCancelled {
                seen.mutate { $0.append(true) }
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    return (fetchFn, seen)
}

private let CONFIG_BASE_URL = "http://hub.test"
private let CONFIG_SESSION_TOKEN = "tok-123"

private let INPUT = FieldTicketInput(
    serviceRequestId: "sr-9", snapshotHash: "hash-abc", ticketNo: "12345", quantityBbl: 120,
    disposalTicketNo: "D-123", deviceInstanceId: "devA", localSeq: 1, opUuid: "op-1"
)

final class HubAbortTests: XCTestCase {
    // MARK: - timeout aborts real network work

    func test_get_timeoutAbortsRealNetworkWork() async throws {
        let (fetchFn, seen) = signalAwareHungFetch()
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 10)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await client.getSessionStatus() }
        XCTAssertEqual(seen.value, [true])
    }

    func test_submit_timeoutMapsToTransientAndAborts() async throws {
        let (fetchFn, seen) = signalAwareHungFetch()
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 10)
        let outcome = try await client.submitFieldTicket(
            HubFieldTicketSubmission(
                idempotencyKey: "gtr:devA:1:op-1", serviceRequestId: "sr-9", snapshotHash: "hash-abc",
                ticketNo: "12345", quantityBbl: 120, disposalTicketNo: "D-123"
            ))
        guard case .transient(let reason, _, _) = outcome else { return XCTFail("expected transient, got \(outcome)") }
        XCTAssertEqual(reason, .network)
        XCTAssertEqual(seen.value, [true])
    }

    func test_fetchThatIgnoresCancellationIsStillTimeBounded() async throws {
        // Simulates a fetch implementation that never checks cancellation at all — the timeout
        // timer still wins the race (see `BoundedFetch.withTimeout`), exactly mirroring the TS
        // race-backstop test.
        let ignoresCancellation: HubFetch = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return jsonResponse(200, [:])
        }
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: ignoresCancellation, timeoutMs: 10)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await client.getAssignments() }
    }

    // MARK: - caller cancellation

    func test_externalCancellationAbortsInFlightGetPromptly() async throws {
        let (fetchFn, seen) = signalAwareHungFetch()
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 60_000)
        let task = Task { try await client.getSessionStatus() }
        try await Task.sleep(nanoseconds: 20_000_000)  // let the request actually start
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the call to throw")
        } catch is HubNetworkError {
            // expected
        } catch {
            XCTFail("expected HubNetworkError, got \(error)")
        }
        XCTAssertEqual(seen.value, [true])
    }

    func test_alreadyCanceledTaskNeverDispatchesNetworkWork() async throws {
        let callCount = LockedBox<Int>(0)
        let fetchFn: HubFetch = { _, _ in
            callCount.mutate { $0 += 1 }
            return jsonResponse(200, ["assignments": [Any]()])
        }
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 60_000)
        let task = Task { try await client.getAssignments() }
        task.cancel()  // canceled before the task body has a chance to run
        do {
            _ = try await task.value
            XCTFail("expected the call to throw")
        } catch {
            // CancellationError, wrapped as HubNetworkError by getAssignments' getJson catch.
        }
        XCTAssertEqual(callCount.value, 0)
    }

    func test_externalCancellationCancelsInFlightSubmitAsTransient() async throws {
        let (fetchFn, _) = signalAwareHungFetch()
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 60_000)
        let task = Task {
            try await client.submitFieldTicket(
                HubFieldTicketSubmission(
                    idempotencyKey: "gtr:devA:1:op-1", serviceRequestId: "sr-9", snapshotHash: "hash-abc",
                    ticketNo: "12345", quantityBbl: 120, disposalTicketNo: "D-123"
                ))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let outcome = try await task.value
        guard case .transient(let reason, _, _) = outcome else { return XCTFail("expected transient, got \(outcome)") }
        XCTAssertEqual(reason, .network)
    }

    // MARK: - abort never leaks in-flight submit state

    func test_afterTimeoutAbortedSubmitEvidenceIsPendingNotStuckInFlight() async throws {
        let (fetchFn, _) = signalAwareHungFetch()
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: fetchFn, timeoutMs: 10)
        let store = VolatileTicketEvidenceStore()

        let result = try await FieldDomain.submitFieldTicket(
            SubmitFieldTicketDeps(submitter: client, evidenceStore: store), INPUT)
        guard case .pendingRetry = result else { return XCTFail("expected pendingRetry, got \(result)") }

        let evidence = store.get("gtr:devA:1:op-1")
        XCTAssertEqual(evidence?.state, .pending)  // NOT in-flight
        XCTAssertEqual(evidence?.attempts, 1)
    }

    func test_retryAfterAbortedAttemptReusesSameKeyAndCanSucceed() async throws {
        let store = VolatileTicketEvidenceStore()
        let (hungFetch, _) = signalAwareHungFetch()
        let failing = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: hungFetch, timeoutMs: 10)
        _ = try await FieldDomain.submitFieldTicket(
            SubmitFieldTicketDeps(submitter: failing, evidenceStore: store), INPUT)

        let keys = LockedBox<[String]>([])
        let ok: HubFetch = { _, requestInit in
            keys.mutate { $0.append(requestInit.headers["Idempotency-Key"] ?? "") }
            return jsonResponse(200, ["accepted": true, "ticket_id": "ft-1"])
        }
        let succeeding = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: ok, timeoutMs: 60_000)
        let retry = try await FieldDomain.submitFieldTicket(
            SubmitFieldTicketDeps(submitter: succeeding, evidenceStore: store), INPUT)

        guard case .accepted = retry else { return XCTFail("expected accepted, got \(retry)") }
        XCTAssertEqual(keys.value, ["gtr:devA:1:op-1"])  // same idempotency key — Hub can never double-create
        XCTAssertEqual(store.get("gtr:devA:1:op-1")?.state, .accepted)
    }
}
