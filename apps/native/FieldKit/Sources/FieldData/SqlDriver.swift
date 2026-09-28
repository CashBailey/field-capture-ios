// Port of src/data/sqlDriver.ts + quickSqliteDriver.ts — minimal synchronous SQL driver seam
// for the durable local store, implemented over the system SQLite3 C API.
//
// The data layer is written against this tiny surface instead of sqlite3 directly so store
// logic stays testable (swift test opens a real on-disk/in-memory database — same engine).
// Synchronous on purpose: the domain store interfaces are synchronous.
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// What may be bound as a statement parameter. (No booleans — store 0/1; keeps drivers honest.)
public enum SqlValue: Equatable {
    case text(String)
    case int(Int64)
    case real(Double)
    case blob(Data)
    case null
}

/// One result row: column name → value (null columns present as `.null`).
public typealias SqlRow = [String: SqlValue]

public extension SqlRow {
    func string(_ column: String) -> String? {
        if case .text(let s)? = self[column] { return s }
        return nil
    }
    func int(_ column: String) -> Int64? {
        switch self[column] {
        case .int(let i)?: return i
        case .real(let d)?: return Int64(d)
        default: return nil
        }
    }
    func real(_ column: String) -> Double? {
        switch self[column] {
        case .real(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }
    func blob(_ column: String) -> Data? {
        if case .blob(let d)? = self[column] { return d }
        return nil
    }
}

public struct SqlError: Error, LocalizedError {
    public let message: String
    public let code: Int32
    public init(message: String, code: Int32) {
        self.message = message
        self.code = code
    }
    public var errorDescription: String? { "SQLite error \(code): \(message)" }
}

struct DatabaseMigrationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public protocol SqlDriver {
    /// Execute one or more statements WITHOUT parameter binding (DDL / PRAGMA only).
    func exec(_ sql: String) throws
    /// Execute one write statement with positional `?` parameters.
    func run(_ sql: String, _ params: [SqlValue]) throws
    /// Query all rows.
    func all(_ sql: String, _ params: [SqlValue]) throws -> [SqlRow]
    /// Query the first row, or nil.
    func first(_ sql: String, _ params: [SqlValue]) throws -> SqlRow?
    /// Run `fn` inside a transaction; rolls back if it throws, returns its result otherwise.
    func transaction<T>(_ fn: () throws -> T) throws -> T
}

public extension SqlDriver {
    func run(_ sql: String) throws { try run(sql, []) }
    func all(_ sql: String) throws -> [SqlRow] { try all(sql, []) }
    func first(_ sql: String) throws -> SqlRow? { try first(sql, []) }
}

/// Production `SqlDriver` over the system SQLite3 C API, serialized behind one connection.
public final class SystemSqliteDriver: SqlDriver, @unchecked Sendable {
    private let connectionLock = NSRecursiveLock()
    private var db: OpaquePointer?
    /// Nonzero while a `transaction` body runs. Only the thread holding `connectionLock` for the
    /// whole outer transaction can observe it, so a nested call joins that transaction instead of
    /// issuing a second BEGIN (SQLite rejects nested BEGIN).
    private var inTransaction = false
    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let handle { sqlite3_close_v2(handle) }
            throw SqlError(message: "cannot open database at \(path): \(message)", code: rc)
        }
        db = handle
    }

    deinit { close() }

    public func close() {
        withConnectionLock {
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    private func withConnectionLock<T>(_ operation: () throws -> T) rethrows -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return try operation()
    }

    private func check(_ rc: Int32, _ ok: Int32 = SQLITE_OK) throws {
        guard rc == ok else {
            throw SqlError(message: String(cString: sqlite3_errmsg(db)), code: rc)
        }
    }

    public func exec(_ sql: String) throws {
        try withConnectionLock {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(errMsg)
                throw SqlError(message: message, code: rc)
            }
        }
    }

    private func prepare(_ sql: String, _ params: [SqlValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let stmt else { throw SqlError(message: "empty statement: \(sql)", code: SQLITE_MISUSE) }
        for (index, value) in params.enumerated() {
            let slot = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s): rc = sqlite3_bind_text(stmt, slot, s, -1, SQLITE_TRANSIENT)
            case .int(let i): rc = sqlite3_bind_int64(stmt, slot, i)
            case .real(let d): rc = sqlite3_bind_double(stmt, slot, d)
            case .blob(let data):
                rc = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(stmt, slot, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .null: rc = sqlite3_bind_null(stmt, slot)
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw SqlError(message: String(cString: sqlite3_errmsg(db)), code: rc)
            }
        }
        return stmt
    }

