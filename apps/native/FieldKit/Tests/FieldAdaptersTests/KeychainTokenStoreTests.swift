// No upstream TS test exists for KeychainTokenStore (adapters/auth/KeychainTokenStore.ts has no
// corresponding __tests__ file — react-native-keychain has no useful in-memory fake, so the TS
// app relies on integration/manual testing for this adapter). Real Keychain I/O is inappropriate
// for a unit test, so an injected in-memory seam exercises read-status handling and atomic save
// semantics; pure session encoding remains covered here as well.
import FieldDomain
import Security
import XCTest

@testable import FieldAdapters

private final class FakeSessionKeychain: SessionKeychainAccess, @unchecked Sendable {
    var readResult: (status: OSStatus, data: Data?)
    var updateStatuses: [OSStatus]
    var addStatuses: [OSStatus]
    var deleteStatus: OSStatus
    private(set) var updatedData: [Data] = []
    private(set) var addedData: [Data] = []
    private(set) var deleteCount = 0

    init(
        readResult: (status: OSStatus, data: Data?) = (errSecItemNotFound, nil),
        updateStatuses: [OSStatus] = [],
        addStatuses: [OSStatus] = [],
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.readResult = readResult
        self.updateStatuses = updateStatuses
        self.addStatuses = addStatuses
        self.deleteStatus = deleteStatus
    }

    func read() -> (status: OSStatus, data: Data?) {
        readResult
    }

    func update(_ data: Data) -> OSStatus {
        updatedData.append(data)
        return updateStatuses.removeFirst()
    }

    func add(_ data: Data) -> OSStatus {
        addedData.append(data)
        return addStatuses.removeFirst()
    }

    func delete() -> OSStatus {
        deleteCount += 1
        return deleteStatus
    }
}

final class KeychainTokenStoreTests: XCTestCase {
    func test_durabilityIsDurableEncrypted() {
        XCTAssertEqual(KeychainTokenStore().durability, .durableEncrypted)
    }

    func test_encodeDecodeRoundTripsAMinimalSession() throws {
        let session = AuthSession(sessionToken: "tok-1")
        let data = try KeychainTokenStore.encodeAuthSession(session)
        XCTAssertEqual(KeychainTokenStore.decodeAuthSession(data), session)
    }

    func test_encodeDecodeRoundTripsAFullSessionWithProfile() throws {
        let session = AuthSession(
            sessionToken: "tok-1",
            expiresAt: "2026-06-11T00:00:00Z",
            refreshToken: "refresh-9",
            userProfile: UserProfile(
                id: "user-1", username: "driver.user", email: "driver.user@example.test",
                displayName: "Driver User", title: "Driver", department: "Operations",
                isActive: true, employeeId: "emp-1", phone: "(432) 555-0101",
                assignedYard: "Midland Yard", defaultTruck: "Truck 7", defaultTrailer: "Vacuum Trailer 19",
                accessProfile: "driver", roles: ["driver", "end_user"], language: "en"
            )
        )
        let data = try KeychainTokenStore.encodeAuthSession(session)
        XCTAssertEqual(KeychainTokenStore.decodeAuthSession(data), session)
    }

    func test_decodeRejectsAnEmptySessionToken() {
        let data = try! JSONSerialization.data(withJSONObject: ["sessionToken": ""])
        XCTAssertNil(KeychainTokenStore.decodeAuthSession(data))
    }

    func test_decodeRejectsGarbageData() {
        XCTAssertNil(KeychainTokenStore.decodeAuthSession(Data([0xFF, 0x00, 0x01])))
    }

    func test_loadReturnsNilOnlyWhenTheItemIsNotFound() async throws {
        let keychain = FakeSessionKeychain()

        let loaded = try await KeychainTokenStore(keychain: keychain).load()

        XCTAssertNil(loaded)
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_loadSurfacesKeychainReadFailuresWithoutDeletingTheSession() async {
        let keychain = FakeSessionKeychain(readResult: (errSecInteractionNotAllowed, nil))

        do {
            _ = try await KeychainTokenStore(keychain: keychain).load()
            XCTFail("expected KeychainError")
        } catch let error as KeychainError {
            XCTAssertEqual(error.status, errSecInteractionNotAllowed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_loadSurfacesMalformedSessionDataWithoutDeletingIt() async {
        let keychain = FakeSessionKeychain(readResult: (errSecSuccess, Data("not-json".utf8)))

        do {
            _ = try await KeychainTokenStore(keychain: keychain).load()
            XCTFail("expected KeychainDataError")
        } catch is KeychainDataError {
            // Expected: callers can distinguish corrupt data from a signed-out session.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_saveUpdatesAnExistingSessionWithoutDeletingIt() async throws {
        let keychain = FakeSessionKeychain(updateStatuses: [errSecSuccess])
        let session = AuthSession(sessionToken: "replacement")

        try await KeychainTokenStore(keychain: keychain).save(session)

        XCTAssertEqual(keychain.updatedData, [try KeychainTokenStore.encodeAuthSession(session)])
        XCTAssertTrue(keychain.addedData.isEmpty)
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_saveAddsWhenUpdateReportsItemNotFoundWithoutDeleting() async throws {
        let keychain = FakeSessionKeychain(
            updateStatuses: [errSecItemNotFound],
            addStatuses: [errSecSuccess])
        let session = AuthSession(sessionToken: "new")

        try await KeychainTokenStore(keychain: keychain).save(session)

        let encoded = try KeychainTokenStore.encodeAuthSession(session)
        XCTAssertEqual(keychain.updatedData, [encoded])
        XCTAssertEqual(keychain.addedData, [encoded])
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_saveRetriesUpdateWhenAnotherWriterWinsTheAddRace() async throws {
        let keychain = FakeSessionKeychain(
            updateStatuses: [errSecItemNotFound, errSecSuccess],
            addStatuses: [errSecDuplicateItem])
        let session = AuthSession(sessionToken: "winner")

        try await KeychainTokenStore(keychain: keychain).save(session)

        XCTAssertEqual(keychain.updatedData.count, 2)
        XCTAssertEqual(keychain.addedData.count, 1)
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_replaceUpdatesOnlyWhenTheStoredSessionMatches() async throws {
        let old = AuthSession(sessionToken: "old")
        let fresh = AuthSession(sessionToken: "fresh")
        let keychain = FakeSessionKeychain(
            readResult: (errSecSuccess, try KeychainTokenStore.encodeAuthSession(old)),
            updateStatuses: [errSecSuccess])
        let store = KeychainTokenStore(keychain: keychain)

        let rejected = try await store.replace(AuthSession(sessionToken: "different"), with: fresh)
        XCTAssertFalse(rejected)
        XCTAssertTrue(keychain.updatedData.isEmpty)
        let replaced = try await store.replace(old, with: fresh)
        XCTAssertTrue(replaced)
        XCTAssertEqual(keychain.updatedData, [try KeychainTokenStore.encodeAuthSession(fresh)])
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func test_replaceClearsOnlyTheExpectedStoredSession() async throws {
        let old = AuthSession(sessionToken: "old")
        let keychain = FakeSessionKeychain(
            readResult: (errSecSuccess, try KeychainTokenStore.encodeAuthSession(old)))
        let store = KeychainTokenStore(keychain: keychain)

        let cleared = try await store.replace(old, with: nil)
        XCTAssertTrue(cleared)

        XCTAssertEqual(keychain.deleteCount, 1)
        XCTAssertTrue(keychain.updatedData.isEmpty)
        XCTAssertTrue(keychain.addedData.isEmpty)
    }
}
