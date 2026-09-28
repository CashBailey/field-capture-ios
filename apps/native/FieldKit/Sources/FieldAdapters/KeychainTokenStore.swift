// Port of adapters/auth/KeychainTokenStore.ts — `TokenStore` over the iOS Keychain.
// The session never touches SQLite or AsyncStorage. A missing item means signed-out; corrupt data
// or Keychain system failures are surfaced without erasing a potentially recoverable session.
//
// The TS talks to the Keychain via `react-native-keychain`'s generic-password API
// (`Keychain.setGenericPassword(username, password, { service, accessible })`), which maps
// directly onto Keychain Services' `kSecClassGenericPassword` with `kSecAttrService` = the service
// string and `kSecAttrAccount` = the username. Same names are kept here so a device upgrading from
// the RN app (or a future native/RN dual-boot) reads the exact same keychain item.
import Foundation
import FieldDomain
import Security

private let SESSION_SERVICE = "fieldcapture.auth.session"
private let SESSION_ACCOUNT = "fieldcapture"

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain operation failed (OSStatus \(status))" }
    public init(_ status: OSStatus) { self.status = status }
}

public struct KeychainDataError: Error, LocalizedError, Equatable {
    public let errorDescription: String? = "the authentication session stored in Keychain is malformed"

    public init() {}
}

protocol SessionKeychainAccess: Sendable {
    func read() -> (status: OSStatus, data: Data?)
    func update(_ data: Data) -> OSStatus
    func add(_ data: Data) -> OSStatus
    func delete() -> OSStatus
}

private struct SystemSessionKeychainAccess: SessionKeychainAccess {
    func read() -> (status: OSStatus, data: Data?) {
        var query = sessionBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ data: Data) -> OSStatus {
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemUpdate(sessionBaseQuery() as CFDictionary, attributes as CFDictionary)
    }

    func add(_ data: Data) -> OSStatus {
        var query = sessionBaseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    func delete() -> OSStatus {
        SecItemDelete(sessionBaseQuery() as CFDictionary)
    }
}

private func sessionBaseQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SESSION_SERVICE,
        kSecAttrAccount as String: SESSION_ACCOUNT,
    ]
}

public final class KeychainTokenStore: TokenStore, Sendable {
    public let durability: StoreDurability = .durableEncrypted
    private let keychain: any SessionKeychainAccess
    private let lock = NSLock()

    public convenience init() {
        self.init(keychain: SystemSessionKeychainAccess())
    }

    init(keychain: any SessionKeychainAccess) {
        self.keychain = keychain
    }

    public func load() async throws -> AuthSession? {
        try withLock { try loadUnlocked() }
    }

    public func save(_ session: AuthSession) async throws {
        try withLock { try saveUnlocked(session) }
    }

    public func clear() async throws {
        try withLock { try clearUnlocked() }
    }

    public func replace(_ expected: AuthSession?, with replacement: AuthSession?) async throws -> Bool {
        try withLock {
            guard try loadUnlocked() == expected else { return false }
            if let replacement {
                try saveUnlocked(replacement)
            } else {
                try clearUnlocked()
            }
            return true
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func loadUnlocked() throws -> AuthSession? {
        let result = keychain.read()
        switch result.status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result.data, let session = Self.decodeAuthSession(data) else {
                throw KeychainDataError()
            }
            return session
        default:
            throw KeychainError(result.status)
        }
    }

    private func saveUnlocked(_ session: AuthSession) throws {
        let data = try Self.encodeAuthSession(session)
        let updateStatus = keychain.update(data)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = keychain.add(data)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecDuplicateItem {
                // Another writer inserted between update and add. Complete the intended
                // overwrite without introducing a delete window where the session disappears.
                let retryStatus = keychain.update(data)
                guard retryStatus == errSecSuccess else { throw KeychainError(retryStatus) }
                return
            }
            throw KeychainError(addStatus)
        default:
            throw KeychainError(updateStatus)
        }
    }

    private func clearUnlocked() throws {
        let status = keychain.delete()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status)
        }
    }

    // MARK: - Pure encode/decode (unit-testable without touching the real Keychain)

    public static func encodeAuthSession(_ session: AuthSession) throws -> Data {
        var dict: [String: Any] = ["sessionToken": session.sessionToken]
        if let expiresAt = session.expiresAt { dict["expiresAt"] = expiresAt }
        if let refreshToken = session.refreshToken { dict["refreshToken"] = refreshToken }
        if let profile = session.userProfile { dict["userProfile"] = encodeUserProfile(profile) }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    public static func decodeAuthSession(_ data: Data) -> AuthSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let rec = obj as? [String: Any],
            let sessionToken = rec["sessionToken"] as? String, !sessionToken.isEmpty
        else { return nil }
        return AuthSession(
            sessionToken: sessionToken,
            expiresAt: rec["expiresAt"] as? String,
            refreshToken: rec["refreshToken"] as? String,
            userProfile: decodeUserProfile(rec["userProfile"])
        )
    }

    private static func encodeUserProfile(_ p: UserProfile) -> [String: Any] {
        var o: [String: Any] = [:]
        if let v = p.id { o["id"] = v }
        if let v = p.username { o["username"] = v }
        if let v = p.email { o["email"] = v }
        if let v = p.displayName { o["displayName"] = v }
        if let v = p.title { o["title"] = v }
        if let v = p.department { o["department"] = v }
        if let v = p.isActive { o["isActive"] = v }
        if let v = p.employeeId { o["employeeId"] = v }
        if let v = p.phone { o["phone"] = v }
        if let v = p.assignedYard { o["assignedYard"] = v }
        if let v = p.defaultTruck { o["defaultTruck"] = v }
        if let v = p.defaultTrailer { o["defaultTrailer"] = v }
        if let v = p.accessProfile { o["accessProfile"] = v }
        if let v = p.roles { o["roles"] = v }
        if let v = p.language { o["language"] = v }
        return o
    }

    private static func decodeUserProfile(_ any: Any?) -> UserProfile? {
        guard let rec = any as? [String: Any] else { return nil }
        return UserProfile(
            id: rec["id"] as? String,
            username: rec["username"] as? String,
            email: rec["email"] as? String,
            displayName: rec["displayName"] as? String,
            title: rec["title"] as? String,
            department: rec["department"] as? String,
            isActive: rec["isActive"] as? Bool,
            employeeId: rec["employeeId"] as? String,
            phone: rec["phone"] as? String,
            assignedYard: rec["assignedYard"] as? String,
            defaultTruck: rec["defaultTruck"] as? String,
            defaultTrailer: rec["defaultTrailer"] as? String,
            accessProfile: rec["accessProfile"] as? String,
            roles: rec["roles"] as? [String],
            language: rec["language"] as? String
        )
    }
}
