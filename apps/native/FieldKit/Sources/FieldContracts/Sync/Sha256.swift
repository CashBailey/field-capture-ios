// Port of sync/sha256.ts — SHA-256 digest used for blob integrity anchors (capture hashes, upload
// verification, print payload hashes). The TS version is a dependency-free pure-JS FIPS 180-4
// implementation (jest/vitest/on-device parity was the point on that runtime); on iOS the
// equivalent parity concern doesn't apply, so per PORTING.md this is backed by CryptoKit instead
// of a hand-rolled Swift port of the same bit-twiddling.
import CryptoKit
import Foundation

/// SHA-256 of `bytes`, as a lowercase hex string.
public func sha256Hex(_ bytes: Data) -> String {
    let digest = SHA256.hash(data: bytes)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Convenience: SHA-256 of a UTF-8 string.
public func sha256HexOfString(_ value: String) -> String {
    sha256Hex(Data(value.utf8))
}
