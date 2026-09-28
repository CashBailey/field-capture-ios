// Port of src/data/database.ts — open (and migrate) the durable local database. This is the only
// module that talks to the SQLite adapter directly; everything else sees a `SqlDriver` plus an
// HONEST durability verdict.
//
// Encryption: the key comes from the device keychain (EncryptionKey.swift). `PRAGMA key` MUST be
// the first statement after open. Whether SQLCipher is REALLY active is verified with
// `PRAGMA cipher_version`; a build without SQLCipher (the system libsqlite3) silently ignores
// `PRAGMA key`, so the durability verdict is taken from the database, never assumed from
// configuration. The database file additionally carries iOS Data Protection
// (complete-until-first-unlock), the platform-native at-rest encryption.
import Foundation
import FieldDomain

public let DEFAULT_DATABASE_NAME = "fieldcapture.db"

/// The database exists but cannot be decrypted with the available key (keychain entry lost or
/// rotated). The data is unreadable; the ONLY way forward is an explicit, user-confirmed reset
/// (`resetLocalDatabase`). Never auto-wipe.
public struct DatabaseKeyMismatchError: Error, LocalizedError {
    public let message: String
    public let cause: Error?
    public init(_ message: String, cause: Error? = nil) {
        self.message = message
        self.cause = cause
    }
    public var errorDescription: String? { message }
}

/// Destroy the local database so the app can start fresh after a key loss. DESTRUCTIVE: any
/// unsynced evidence inside is gone — callers must put an explicit user confirmation in front.
public func resetLocalDatabase(databaseName: String = DEFAULT_DATABASE_NAME) throws {
    try deleteSystemSqliteDatabase(databaseName: databaseName)
}

public struct OpenedDatabase {
    public let db: SqlDriver
    /// What this database actually guarantees — verified, not assumed.
    public let durability: StoreDurability
}

/// True when the underlying build is SQLCipher (plain SQLite returns no cipher_version row).
private func cipherActive(_ db: SqlDriver) -> Bool {
    guard let row = try? db.first("PRAGMA cipher_version"),
        let version = row.string("cipher_version")
    else { return false }
    return !version.isEmpty
}

public func openFieldDatabase(encryptionKey: String, databaseName: String = DEFAULT_DATABASE_NAME)
    throws -> OpenedDatabase
{
    let db = try openSystemSqliteDriver(databaseName: databaseName)
    // Hex-quoted key form; the key itself is random hex from the keychain (never user input).
    guard encryptionKey.range(of: "^[0-9a-f]+$", options: [.regularExpression, .caseInsensitive]) != nil
    else {
        throw SqlError(message: "database encryption key must be hex (got a non-hex string)", code: 1)
    }
    try db.exec("PRAGMA key = \"x'\(encryptionKey)'\"")
    let durability: StoreDurability = cipherActive(db) ? .durableEncrypted : .durablePlain
    // First real read: with a wrong/lost key SQLCipher fails here ("file is not a database").
    // Classify it so the boot screen can offer an explicit reset instead of a crash loop.
    do {
        _ = try db.first("SELECT count(*) AS n FROM sqlite_master")
    } catch {
        throw DatabaseKeyMismatchError(
            "local database \"\(databaseName)\" cannot be decrypted with the stored key — the "
                + "keychain entry was lost or rotated. Local data is unreadable; an explicit reset "
                + "is required.",
            cause: error)
    }
    try db.exec("PRAGMA journal_mode = WAL")
    try db.exec("PRAGMA foreign_keys = ON")
    try migrate(db)
    // Platform at-rest encryption for the plain-SQLite build (matches the keychain key's
    // after-first-unlock availability so background sync keeps working).
    #if os(iOS)
        for suffix in ["", "-wal", "-shm"] {
            let path = db.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path)
        }
    #endif
    return OpenedDatabase(db: db, durability: durability)
}
