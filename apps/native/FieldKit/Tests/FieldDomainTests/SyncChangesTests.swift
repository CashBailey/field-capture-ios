import FieldContracts
// Port of __tests__/sync-changes.test.ts — down-sync applied-changes ledger (ADR-004 §4g). The
// apply MUST be idempotent and must never silently drop a change — a no-op apply would advance
// the frontier past authoritative changes.
import XCTest

@testable import FieldDomain

final class SyncChangesTests: XCTestCase {
    // The verbatim real-Hub change shape (from GET /sync/changes against local opshub).
    private var REAL_CHANGE: [String: Any] {
        [
            "authority_epoch": 1,
            "commit_seq": 1,
            "op_id": "op-vtest-1",
            "entity_type": "sync_operation",
            "entity_id": "2fa77824-e9c0-48d8-b707-c9482084cee9",
            "change_type": "field.note",
            "payload": [
                "service_request_id": "2fa77824-e9c0-48d8-b707-c9482084cee9",
                "note": "v2 verification",
            ] as [String: Any],
            "created_at": "2026-06-15T02:56:55.549668",
        ]
    }

    func testNormalizesTheRealHubChangeRow() {
        let expected = SyncChangeRow(
            authorityEpoch: 1,
            commitSeq: 1,
            opId: "op-vtest-1",
            entityType: "sync_operation",
            entityId: "2fa77824-e9c0-48d8-b707-c9482084cee9",
            changeType: "field.note",
            payload: [
                "service_request_id": "2fa77824-e9c0-48d8-b707-c9482084cee9",
                "note": "v2 verification",
            ],
            createdAt: "2026-06-15T02:56:55.549668"
        )
        XCTAssertEqual(parseSyncChange(REAL_CHANGE), expected)
    }

    func testReturnsNilForAnUnkeyableChangeMissingEpochSeqOrType() {
        XCTAssertNil(parseSyncChange(["op_id": "x"] as [String: Any]))
        XCTAssertNil(
            parseSyncChange(["authority_epoch": 1, "commit_seq": "nope", "change_type": "t"] as [String: Any]))
        XCTAssertNil(parseSyncChange("garbage"))
    }

    func testRecordsNewChangesAndReportsCounts() throws {
        let ledger = VolatileSyncChangeLedger()
        var second = REAL_CHANGE
        second["commit_seq"] = 2
        second["change_type"] = "jhajsa.submit"
        let result = try recordChanges(ledger, [REAL_CHANGE, second])
        XCTAssertEqual(result, RecordChangesResult(recorded: 2, duplicates: 0, skipped: 0))
        XCTAssertEqual(ledger.count(), 2)
        XCTAssertTrue(ledger.has(1, 1))
    }

    func testReApplyingTheSamePageIsANoOp() throws {
        let ledger = VolatileSyncChangeLedger()
        _ = try recordChanges(ledger, [REAL_CHANGE])
        let second = try recordChanges(ledger, [REAL_CHANGE])
        XCTAssertEqual(second, RecordChangesResult(recorded: 0, duplicates: 1, skipped: 0))
        XCTAssertEqual(ledger.count(), 1)
    }

    func testCountsUnkeyableChangesAsSkipped() throws {
        let ledger = VolatileSyncChangeLedger()
        let result = try recordChanges(ledger, [REAL_CHANGE, ["junk": true] as [String: Any]])
        XCTAssertEqual(result, RecordChangesResult(recorded: 1, duplicates: 0, skipped: 1))
    }

    func testListsInEpochSeqOrder() throws {
        let ledger = VolatileSyncChangeLedger()
        var c1 = REAL_CHANGE
        c1["commit_seq"] = 3
        var c2 = REAL_CHANGE
        c2["commit_seq"] = 1
        var c3 = REAL_CHANGE
        c3["commit_seq"] = 2
        _ = try recordChanges(ledger, [c1, c2, c3])
        XCTAssertEqual(ledger.list().map(\.commitSeq), [1, 2, 3])
    }
}
