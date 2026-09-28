import Foundation
import XCTest

@testable import FieldData

private enum InjectedPrintPayloadSqlError: Error {
    case failed
}

private final class FailingPrintPayloadSqlDriver: SqlDriver {
    func exec(_ sql: String) throws { throw InjectedPrintPayloadSqlError.failed }
    func run(_ sql: String, _ params: [SqlValue]) throws { throw InjectedPrintPayloadSqlError.failed }
    func all(_ sql: String, _ params: [SqlValue]) throws -> [SqlRow] {
        throw InjectedPrintPayloadSqlError.failed
    }
    func first(_ sql: String, _ params: [SqlValue]) throws -> SqlRow? {
        throw InjectedPrintPayloadSqlError.failed
    }
    func transaction<T>(_ fn: () throws -> T) throws -> T {
        throw InjectedPrintPayloadSqlError.failed
    }
}

final class SqlitePrintPayloadStoreTests: XCTestCase {
    func testRoundTripsBinaryPayloadAndDeletesIt() throws {
        let db = try SystemSqliteDriver(
            path: NSTemporaryDirectory() + "fieldkit-print-payload-\(UUID().uuidString).db")
        defer { db.close() }
        try migrate(db)
        let store = SqlitePrintPayloadStore(db)
        let payload = Data([0x00, 0x1b, 0x40, 0xff])

        try store.put("job-1", payload)

        XCTAssertEqual(try store.get("job-1"), payload)
        try store.delete("job-1")
        XCTAssertNil(try store.get("job-1"))
    }

    func testPayloadSurvivesDatabaseRestart() throws {
        let directory = NSTemporaryDirectory() + "fieldkit-print-payload-restart-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/print.db"
        let payload = Data([0x1b, 0x40, 0x47, 0x0a])

        let firstDatabase = try SystemSqliteDriver(path: path)
        try migrate(firstDatabase)
        try SqlitePrintPayloadStore(firstDatabase).put("job-1", payload)
        firstDatabase.close()

        let reopenedDatabase = try SystemSqliteDriver(path: path)
        defer { reopenedDatabase.close() }
        try migrate(reopenedDatabase)

        XCTAssertEqual(try SqlitePrintPayloadStore(reopenedDatabase).get("job-1"), payload)
    }

    func testInvalidPayloadTypeIsATypedCorruptionFailure() throws {
        let db = try SystemSqliteDriver(
            path: NSTemporaryDirectory() + "fieldkit-print-payload-corrupt-\(UUID().uuidString).db")
        defer { db.close() }
        try migrate(db)
        try db.run(
            "INSERT INTO print_payloads (print_job_id, payload) VALUES (?, ?)",
            [.text("job-1"), .text("not binary")])

        XCTAssertThrowsError(try SqlitePrintPayloadStore(db).get("job-1")) { error in
            guard case .corruptRecord(let id, let detail) = error as? SqlitePrintPayloadStoreError else {
                return XCTFail("expected a typed corrupt-record error")
            }
            XCTAssertEqual(id, "job-1")
            XCTAssertTrue(detail.contains("payload"))
        }
    }

    func testPropagatesEverySqlFailure() {
        let store = SqlitePrintPayloadStore(FailingPrintPayloadSqlDriver())

        XCTAssertThrowsError(try store.put("job-1", Data([0x01])))
        XCTAssertThrowsError(try store.get("job-1"))
        XCTAssertThrowsError(try store.delete("job-1"))
    }
}
