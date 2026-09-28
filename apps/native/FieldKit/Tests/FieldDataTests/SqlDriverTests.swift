import XCTest

@testable import FieldData

final class SqlDriverTests: XCTestCase {
    func makeDriver() throws -> SystemSqliteDriver {
        let path = NSTemporaryDirectory() + "fieldkit-test-\(UUID().uuidString).db"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return try SystemSqliteDriver(path: path)
    }

    func testRunAllFirstRoundTrip() throws {
        let db = try makeDriver()
        try db.exec("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER, r REAL, b BLOB, x TEXT)")
        try db.run(
            "INSERT INTO t (id, n, r, b, x) VALUES (?, ?, ?, ?, ?)",
            [.text("a"), .int(42), .real(1.5), .blob(Data([1, 2, 3])), .null])
        let row = try XCTUnwrap(db.first("SELECT * FROM t WHERE id = ?", [.text("a")]))
        XCTAssertEqual(row.string("id"), "a")
        XCTAssertEqual(row.int("n"), 42)
        XCTAssertEqual(row.real("r"), 1.5)
        XCTAssertEqual(row.blob("b"), Data([1, 2, 3]))
        XCTAssertEqual(row["x"], .null)
        XCTAssertEqual(try db.all("SELECT * FROM t").count, 1)
    }

    func testTransactionRollsBackOnThrow() throws {
        let db = try makeDriver()
        try db.exec("CREATE TABLE t (id TEXT)")
        struct Boom: Error {}
        XCTAssertThrowsError(
            try db.transaction {
                try db.run("INSERT INTO t (id) VALUES (?)", [.text("x")])
                throw Boom()
            })
        XCTAssertEqual(try db.all("SELECT * FROM t").count, 0)
        let n: () = try db.transaction {
            try db.run("INSERT INTO t (id) VALUES (?)", [.text("y")])
        }
        _ = n
        XCTAssertEqual(try db.all("SELECT * FROM t").count, 1)
    }

    func testNestedTransactionJoinsTheEnclosingTransaction() throws {
        let db = try makeDriver()
        try db.exec("CREATE TABLE t (id TEXT)")

        // Inner success joins the outer commit.
        try db.transaction {
            try db.run("INSERT INTO t (id) VALUES (?)", [.text("outer")])
            try db.transaction {
                try db.run("INSERT INTO t (id) VALUES (?)", [.text("inner")])
            }
        }
        XCTAssertEqual(try db.all("SELECT * FROM t").count, 2)

        // An outer failure rolls back inner writes, and the caller's error survives untranslated.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try db.transaction {
                try db.transaction {
                    try db.run("INSERT INTO t (id) VALUES (?)", [.text("rolled-back")])
                }
                throw Boom()
            }
        ) { error in
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(try db.all("SELECT * FROM t").count, 2)
    }

    func testTransactionPreventsConcurrentWritesFromJoiningItsRollback() throws {
        let db = try makeDriver()
        try db.exec("CREATE TABLE t (id TEXT)")

        let transactionInserted = DispatchSemaphore(value: 0)
        let allowRollback = DispatchSemaphore(value: 0)
        let concurrentWriteStarted = DispatchSemaphore(value: 0)
        let concurrentWriteFinished = DispatchSemaphore(value: 0)
        let work = DispatchGroup()

        struct ExpectedRollback: Error {}

        work.enter()
        DispatchQueue.global().async {
            defer { work.leave() }
            do {
                try db.transaction {
                    try db.run("INSERT INTO t (id) VALUES (?)", [.text("rolled-back")])
                    transactionInserted.signal()
                    _ = allowRollback.wait(timeout: .now() + 2)
                    throw ExpectedRollback()
                }
            } catch {}
        }

        XCTAssertEqual(transactionInserted.wait(timeout: .now() + 2), .success)

        work.enter()
        DispatchQueue.global().async {
            defer {
                concurrentWriteFinished.signal()
                work.leave()
            }
            concurrentWriteStarted.signal()
            try? db.run("INSERT INTO t (id) VALUES (?)", [.text("committed")])
        }

        XCTAssertEqual(concurrentWriteStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(concurrentWriteFinished.wait(timeout: .now() + 0.1), .timedOut)

        allowRollback.signal()
        XCTAssertEqual(concurrentWriteFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(work.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(try db.all("SELECT id FROM t").compactMap { $0.string("id") }, ["committed"])
    }

    func testProductionDatabasePathMatchesQuickSqliteDocumentsLocation() {
        let databaseName = "fieldkit-path-\(UUID().uuidString).db"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(
            databaseFilePath(databaseName: databaseName),
            documents.appendingPathComponent(databaseName).path
        )
    }

    func testPrototypeMigrationMovesSidecarsBeforePublishingTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fieldkit-migration-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("prototype/fieldcapture.db").path
        let destination = directory.appendingPathComponent("documents/fieldcapture.db").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: source).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("main".utf8).write(to: URL(fileURLWithPath: source))
        try Data("wal".utf8).write(to: URL(fileURLWithPath: source + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: source + "-shm"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        try migratePrototypeDatabaseIfNeeded(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), Data("main".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination + "-wal")), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination + "-shm")), Data("shm".utf8))
    }

    func testPrototypeMigrationConflictThrowsWithoutMovingTheMainDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fieldkit-migration-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("prototype/fieldcapture.db").path
        let destination = directory.appendingPathComponent("documents/fieldcapture.db").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: source).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("main".utf8).write(to: URL(fileURLWithPath: source))
        try Data("source wal".utf8).write(to: URL(fileURLWithPath: source + "-wal"))
        try Data("destination wal".utf8).write(to: URL(fileURLWithPath: destination + "-wal"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try migratePrototypeDatabaseIfNeeded(from: source, to: destination)
        ) { error in
            XCTAssertTrue(error is DatabaseMigrationError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    }
}
