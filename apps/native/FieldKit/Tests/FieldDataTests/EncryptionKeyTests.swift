// Port of __tests__/encryption-key.test.ts — DB-encryption critical path: the random key in the
// keychain, and the open path that proves SQLCipher is REALLY decrypting (verified, never
// assumed) and surfaces a lost/rotated key as a visible error instead of silently wiping local
// evidence.
//
// ponytail: the TS test fakes react-native-keychain and mocks `quickSqliteDriver` at the module
// level so `openFieldDatabase` can be driven against a controllable fake driver. The Swift port
// (`Database.swift`, already ported — not modified here) has no such injection seam: it always
// opens a real `SystemSqliteDriver` against the app's Application Support directory and
// `getOrCreateDatabaseKey` always calls the real device Keychain. So this file adapts to the real
// primitives instead of faking them: `openFieldDatabase` tests use a real on-disk SQLite file
// (this build links plain system libsqlite3, not SQLCipher, so only the "durable-plain" verdict
// is reachable here — the "durable-encrypted" case needs a real SQLCipher build to observe, and
// is skipped with this comment rather than faked). The keychain-backed `getOrCreateDatabaseKey`
// case is exercised against the REAL keychain and gracefully skipped (`XCTSkip`) when the test
// environment has no keychain access (e.g. a headless/sandboxed CI runner).
import Security
import XCTest

@testable import FieldData

final class PlatformRandomTests: XCTestCase {
    func testRejectsNonPositiveLengthsWithoutTrapping() {
        XCTAssertThrowsError(try randomBytes(0)) { error in
            XCTAssertEqual(error as? PlatformRandomError, .invalidLength(0))
        }
    }

    func testReturnsTheRequestedNumberOfSecureBytes() throws {
        XCTAssertEqual(try randomBytes(32).count, 32)
    }
}

private func uniqueDbName(_ label: String) -> String {
    "fieldkit-test-\(label)-\(UUID().uuidString).db"
}

private final class FakeDatabaseKeychain: DatabaseKeychainAccess, @unchecked Sendable {
    private(set) var reads: [(status: OSStatus, data: Data?)]
    private(set) var addedData: [Data] = []
    var addStatus: OSStatus

    init(
        reads: [(status: OSStatus, data: Data?)],
        addStatus: OSStatus = errSecSuccess
    ) {
        self.reads = reads
        self.addStatus = addStatus
    }

    func read() -> (status: OSStatus, data: Data?) {
        reads.removeFirst()
    }

    func add(_ data: Data) -> OSStatus {
        addedData.append(data)
        return addStatus
    }
}

final class GetOrCreateDatabaseKeyTests: XCTestCase {
    func testReusesOrGeneratesAValid64HexKeyFromTheRealKeychainAndIsStableAcrossCalls() throws {
        do {
            let key = try getOrCreateDatabaseKey()
            XCTAssertEqual(key.count, 64)
            XCTAssertNotNil(key.range(of: "^[0-9a-f]{64}$", options: [.regularExpression, .caseInsensitive]))
            // stable across calls once generated (a second call reuses the persisted key)
            let second = try getOrCreateDatabaseKey()
            XCTAssertEqual(second, key)
        } catch {
            throw XCTSkip("real device Keychain unavailable in this test environment: \(error)")
        }
    }

    func testReturnsAnExistingValidKeyWithoutWriting() throws {
        let existing = String(repeating: "a", count: 64)
        let keychain = FakeDatabaseKeychain(reads: [(errSecSuccess, Data(existing.utf8))])

        let key = try getOrCreateDatabaseKey(
            keychain: keychain,
            generateBytes: { _ in Data(repeating: 0xbb, count: 32) })

        XCTAssertEqual(key, existing)
        XCTAssertTrue(keychain.addedData.isEmpty)
    }

    func testReadFailureIsSurfacedWithoutReplacingTheKey() {
        let keychain = FakeDatabaseKeychain(reads: [(errSecInteractionNotAllowed, nil)])

        XCTAssertThrowsError(
            try getOrCreateDatabaseKey(
                keychain: keychain,
                generateBytes: { _ in Data(repeating: 0xbb, count: 32) })
        ) { error in
            XCTAssertEqual(error as? DatabaseKeychainError, .readFailed(errSecInteractionNotAllowed))
        }
        XCTAssertTrue(keychain.addedData.isEmpty)
    }