    private func rowFrom(_ stmt: OpaquePointer) -> SqlRow {
        var row = SqlRow()
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(stmt, i) {
                    row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))))
                } else {
                    row[name] = .blob(Data())
                }
            default: row[name] = .null
            }
        }
        return row
    }

    public func run(_ sql: String, _ params: [SqlValue]) throws {
        try withConnectionLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SqlError(message: String(cString: sqlite3_errmsg(db)), code: rc)
            }
        }
    }

    public func all(_ sql: String, _ params: [SqlValue]) throws -> [SqlRow] {
        try withConnectionLock {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var rows: [SqlRow] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    rows.append(rowFrom(stmt))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SqlError(message: String(cString: sqlite3_errmsg(db)), code: rc)
                }
            }
            return rows
        }
    }

    public func first(_ sql: String, _ params: [SqlValue]) throws -> SqlRow? {
        try all(sql, params).first
    }

    public func transaction<T>(_ fn: () throws -> T) throws -> T {
        try withConnectionLock {
            guard !inTransaction else { return try fn() }  // join the enclosing transaction
            inTransaction = true
            defer { inTransaction = false }
            try exec("BEGIN IMMEDIATE")
            do {
                let result = try fn()
                try exec("COMMIT")
                return result
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }
}

/// Resolve the on-disk path used by React Native QuickSQLite: the app's Documents directory.
/// Keeping this exact location lets an App Store update open the existing offline database in
/// place. Early native prototypes wrote under Application Support/FieldCapture; opening the
/// production driver relocates that prototype before SQLite is allowed to create a new file.
public func databaseFilePath(databaseName: String) -> String {
    let fileManager = FileManager.default
    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return documents.appendingPathComponent(databaseName).path
}

/// Relocate an early native prototype without making the destination database visible until its
/// WAL sidecars are in place. A failed or conflicting move throws while the main source database
/// remains at `source`, preventing SQLite from silently creating a fresh empty database.
func migratePrototypeDatabaseIfNeeded(
    from source: String,
    to destination: String,
    fileManager: FileManager = .default
) throws {
    guard !fileManager.fileExists(atPath: destination), fileManager.fileExists(atPath: source) else {
        return
    }

    try fileManager.createDirectory(
        at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // The main database moves last and acts as the commit marker. Destination-only sidecars are
    // accepted so an interrupted earlier attempt can resume safely.
    for suffix in ["-wal", "-shm", ""] {
        let sourcePath = source + suffix
        let destinationPath = destination + suffix
        let sourceExists = fileManager.fileExists(atPath: sourcePath)
        let destinationExists = fileManager.fileExists(atPath: destinationPath)

        if sourceExists && destinationExists {
            throw DatabaseMigrationError(
                message: "Cannot migrate database because both \(sourcePath) and \(destinationPath) exist."
            )
        }
        if sourceExists {
            do {
                try fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)
            } catch {
                throw DatabaseMigrationError(
                    message:
                        "Cannot migrate database from \(sourcePath) to \(destinationPath): \(error.localizedDescription)"
                )
            }
        }
    }

    guard fileManager.fileExists(atPath: destination) else {
        throw DatabaseMigrationError(
            message: "Database migration did not produce the expected file at \(destination)."
        )
    }
}

/// Port of openQuickSqliteDriver — open (creating if needed) the named database.
public func openSystemSqliteDriver(databaseName: String) throws -> SystemSqliteDriver {
    let fileManager = FileManager.default
    let destination = databaseFilePath(databaseName: databaseName)
    let prototypeDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FieldCapture", isDirectory: true)
    let source = prototypeDirectory.appendingPathComponent(databaseName).path

    try migratePrototypeDatabaseIfNeeded(
        from: source,
        to: destination,
        fileManager: fileManager
    )
    return try SystemSqliteDriver(path: destination)
}

/// Port of deleteQuickSqliteDatabase — destroy the named database (and WAL sidecars). Sidecars go
/// first and the main database goes last as the deletion commit marker. A failure is surfaced so a
/// caller cannot announce a successful reset while SQLite state remains on disk.
public func deleteSystemSqliteDatabase(databaseName: String) throws {
    let base = databaseFilePath(databaseName: databaseName)
    for suffix in ["-wal", "-shm", ""] {
        let path = base + suffix
        guard FileManager.default.fileExists(atPath: path) else { continue }
        try FileManager.default.removeItem(atPath: path)
    }
}
