// Port of src/platform/random.ts — secure random bytes + v4 UUIDs.
import Foundation
import Security

public enum PlatformRandomError: Error, LocalizedError, Equatable {
    case invalidLength(Int)
    case unavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidLength(let length): return "random byte length must be positive (got \(length))"
        case .unavailable(let status): return "secure random bytes are unavailable (status \(status))"
        }
    }
}

public func randomBytes(_ length: Int) throws -> Data {
    guard length > 0 else { throw PlatformRandomError.invalidLength(length) }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, length, baseAddress)
    }
    guard status == errSecSuccess else { throw PlatformRandomError.unavailable(status) }
    return data
}

/// Lowercase v4 UUID, matching the TS `crypto.randomUUID()` output shape used on the wire.
public func randomUuid() -> String {
    UUID().uuidString.lowercased()
}
