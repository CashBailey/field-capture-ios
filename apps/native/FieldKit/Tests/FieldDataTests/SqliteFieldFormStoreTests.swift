// Standalone round-trip coverage for SqliteFieldFormStore (JSON envelope fidelity for the
// DvirForm/JhaForm payload). __tests__/field-workflow.test.ts exercises this store too, but only
// through `FieldWorkflowService` (src/runtime) — out of scope for FieldData tests per PORTING.md
// (FieldRuntime is a separate, concurrently-owned target). This file covers the same store
// directly: draft save/get/list/listByStatus and payload_json round-tripping for both form kinds.
import XCTest

@testable import FieldContracts
@testable import FieldData
@testable import FieldDomain

private func makeDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-fieldforms-\(UUID().uuidString).db")
}

final class SqliteFieldFormStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func dvirRecord() -> FieldFormRecord {
        FieldFormRecord(
            form: .dvir(
                DvirForm(
                    formId: "dvir-1", kind: .preTripDvir, vehicleRef: "truck-7", odometer: 12_345,
                    items: [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
                    defectsCertifiedSafe: true, signatureBlobIds: ["sig-1"],
                    signatures: [
                        SignatureRecord(
                            blobId: "sig-1", signerName: "A. Rivera", signedAtUtc: "2026-06-10T12:00:00Z",
                            certificationText: "I confirm this pre-trip inspection is complete and accurate.",
                            deviceInstanceId: "devA", appVersion: "1.0.0")
                    ], completedAt: "2026-06-10T12:01:00Z")),
            status: .completed, opId: "op-1", createdAt: "2026-06-10T11:00:00Z", updatedAt: "2026-06-10T12:01:00Z")
    }

    private func jhaRecord() -> FieldFormRecord {
        FieldFormRecord(
            form: .jha(
                JhaForm(
                    formId: "jha-1", serviceRequestId: "sr-9",
                    hazards: [JhaHazard(hazardId: "h1", description: "H2S", mitigation: "monitor")],
                    signatureBlobIds: ["sig-2"])),
            status: .draft, createdAt: "2026-06-10T11:00:00Z", updatedAt: "2026-06-10T11:00:00Z")
    }

    func testSavesAndReadsBackADvirDraftPreservingNestedFields() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())
        let got = try store.get("dvir-1")
        XCTAssertEqual(got?.status, .completed)
        XCTAssertEqual(got?.opId, "op-1")
        guard case .dvir(let dvir) = got?.form else { return XCTFail("expected a dvir form") }
        XCTAssertEqual(dvir.kind, .preTripDvir)
        XCTAssertEqual(dvir.vehicleRef, "truck-7")
        XCTAssertEqual(dvir.odometer, 12_345)
        XCTAssertEqual(dvir.items, [InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)])
        XCTAssertEqual(dvir.defectsCertifiedSafe, true)
        XCTAssertEqual(dvir.signatures?.first?.blobId, "sig-1")
    }

    func testSavesAndReadsBackAJhaDraft() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(jhaRecord())
        let got = try store.get("jha-1")
        XCTAssertEqual(got?.status, .draft)
        guard case .jha(let jha) = got?.form else { return XCTFail("expected a jha form") }
        XCTAssertEqual(jha.serviceRequestId, "sr-9")
        XCTAssertEqual(jha.hazards, [JhaHazard(hazardId: "h1", description: "H2S", mitigation: "monitor")])
    }

    func testListAndListByStatus() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())
        try store.save(jhaRecord())
        XCTAssertEqual(
            Set(try store.list().map { $0.form == dvirRecord().form ? "dvir-1" : "jha-1" }),
            ["dvir-1", "jha-1"])
        XCTAssertEqual(try store.listByStatus(.draft).count, 1)
        XCTAssertEqual(try store.listByStatus(.completed).count, 1)
    }

    func testUpsertOnFormIdReplacesThePreviousRow() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())
        var updated = dvirRecord()
        updated.status = .accepted
        try store.save(updated)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.get("dvir-1")?.status, .accepted)
    }

    func testCorruptRowStatusAndKindAreSurfacedInsteadOfBecomingDrafts() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())
        try store.save(jhaRecord())

        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run(
            "UPDATE field_forms SET status = ? WHERE form_id = ?",
            [.text("future-status"), .text("dvir-1")])
        try db.run(
            "UPDATE field_forms SET kind = ? WHERE form_id = ?",
            [.text("future-kind"), .text("jha-1")])

        XCTAssertEqual(try db.first("SELECT COUNT(*) AS count FROM field_forms")?.int("count"), 2)
        XCTAssertThrowsError(try store.get("dvir-1")) { error in
            XCTAssertTrue(error is SqliteFieldFormStoreError)
        }
        XCTAssertThrowsError(try store.get("jha-1")) { error in
            XCTAssertTrue(error is SqliteFieldFormStoreError)
        }
        XCTAssertThrowsError(try store.list())
    }

    func testUnknownInspectionResultSurfacesTheCorruptForm() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())

        let payload = try XCTUnwrap(
            try db.first("SELECT payload_json FROM field_forms WHERE form_id = 'dvir-1'")?.string("payload_json"))
        var object = try XCTUnwrap((try jsonParse(payload)) as? [String: Any])
        var items = try XCTUnwrap(object["items"] as? [[String: Any]])
        items[0]["result"] = "future-result"
        object["items"] = items
        try db.run(
            "UPDATE field_forms SET payload_json = ? WHERE form_id = ?",
            [.text(try jsonStringify(object)), .text("dvir-1")])

        XCTAssertThrowsError(try store.get("dvir-1")) { error in
            guard let storeError = error as? SqliteFieldFormStoreError,
                case .corruptRecord(let formId, _) = storeError
            else {
                return XCTFail("expected a corrupt-record error")
            }
            XCTAssertEqual(formId, "dvir-1")
        }
        XCTAssertThrowsError(try store.list())
    }

    func testDatabaseFailuresPropagateInsteadOfCrashing() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        db.close()

        XCTAssertThrowsError(try store.save(dvirRecord()))
        XCTAssertThrowsError(try store.get("dvir-1"))
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.listByStatus(.completed))
    }

    func testTransactionRollsBackFormAndOutboxWritesAsOneUnit() throws {
        let store = SqliteFieldFormStore(db, .durablePlain)
        try store.save(dvirRecord())
        var enqueued = dvirRecord()
        enqueued.status = .enqueued
        enqueued.opId = "op-atomic"

        XCTAssertThrowsError(
            try store.transaction {
                try db.run(
                    """
                    INSERT INTO sync_outbox (
                        op_id, idempotency_key, envelope_json, state, retry_count,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text("op-atomic"), .text("gtr:dev:1:op-atomic"), .text("{}"),
                        .text("pending"), .int(0), .text("2026-06-10T12:00:00Z"),
                        .text("2026-06-10T12:00:00Z"),
                    ])
                try store.save(enqueued)
                throw TestTransactionError.failed
            })
        XCTAssertEqual(try store.get("dvir-1")?.status, .completed)
        XCTAssertEqual(try db.first("SELECT COUNT(*) AS count FROM sync_outbox")?.int("count"), 0)
    }
}

private enum TestTransactionError: Error {
    case failed
}
