// Port of __tests__/evidence-pruning.test.ts — accepted-evidence pruning against real SQL. The
// invariant under proof: pending, in-flight, retry, blocked, failed, needs-review,
// externally-protected, corrupt, and young-accepted rows are NEVER deleted — only old accepted
// rows go, and only while the table is over its ADR 002 byte budget. Pruned full-engine rows
// land in the committed-op ledger so dependency planning still resolves them.
import XCTest

@testable import FieldContracts
@testable import FieldData
@testable import FieldDomain

private func makeDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-pruning-\(UUID().uuidString).db")
}

private let DAY_MS: Int64 = 24 * 60 * 60 * 1000
private let NOW = Date(timeIntervalSince1970: 1_781_179_200)  // 2026-06-10T12:00:00.000Z
private let POLICY = EvidencePrunePolicy(retentionMs: Int(7 * DAY_MS), maxTotalBytes: 1)

private func daysAgo(_ days: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: NOW.addingTimeInterval(-Double(days) * 86400))
}

private func evidence(
    _ key: String, _ state: OutboxItemState, _ outcomeAt: String, extra: (inout TicketEvidence) -> Void = { _ in }
) -> TicketEvidence {
    let envelope = OperationEnvelope<HubFieldTicketSubmission>(
        opId: key, kind: .command, type: "ticket.submit", idempotencyKey: "gtr:devA:1:\(key)", localSeq: 1,
        dependsOn: [],
        payload: HubFieldTicketSubmission(
            idempotencyKey: "gtr:devA:1:\(key)", serviceRequestId: "sr-1", snapshotHash: "h", ticketNo: "t",
            quantityBbl: 1, disposalTicketNo: "d"))
    var e = TicketEvidence(
        envelope: envelope, state: state, attempts: 0, createdAt: daysAgo(60), updatedAt: outcomeAt,
        lastOutcomeAt: outcomeAt)
    extra(&e)
    return e
}

final class PruneAcceptedTicketEvidenceTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testNeverPrunesUnsyncedBlockedFrozenWorkRegardlessOfBytePressure() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        store.save(evidence("pend", .pending, daysAgo(90)))
        store.save(
            evidence("retry", .pending, daysAgo(90)) {
                $0.attempts = 4
                $0.lastTransientReason = "network"
            })
        store.save(evidence("blocked", .pending, daysAgo(90)) { $0.lastRejectionCode = "not_clocked_in" })
        store.save(evidence("inflight", .inFlight, daysAgo(90)))
        store.save(evidence("rejected", .rejected, daysAgo(90)) { $0.lastRejectionCode = "bad" })
        store.save(evidence("review", .needsReview, daysAgo(90)))

        let outcome = try pruneAcceptedTicketEvidence(PruneDeps(db: db, policy: POLICY, now: { NOW }))

        XCTAssertEqual(outcome.prunedIds, [])
        XCTAssertGreaterThan(outcome.shortfallBytes, 0)  // honest: over budget, nothing safe to free
        XCTAssertEqual(store.list().count, 6)
    }

    func testPrunesOnlyOldAcceptedRowsYoungAcceptedRowsStay() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        store.save(evidence("old-accepted", .accepted, daysAgo(30)))
        store.save(evidence("young-accepted", .accepted, daysAgo(2)))
        store.save(evidence("pending", .pending, daysAgo(30)))

        let outcome = try pruneAcceptedTicketEvidence(PruneDeps(db: db, policy: POLICY, now: { NOW }))

        XCTAssertEqual(outcome.prunedIds, ["gtr:devA:1:old-accepted"])
        XCTAssertNil(store.get("gtr:devA:1:old-accepted"))
        XCTAssertNotNil(store.get("gtr:devA:1:young-accepted"))
        XCTAssertNotNil(store.get("gtr:devA:1:pending"))
    }

    func testAGenerousBudgetPrunesNothing() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        store.save(evidence("old-accepted", .accepted, daysAgo(30)))
        let outcome = try pruneAcceptedTicketEvidence(
            PruneDeps(db: db, policy: EvidencePrunePolicy(retentionMs: 0, maxTotalBytes: 10_000_000), now: { NOW }))
        XCTAssertEqual(outcome.prunedIds, [])
        XCTAssertNotNil(store.get("gtr:devA:1:old-accepted"))
    }

    func testExternallyProtectedAcceptedRowsSurvive() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        store.save(evidence("with-photo", .accepted, daysAgo(30)))
        store.save(evidence("plain", .accepted, daysAgo(30)))

        let outcome = try pruneAcceptedTicketEvidence(
            PruneDeps(
                db: db, policy: POLICY, now: { NOW },
                protectedReasons: { id in id == "gtr:devA:1:with-photo" ? ["unlinked-attachment"] : [] }))

        XCTAssertEqual(outcome.prunedIds, ["gtr:devA:1:plain"])
        XCTAssertNotNil(store.get("gtr:devA:1:with-photo"))
    }

    func testACorruptAcceptedRowIsKeptSurfacedNeverPruned() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        store.save(evidence("corrupt", .accepted, daysAgo(30)))
        try db.run("UPDATE ticket_evidence SET envelope_json = '{broken' WHERE idempotency_key = 'gtr:devA:1:corrupt'")

        let outcome = try pruneAcceptedTicketEvidence(PruneDeps(db: db, policy: POLICY, now: { NOW }))

        XCTAssertEqual(outcome.prunedIds, [])
        XCTAssertEqual(store.listCorruptKeys(), ["gtr:devA:1:corrupt"])
    }
}

final class PruneAcceptedSyncOutboxTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func outboxItem(_ opId: String, _ state: OutboxItemState, _ updatedAt: String) -> DurableSyncOutboxItem {
        DurableSyncOutboxItem(
            envelope: OperationEnvelope<JSONValue>(
                opId: opId, kind: .event, type: "test.op", idempotencyKey: "gtr:devA:2:\(opId)", localSeq: 2,
                dependsOn: [], payload: .object(["opId": .string(opId)])),
            state: state, retryCount: 0, createdAt: daysAgo(60), updatedAt: updatedAt)
    }

    func testPrunesOldAcceptedOpsIntoTheLedgerProtectedStatesStayPut() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try store.save(outboxItem("done-old", .accepted, daysAgo(30)))
        try store.save(outboxItem("done-young", .accepted, daysAgo(1)))
        try store.save(outboxItem("pending", .pending, daysAgo(30)))
        try store.save(outboxItem("inflight", .inFlight, daysAgo(30)))
        try store.save(outboxItem("review", .needsReview, daysAgo(30)))
        try store.save(outboxItem("rejected", .rejected, daysAgo(30)))

        let outcome = try pruneAcceptedSyncOutbox(PruneDeps(db: db, policy: POLICY, now: { NOW }))

        XCTAssertEqual(outcome.prunedIds, ["done-old"])
        XCTAssertNil(try store.get("done-old"))
        XCTAssertEqual(try store.committedOpIds(), ["done-old"])
        XCTAssertEqual(
            try store.list().map { $0.envelope.opId }.sorted(),
            ["done-young", "inflight", "pending", "rejected", "review"])
    }

    func testADependentOfAPrunedParentStillPlansAsReady() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try store.save(outboxItem("parent", .accepted, daysAgo(30)))
        _ = try pruneAcceptedSyncOutbox(PruneDeps(db: db, policy: POLICY, now: { NOW }))

        var child = outboxItem("child", .pending, daysAgo(0))
        child.envelope.dependsOn = ["parent"]
        try store.save(child)

        let outboxItems = try store.list().map {
            OutboxItem(
                envelope: $0.envelope, state: $0.state, retryCount: $0.retryCount,
                committedToken: $0.committedToken, rejectionCode: $0.rejectionCode, lastError: $0.lastError,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        let plan = try planDispatch(outboxItems, committedOpIds: store.committedOpIds())
        XCTAssertEqual(plan.ready.map { $0.envelope.opId }, ["child"])
        XCTAssertEqual(plan.blocked.count, 0)
    }
}
