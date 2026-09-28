import XCTest

@testable import FieldData

final class MigrationsTests: XCTestCase {
    func testMigrateBringsFreshDatabaseToLatest() throws {
        let path = NSTemporaryDirectory() + "fieldkit-migrate-\(UUID().uuidString).db"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let db = try SystemSqliteDriver(path: path)
        try migrate(db)
        XCTAssertEqual(try currentSchemaVersion(db), MIGRATIONS.count)
        // Idempotent: safe to call on every open.
        try migrate(db)
        XCTAssertEqual(try currentSchemaVersion(db), MIGRATIONS.count)
        // Core tables from v1 exist.
        for table in ["assignments", "ticket_evidence"] {
            let row = try db.first(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(table)])
            XCTAssertNotNil(row, "missing table \(table)")
        }
    }
}
