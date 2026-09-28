import Foundation
import FieldContracts
// Port of __tests__/submit-field-ticket.test.ts — minimal field-ticket submit path.
import XCTest

@testable import FieldDomain

private final class FakeSubmitter: FieldTicketSubmitter {
    private let outcome: () async throws -> HubSubmitOutcome
    private(set) var calls: [HubFieldTicketSubmission] = []

    init(_ outcome: @escaping () async throws -> HubSubmitOutcome) {
        self.outcome = outcome
    }

    func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        calls.append(submission)
        return try await outcome()
    }
}

private let INPUT = FieldTicketInput(
    serviceRequestId: "sr-9", snapshotHash: "hash-abc", ticketNo: "12345", quantityBbl: 120,
    disposalTicketNo: "D-123", deviceInstanceId: "devA", localSeq: 1, opUuid: "op-uuid-1"
)
private let EXPECTED_KEY = "gtr:devA:1:op-uuid-1"

final class SubmitFieldTicketTests: XCTestCase {
    func testBuildsTheIdempotencyKeyWithTheContractsHelperAndSendsTheFullPayload() async throws {
        let store = VolatileTicketEvidenceStore()
        let sub = FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: "ft-1") }
        _ = try await submitFieldTicket(SubmitFieldTicketDeps(submitter: sub, evidenceStore: store), INPUT)
        XCTAssertEqual(sub.calls.count, 1)
        XCTAssertEqual(
            sub.calls[0],
            HubFieldTicketSubmission(
                idempotencyKey: EXPECTED_KEY, serviceRequestId: "sr-9", snapshotHash: "hash-abc",
                ticketNo: "12345", quantityBbl: 120, disposalTicketNo: "D-123"
            ))
        // sanity: the key really is the contracts format
        let parsedKey = try parseIdempotencyKey(EXPECTED_KEY)
        XCTAssertEqual(parsedKey.deviceInstanceId, "devA")
        XCTAssertEqual(parsedKey.localSeq, 1)
        XCTAssertEqual(parsedKey.opUuid, "op-uuid-1")
    }

    func testMarksTheEvidenceAcceptedOnlyAfterHubAccepts() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) },
                evidenceStore: store),
            INPUT
        )
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: nil, idempotencyKey: EXPECTED_KEY))
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .accepted)
    }

    func testTreatsDuplicateAcceptedAsDurableSuccess() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .accepted(duplicate: true, snapshotDrift: nil, ticketId: nil) },
                evidenceStore: store),
            INPUT
        )
        XCTAssertEqual(result, .accepted(duplicate: true, snapshotDrift: nil, idempotencyKey: EXPECTED_KEY))
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .accepted)
    }

    func testPreservesLocalEvidenceAsPendingOnNetworkFailure() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .transient(reason: .network, httpStatus: nil, detail: "offline") },
                evidenceStore: store),
            INPUT
        )
        XCTAssertEqual(result, .pendingRetry(reason: "network", idempotencyKey: EXPECTED_KEY))
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .pending)
        XCTAssertEqual(evidence?.attempts, 1)
        XCTAssertEqual(evidence?.envelope.payload.ticketNo, "12345")
        XCTAssertEqual(evidence?.envelope.payload.quantityBbl, 120)
    }

    func testPreservesEvidenceOn5xxTheSameWay() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .transient(reason: .server, httpStatus: 503, detail: nil) },
                evidenceStore: store),
            INPUT
        )
        guard case .pendingRetry(let reason, _) = result else { return XCTFail("expected pendingRetry") }
        XCTAssertEqual(reason, "server")
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .pending)
    }

    func testRefusesToSubmitWithoutASnapshotHash() async throws {
        let store = VolatileTicketEvidenceStore()
        let sub = FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) }
        for snapshotHash in ["", "   "] {
            var input = INPUT
            input.snapshotHash = snapshotHash
            let result = try await submitFieldTicket(SubmitFieldTicketDeps(submitter: sub, evidenceStore: store), input)
            XCTAssertEqual(result, .notSubmitted(reason: .missingSnapshotHash, idempotencyKey: EXPECTED_KEY))
        }
        XCTAssertEqual(sub.calls.count, 0)  // nothing went on the wire
        XCTAssertEqual(store.list().count, 0)  // and no evidence was created for a refused input
    }

    func testPreservesFullRejectionDetailOnTheEvidence() async throws {
        let store = VolatileTicketEvidenceStore()
        let now = { isoTestDate("2026-06-10T15:30:00.000Z") }
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter {
                    .rejected(
                        kind: .needsReview, httpStatus: 422, rejectionCode: "idempotency_mismatch",
                        detail: "key reused with a different payload")
                },
                evidenceStore: store, now: now
            ),
            INPUT
        )
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .needsReview)
        XCTAssertEqual(evidence?.lastRejectionCode, "idempotency_mismatch")
        XCTAssertEqual(evidence?.lastDetail, "key reused with a different payload")
        XCTAssertEqual(evidence?.lastHttpStatus, 422)
        XCTAssertEqual(evidence?.lastOutcomeAt, "2026-06-10T15:30:00.000Z")
        XCTAssertEqual(evidence?.updatedAt, "2026-06-10T15:30:00.000Z")
    }

    func testStampsCreatedUpdatedTimestampsAndReplacesStaleFailureDetailOnEachNewOutcome() async throws {
        let store = VolatileTicketEvidenceStore()
        var tick: Int64 = 0
        let now = { () -> Date in
            tick += 1
            return Date(timeIntervalSince1970: Double(1_750_000_000 + tick))
        }
        // First attempt: blocked (403). lastRejectionCode marks it user-action-gated.
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter {
                    .rejected(kind: .blocked, httpStatus: 403, rejectionCode: "not_clocked_in", detail: nil)
                },
                evidenceStore: store, now: now
            ),
            INPUT
        )
        let afterBlock = store.get(EXPECTED_KEY)
        XCTAssertEqual(afterBlock?.lastRejectionCode, "not_clocked_in")
        let createdAt = try XCTUnwrap(afterBlock?.createdAt)

        // Second attempt (user clocked in, taps retry): transient network failure. The stale
        // rejection code must NOT linger — the item is now retryable by the engine again.
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .transient(reason: .network, httpStatus: nil, detail: "offline") },
                evidenceStore: store, now: now
            ),
            INPUT
        )
        let afterTransient = store.get(EXPECTED_KEY)
        XCTAssertNil(afterTransient?.lastRejectionCode)
        XCTAssertEqual(afterTransient?.lastTransientReason, "network")
        XCTAssertEqual(afterTransient?.lastDetail, "offline")
        XCTAssertEqual(afterTransient?.createdAt, createdAt)  // creation time never changes
        XCTAssertEqual(afterTransient?.attempts, 2)
    }

    func testMarksAuthFailuresDistinctlySoTheRetryEngineCanPauseForReAuth() async throws {
        let store = VolatileTicketEvidenceStore()
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: FakeSubmitter { .authFailed(httpStatus: 401) }, evidenceStore: store),
            INPUT
        )
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .pending)
        XCTAssertEqual(evidence?.lastTransientReason, "auth-failed")
        XCTAssertEqual(evidence?.lastHttpStatus, 401)
    }

    func testContainsAThrowingSubmitterEvidenceReturnsToPending() async throws {
        struct KeystoreError: Error, CustomStringConvertible { var description: String { "keystore unavailable" } }
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: FakeSubmitter { throw KeystoreError() }, evidenceStore: store),
            INPUT
        )
        XCTAssertEqual(result, .pendingRetry(reason: "client-error", idempotencyKey: EXPECTED_KEY))
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .pending)  // NOT in-flight — the double-submit guard must not deadlock
        XCTAssertEqual(evidence?.attempts, 1)
        XCTAssertEqual(evidence?.lastTransientReason, "client-error")
        XCTAssertTrue(evidence?.lastDetail?.contains("keystore unavailable") == true)
        // and the operation is retryable with the SAME key afterwards
        let retry = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) },
                evidenceStore: store),
            INPUT
        )
        guard case .accepted = retry else { return XCTFail("expected accepted") }
    }

    func testMapsABlockedHubRejectionToAUserVisibleBlockedStateEvidenceKeptPending() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter {
                    .rejected(kind: .blocked, httpStatus: 403, rejectionCode: "not_clocked_in", detail: "no open punch")
                },
                evidenceStore: store
            ),
            INPUT
        )
        XCTAssertEqual(
            result,
            .blocked(
                rejectionCode: "not_clocked_in", httpStatus: 403, detail: "no open punch", idempotencyKey: EXPECTED_KEY)
        )
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .pending)  // retryable after the driver clocks in
        XCTAssertEqual(evidence?.lastRejectionCode, "not_clocked_in")
    }

    func testMapsA412StyleSnapshotDriftRejectionToNeedsReviewAndFreezesTheEvidence() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter {
                    .rejected(kind: .needsReview, httpStatus: 412, rejectionCode: "stale_version", detail: nil)
                },
                evidenceStore: store
            ),
            INPUT
        )
        guard case .needsReview(let rejectionCode, let httpStatus, _, _) = result else {
            return XCTFail("expected needsReview")
        }
        XCTAssertEqual(rejectionCode, "stale_version")
        XCTAssertEqual(httpStatus, 412)
        let evidence = store.get(EXPECTED_KEY)
        XCTAssertEqual(evidence?.state, .needsReview)  // frozen, preserved as evidence
        XCTAssertEqual(evidence?.envelope.payload.serviceRequestId, "sr-9")
    }

    func testMapsAuthFailureToAuthRequiredAndKeepsTheEvidencePending() async throws {
        let store = VolatileTicketEvidenceStore()
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: FakeSubmitter { .authFailed(httpStatus: 401) }, evidenceStore: store),
            INPUT
        )
        XCTAssertEqual(result, .authRequired(idempotencyKey: EXPECTED_KEY))
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .pending)
    }

    func testNeverReportsDurableSuccessOnAnyNonAcceptedOutcome() async throws {
        let outcomes: [HubSubmitOutcome] = [
            .transient(reason: .network, httpStatus: nil, detail: nil),
            .rejected(kind: .blocked, httpStatus: 403, rejectionCode: "forbidden", detail: nil),
            .rejected(kind: .needsReview, httpStatus: 412, rejectionCode: "stale_version", detail: nil),
            .authFailed(httpStatus: 401),
        ]
        for (i, outcome) in outcomes.enumerated() {
            let store = VolatileTicketEvidenceStore()
            var input = INPUT
            input.localSeq = i
            input.opUuid = "op-\(i)"
            let result = try await submitFieldTicket(
                SubmitFieldTicketDeps(submitter: FakeSubmitter { outcome }, evidenceStore: store), input)
            if case .accepted = result { XCTFail("must not be accepted") }
            let key = try buildIdempotencyKey("devA", i, "op-\(i)")
            if case .accepted = store.get(key)?.state { XCTFail("must not be accepted") }
            XCTAssertNotNil(store.get(key))  // evidence always preserved
        }
    }

    func testReusesTheSameIdempotencyKeyWhenRetryingTheSameOperation() async throws {
        let store = VolatileTicketEvidenceStore()
        let offline = FakeSubmitter { .transient(reason: .network, httpStatus: nil, detail: nil) }
        _ = try await submitFieldTicket(SubmitFieldTicketDeps(submitter: offline, evidenceStore: store), INPUT)
        let online = FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) }
        _ = try await submitFieldTicket(SubmitFieldTicketDeps(submitter: online, evidenceStore: store), INPUT)
        XCTAssertEqual(offline.calls[0].idempotencyKey, online.calls[0].idempotencyKey)
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .accepted)
        XCTAssertEqual(store.list().count, 1)  // one evidence record, not two
    }

    func testPropagatesIdempotencyKeyConstructionErrorsBeforeAnyNetworkCall() async throws {
        let store = VolatileTicketEvidenceStore()
        let sub = FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) }
        var input = INPUT
        input.deviceInstanceId = "bad:device"
        do {
            _ = try await submitFieldTicket(SubmitFieldTicketDeps(submitter: sub, evidenceStore: store), input)
            XCTFail("expected throw")
        } catch is IdempotencyKeyError {
            // expected
        }
        XCTAssertEqual(sub.calls.count, 0)
    }

    func testASecondSubmitWhileTheFirstIsInFlightNeverFiresASecondNetworkCall() async throws {
        // ponytail: the TS test races two concurrent submits against a manually-resolved promise
        // to prove the double-submit guard. Swift's structured-concurrency scheduling gives no
        // equivalent guarantee that a second `async let` call observes the first call's
        // synchronous pre-await state, so this seeds the evidence store directly in the
        // `.inFlight` state a real first call would already have reached, then exercises the same
        // guard the concurrent scenario depends on.
        let store = VolatileTicketEvidenceStore()
        let envelope = OperationEnvelope<HubFieldTicketSubmission>(
            opId: "op-uuid-1", kind: .command, type: "ticket.submit", idempotencyKey: EXPECTED_KEY,
            localSeq: 1, dependsOn: [],
            payload: HubFieldTicketSubmission(
                idempotencyKey: EXPECTED_KEY, serviceRequestId: "sr-9", snapshotHash: "hash-abc",
                ticketNo: "12345", quantityBbl: 120, disposalTicketNo: "D-123"
            )
        )
        store.save(TicketEvidence(envelope: envelope, state: .inFlight, attempts: 0, createdAt: "t0", updatedAt: "t0"))

        let submitter = FakeSubmitter { .accepted(duplicate: false, snapshotDrift: nil, ticketId: nil) }
        let result = try await submitFieldTicket(
            SubmitFieldTicketDeps(submitter: submitter, evidenceStore: store), INPUT)
        XCTAssertEqual(result, .pendingRetry(reason: "already-in-flight", idempotencyKey: EXPECTED_KEY))
        XCTAssertEqual(submitter.calls.count, 0)
        XCTAssertEqual(store.get(EXPECTED_KEY)?.state, .inFlight)
    }

    func testDeclaresTheEvidenceStoreVolatile() {
        XCTAssertEqual(VolatileTicketEvidenceStore().durability, .volatileMemory)
    }
}

private func isoTestDate(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)!
}
