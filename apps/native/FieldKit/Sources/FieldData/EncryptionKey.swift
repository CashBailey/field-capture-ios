// Port of src/data/encryptionKey.ts — the database encryption key: 32 random bytes, hex-encoded,
// generated once per install and held in the device keychain. The key never leaves the device and
// is never derived from anything user-visible.
//
// If the keychain entry is lost (e.g. biometrics reset invalidated it), an encrypted database can
// no longer be decrypted — callers surface that as a visible reset, never a silent wipe.
import Foundation
import Security

private let KEY_NAME = "fieldcapture.db.key"
private let KEY_ACCOUNT = "fieldcapture"

public enum DatabaseKeychainError: Error, LocalizedError, Equatable {
    case readFailed(OSStatus)
    case malformedStoredKey
    case writeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let status):
            return "reading the database key from Keychain failed (\(status))"
        case .malformedStoredKey:
            return "the database key stored in Keychain is malformed"
        case .writeFailed(let status):
            return "writing the database key to Keychain failed (\(status))"
        }
    }
}

protocol DatabaseKeychainAccess: Sendable {
    func read() -> (status: OSStatus, data: Data?)
    func add(_ data: Data) -> OSStatus
}

private struct SystemDatabaseKeychainAccess: DatabaseKeychainAccess {
    func read() -> (status: OSStatus, data: Data?) {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(_ data: Data) -> OSStatus {
        var attributes = keychainQuery()
        attributes[kSecValueData as String] = data
        // Available after first unlock so background retry can run; never synced off-device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }
}

private func toHex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func keychainQuery() -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KEY_NAME,
        kSecAttrAccount as String: KEY_ACCOUNT,
    ]
}

private func isValidDatabaseKey(_ key: String) -> Bool {
    key.count == 64
        && key.range(of: "^[0-9a-f]{64}$", options: [.regularExpression, .caseInsensitive]) != nil
}

private func readExistingKey(from keychain: any DatabaseKeychainAccess) throws -> String? {
    let result = keychain.read()
    switch result.status {
    case errSecItemNotFound:
        return nil
    case errSecSuccess:
        guard let data = result.data,
            let key = String(data: data, encoding: .utf8),
            isValidDatabaseKey(key)
        else {
            throw DatabaseKeychainError.malformedStoredKey
        }
        return key
    default:
        throw DatabaseKeychainError.readFailed(result.status)
    }
}

func getOrCreateDatabaseKey(
    keychain: any DatabaseKeychainAccess,
    generateBytes: (Int) throws -> Data
) throws -> String {
    if let existing = try readExistingKey(from: keychain) {
        return existing
    }

    let key = toHex(try generateBytes(32))
    let status = keychain.add(Data(key.utf8))
    switch status {
    case errSecSuccess:
        return key
    case errSecDuplicateItem:
        // Another caller won the get-or-create race. Never replace an established database key:
        // doing so could make an existing encrypted database permanently unreadable.
        guard let existing = try readExistingKey(from: keychain) else {
            throw DatabaseKeychainError.writeFailed(status)
        }
        return existing
    default:
        throw DatabaseKeychainError.writeFailed(status)
    }
}

public func getOrCreateDatabaseKey() throws -> String {
    try getOrCreateDatabaseKey(
        keychain: SystemDatabaseKeychainAccess(),
        generateBytes: randomBytes)
}
