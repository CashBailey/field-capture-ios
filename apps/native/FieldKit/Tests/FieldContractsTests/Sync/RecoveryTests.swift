// Port of test/recovery.test.ts
import XCTest

@testable import FieldContracts

private typealias Payload = [String: JSONValue]

final class RecoveryTests: XCTestCase {
    private func item(_ opId: String, _ localSeq: Int, _ state: OutboxItemState, _ retryCount: Int = 0) throws
        -> OutboxItem<Payload>
    {
        OutboxItem(
            envelope: OperationEnvelope(
                opId: opId,
                kind: .command,
                type: "ticket.submit",
                idempotencyKey: try buildIdempotencyKey("dev-1", localSeq, opId),
                localSeq: localSeq,
                dependsOn: [],
                payload: [:]
            ),
            state: state,
            retryCount: retryCount
        )
    }

    // ---- restart recovery sweep (pending→retry, in-flight→retry, terminal stays) ----

    func testSweepsOrphanedInFlightRowsBackToPendingWithTheSameIdempotencyKey() throws {
        let orphan = try item("op-b", 2, .inFlight, 1)
        let recovery = recoverOutboxOnRestart([orphan])
        XCTAssertEqual(recovery.recoveredOpIds, ["op-b"])
        XCTAssertEqual(recovery.items[0].state, .pending)
        XCTAssertEqual(recovery.items[0].retryCount, 2)
        // identity untouched — Hub can still dedupe a re-send of the interrupted attempt
        XCTAssertEqual(recovery.items[0].envelope.idempotencyKey, orphan.envelope.idempotencyKey)
    }

    func testLeavesPendingRowsQueuedAndTerminalRowsFrozen() throws {
        let rows = [
            try item("op-pending", 1, .pending),
            try item("op-accepted", 2, .accepted),
            try item("op-rejected", 3, .rejected),
            try item("op-review", 4, .needsReview),
        ]
        let recovery = recoverOutboxOnRestart(rows)
        XCTAssertEqual(recovery.recoveredOpIds, [])
        XCTAssertEqual(recovery.items.map(\.state), [.pending, .accepted, .rejected, .needsReview])
        // untouched rows are equal to the originals — the sweep never rewrites what it does not
        // recover (Swift value types make this an equality check rather than a reference check).
        XCTAssertEqual(recovery.items[0], rows[0])
        XCTAssertEqual(recovery.items[1], rows[1])
    }

    func testNeverMutatesItsInputs() throws {
        let orphan = try item("op-x", 5, .inFlight)
        _ = recoverOutboxOnRestart([orphan])
        XCTAssertEqual(orphan.state, .inFlight)
        XCTAssertEqual(orphan.retryCount, 0)
    }
}
