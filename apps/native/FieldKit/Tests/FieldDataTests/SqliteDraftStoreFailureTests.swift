import XCTest

@testable import FieldData
@testable import FieldDomain

private enum InjectedDraftStoreSqlError: Error {
    case failed
}

private final class FailingDraftStoreSqlDriver: SqlDriver {
    func exec(_ sql: String) throws {
        throw InjectedDraftStoreSqlError.failed
    }

    func run(_ sql: String, _ params: [SqlValue]) throws {
        throw InjectedDraftStoreSqlError.failed
    }

    func all(_ sql: String, _ params: [SqlValue]) throws -> [SqlRow] {
        throw InjectedDraftStoreSqlError.failed
    }

    func first(_ sql: String, _ params: [SqlValue]) throws -> SqlRow? {
        throw InjectedDraftStoreSqlError.failed
    }

    func transaction<T>(_ fn: () throws -> T) throws -> T {
        throw InjectedDraftStoreSqlError.failed
    }
}

private func makeDraftStoreDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-draft-errors-\(UUID().uuidString).db")
}

private func fieldTicketDraft(id: String = "draft-1") -> FieldTicketDraft {
    FieldTicketDraft(
        id: id,
        serviceRequestId: "sr-1",
        ticketNo: "T-100",
        quantityBbl: 80,
        disposalTicketNo: "D-100",
        captureMethod: .digital,
        createdAt: "2026-07-11T10:00:00.000Z",
        updatedAt: "2026-07-11T10:00:00.000Z"
    )
}

private func receiptDraft(id: String = "receipt-1") -> ReceiptDraft {
    ReceiptDraft(
        id: id,
        serviceRequestId: "sr-1",
        receiptType: .fuel,
        vendor: "Fuel Stop",
        receiptNo: "R-100",
        amount: 42.50,
        notes: "",
        createdAt: "2026-07-11T10:00:00.000Z",
        updatedAt: "2026-07-11T10:00:00.000Z"
    )
}

final class SqliteDraftStoreFailureTests: XCTestCase {
    func testFieldTicketStorePropagatesEverySqlFailure() {
        let store = SqliteFieldTicketDraftStore(FailingDraftStoreSqlDriver(), .durablePlain)

        XCTAssertThrowsError(try store.save(fieldTicketDraft()))
        XCTAssertThrowsError(try store.get("draft-1"))
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.delete("draft-1"))
    }

    func testReceiptStorePropagatesEverySqlFailure() {
        let store = SqliteReceiptDraftStore(FailingDraftStoreSqlDriver(), .durablePlain)

        XCTAssertThrowsError(try store.save(receiptDraft()))
        XCTAssertThrowsError(try store.get("receipt-1"))
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.delete("receipt-1"))
    }

    func testUnknownFieldTicketCaptureMethodIsAQuarantinedTypedFailure() throws {
        let db = try makeDraftStoreDriver()
        try migrate(db)
        let store = SqliteFieldTicketDraftStore(db, .durablePlain)
        try store.save(fieldTicketDraft())
        try store.save(fieldTicketDraft(id: "draft-healthy"))
        try db.run(
            "UPDATE field_ticket_drafts SET capture_method = ? WHERE id = ?",
            [.text("future-method"), .text("draft-1")]
        )

        XCTAssertEqual(try store.get("draft-healthy")?.captureMethod, .digital)
        XCTAssertThrowsError(try store.get("draft-1")) { error in
            guard
                case .corruptRecord(let id, let detail) =
                    error as? SqliteFieldTicketDraftStoreError
            else {
                return XCTFail("expected a typed corrupt-record error")
            }
            XCTAssertEqual(id, "draft-1")
            XCTAssertTrue(detail.contains("capture_method"))
        }
        XCTAssertThrowsError(try store.list())
    }

    func testUnknownReceiptTypeIsAQuarantinedTypedFailure() throws {
        let db = try makeDraftStoreDriver()
        try migrate(db)
        let store = SqliteReceiptDraftStore(db, .durablePlain)
        try store.save(receiptDraft())
        try store.save(receiptDraft(id: "receipt-healthy"))
        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run(
            "UPDATE receipt_drafts SET receipt_type = ? WHERE id = ?",
            [.text("future-type"), .text("receipt-1")]
        )

        XCTAssertEqual(try store.get("receipt-healthy")?.receiptType, .fuel)
        XCTAssertThrowsError(try store.get("receipt-1")) { error in
            guard
                case .corruptRecord(let id, let detail) =
                    error as? SqliteReceiptDraftStoreError
            else {
                return XCTFail("expected a typed corrupt-record error")
            }
            XCTAssertEqual(id, "receipt-1")
            XCTAssertTrue(detail.contains("receipt_type"))
        }
        XCTAssertThrowsError(try store.list())
    }
}
