// Standalone round-trip + durability coverage for SqlitePrintJobStore, backing the contracts
// `PrintJobQueue`. __tests__/print-runtime.test.ts exercises this store too, but almost entirely
// through `PrintRuntime` (src/runtime) and the PT-210 adapters — out of scope for FieldData tests
// per PORTING.md (FieldRuntime/FieldAdapters are separate, concurrently-owned targets). This file
// covers the same "queue durability" guarantee directly: an enqueued job survives a close/reopen
// with a brand-new `PrintJobQueue` over the same database, exactly like the TS test's core case.
import XCTest

@testable import FieldContracts
@testable import FieldData

private enum InjectedPrintJobSqlError: Error {
    case failed
}

private final class FailingPrintJobSqlDriver: SqlDriver {
    func exec(_ sql: String) throws { throw InjectedPrintJobSqlError.failed }
    func run(_ sql: String, _ params: [SqlValue]) throws { throw InjectedPrintJobSqlError.failed }
    func all(_ sql: String, _ params: [SqlValue]) throws -> [SqlRow] {
        throw InjectedPrintJobSqlError.failed
    }
    func first(_ sql: String, _ params: [SqlValue]) throws -> SqlRow? {
        throw InjectedPrintJobSqlError.failed
    }
    func transaction<T>(_ fn: () throws -> T) throws -> T {
        throw InjectedPrintJobSqlError.failed
    }
}

private func makeDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-printjobs-\(UUID().uuidString).db")
}

private func job(_ id: String = "job-1") -> PrintJob {
    PrintJob(
        printJobId: id, srId: "sr-9", fieldTicketId: "ft-1", printerProfileId: "pt210-1",
        createdAt: "2026-06-10T12:00:00Z", status: .queued, retryCount: 0, payloadHash: "abc123",
        payloadSizeBytes: 42)
}

final class SqlitePrintJobStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testRoundTripsAJobIncludingOptionalActorFields() throws {
        let store = SqlitePrintJobStore(db)
        var j = job()
        j.employeeId = "emp-1"
        j.printedAt = "2026-06-10T12:01:00Z"
        j.errorCode = "code"
        j.diagnosticMessage = "msg"
        try store.upsert(j)
        XCTAssertEqual(try store.get("job-1"), j)
        XCTAssertEqual(try store.all(), [j])
    }

    func testUpsertsOnIdAndDeletes() throws {
        let store = SqlitePrintJobStore(db)
        try store.upsert(job())
        var updated = job()
        updated.status = .printed
        try store.upsert(updated)
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.get("job-1")?.status, .printed)
        try store.delete("job-1")
        XCTAssertNil(try store.get("job-1"))
    }

    func testAnEnqueuedJobSurvivesRestartReOpenTheSameSqliteRows() throws {
        let dir = NSTemporaryDirectory() + "fieldkit-printjobs-restart-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/print.db"

        let db1 = try SystemSqliteDriver(path: file)
        try migrate(db1)
        let firstQueue = PrintJobQueue(SqlitePrintJobStore(db1))
        let enqueued = try firstQueue.enqueue(job())
        db1.close()

        // "Restart": a brand-new queue over the same database.
        let db2 = try SystemSqliteDriver(path: file)
        try migrate(db2)
        let reopenedQueue = PrintJobQueue(SqlitePrintJobStore(db2))
        let reread = try reopenedQueue.get(enqueued.printJobId)
        XCTAssertEqual(reread?.status, .queued)
        XCTAssertEqual(reread?.payloadHash, "abc123")
        XCTAssertEqual(reread?.payloadSizeBytes, 42)
        db2.close()
    }

    func testCorruptStatusIsQuarantinedInsteadOfBecomingQueuedWork() throws {
        let store = SqlitePrintJobStore(db)
        try store.upsert(job("corrupt"))
        try store.upsert(job("healthy"))

        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run(
            "UPDATE print_jobs SET status = ? WHERE print_job_id = ?",
            [.text("future-status"), .text("corrupt")])

        XCTAssertEqual(try db.first("SELECT COUNT(*) AS count FROM print_jobs")?.int("count"), 2)
        XCTAssertEqual(try store.get("healthy")?.printJobId, "healthy")
        XCTAssertThrowsError(try store.get("corrupt")) { error in
            guard case .corruptRecord(let id, let detail) = error as? SqlitePrintJobStoreError else {
                return XCTFail("expected a typed corrupt-record error")
            }
            XCTAssertEqual(id, "corrupt")
            XCTAssertTrue(detail.contains("status"))
        }
        XCTAssertThrowsError(try store.all())
    }

    func testInvalidRequiredValuesAreTypedCorruptionFailures() throws {
        let store = SqlitePrintJobStore(db)
        try store.upsert(job("negative-retries"))
        try store.upsert(job("empty-payload"))

        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run(
            "UPDATE print_jobs SET retry_count = ? WHERE print_job_id = ?",
            [.int(-1), .text("negative-retries")])
        try db.run(
            "UPDATE print_jobs SET payload_size_bytes = ? WHERE print_job_id = ?",
            [.int(0), .text("empty-payload")])

        XCTAssertThrowsError(try store.get("negative-retries")) { error in
            XCTAssertTrue(String(describing: error).contains("retry_count"))
        }
        XCTAssertThrowsError(try store.get("empty-payload")) { error in
            XCTAssertTrue(String(describing: error).contains("payload_size_bytes"))
        }
    }

    func testPropagatesEverySqlFailure() {
        let store = SqlitePrintJobStore(FailingPrintJobSqlDriver())

        XCTAssertThrowsError(try store.upsert(job()))
        XCTAssertThrowsError(try store.get("job-1"))
        XCTAssertThrowsError(try store.all())
        XCTAssertThrowsError(try store.delete("job-1"))
    }
}