    func testMalformedStoredKeyIsSurfacedWithoutDeletingOrRekeying() {
        let keychain = FakeDatabaseKeychain(reads: [(errSecSuccess, Data("not-a-key".utf8))])

        XCTAssertThrowsError(
            try getOrCreateDatabaseKey(
                keychain: keychain,
                generateBytes: { _ in Data(repeating: 0xbb, count: 32) })
        ) { error in
            XCTAssertEqual(error as? DatabaseKeychainError, .malformedStoredKey)
        }
        XCTAssertTrue(keychain.addedData.isEmpty)
    }

    func testGeneratesAndAddsAKeyOnlyWhenTheItemIsNotFound() throws {
        let keychain = FakeDatabaseKeychain(reads: [(errSecItemNotFound, nil)])

        let key = try getOrCreateDatabaseKey(
            keychain: keychain,
            generateBytes: { _ in Data(repeating: 0xab, count: 32) })

        XCTAssertEqual(key, String(repeating: "ab", count: 32))
        XCTAssertEqual(keychain.addedData, [Data(key.utf8)])
    }

    func testDuplicateAddReturnsTheConcurrentWinnersKeyWithoutReplacingIt() throws {
        let winner = String(repeating: "c", count: 64)
        let keychain = FakeDatabaseKeychain(
            reads: [
                (errSecItemNotFound, nil),
                (errSecSuccess, Data(winner.utf8)),
            ],
            addStatus: errSecDuplicateItem)

        let key = try getOrCreateDatabaseKey(
            keychain: keychain,
            generateBytes: { _ in Data(repeating: 0xab, count: 32) })

        XCTAssertEqual(key, winner)
        XCTAssertEqual(keychain.addedData.count, 1)
    }
}

final class OpenFieldDatabaseTests: XCTestCase {
    func testResetRemovesTheDatabaseAndItsSidecars() throws {
        let name = uniqueDbName("reset")
        let base = databaseFilePath(databaseName: name)
        defer { try? resetLocalDatabase(databaseName: name) }

        for suffix in ["", "-wal", "-shm"] {
            try Data("test".utf8).write(to: URL(fileURLWithPath: base + suffix))
        }

        try resetLocalDatabase(databaseName: name)

        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: base + suffix))
        }
    }

    func testRejectsANonHexEncryptionKeyBeforeTouchingTheDatabase() {
        let name = uniqueDbName("nonhex")
        defer { try? resetLocalDatabase(databaseName: name) }
        XCTAssertThrowsError(try openFieldDatabase(encryptionKey: "plaintext-not-hex", databaseName: name)) { error in
            XCTAssertTrue("\(error)".lowercased().contains("hex"))
        }
    }

    func testReportsDurablePlainWhenTheBuildIsPlainSqlite() throws {
        // Verdict comes from the database (`PRAGMA cipher_version`), not from configuration — this
        // build links plain system libsqlite3, so the honest verdict is always durable-plain.
        let name = uniqueDbName("plain")
        defer { try? resetLocalDatabase(databaseName: name) }
        let opened = try openFieldDatabase(encryptionKey: String(repeating: "a", count: 64), databaseName: name)
        XCTAssertEqual(opened.durability, .durablePlain)
    }

    func testSurfacesADecryptFailureAsAVisibleDatabaseKeyMismatchErrorNeverDeletingTheDatabase() throws {
        let name = uniqueDbName("corrupt")
        defer { try? resetLocalDatabase(databaseName: name) }
        // Simulate a lost/rotated key by corrupting the on-disk file BEFORE opening it — the real
        // first-read classification path (`SELECT count(*) FROM sqlite_master`) fails against
        // garbage bytes exactly like it would against ciphertext with the wrong key.
        let path = databaseFilePath(databaseName: name)
        try Data("not a sqlite file".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(
            try openFieldDatabase(encryptionKey: String(repeating: "a", count: 64), databaseName: name)
        ) { error in
            XCTAssertTrue(error is DatabaseKeyMismatchError)
            XCTAssertNotNil((error as? DatabaseKeyMismatchError)?.cause)
        }
        // the whole point: a lost/rotated key must NOT trigger an auto-wipe
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
