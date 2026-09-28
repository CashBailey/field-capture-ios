// Port of src/data/FileBlobBytesSource.ts — file-backed blob bytes source for captured
// photos/signatures. SQLite stores the blob metadata and lifecycle; this adapter stores the
// actual bytes under the app's private documents area so they survive restart and are deleted
// only through UploadEngine.purgeOnce().
import Foundation
import FieldContracts
import FieldDomain

public protocol BlobFileDriver {
    var rootUri: String { get }
    func ensureRoot() async throws
    func write(name: String, bytes: Data) async throws -> String
    func read(uri: String) async throws -> Data
    func delete(uri: String) async throws
}

func blobFilename(_ blobId: String) -> String {
    var safe = blobId.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
    while safe.hasPrefix("-") { safe.removeFirst() }
    while safe.hasSuffix("-") { safe.removeLast() }
    let readable = safe.isEmpty ? "blob" : safe
    let collisionGuard = String(sha256HexOfString(blobId).prefix(16))
    return "\(readable)-\(collisionGuard).bin"
}

func fileUri(_ path: String) -> String {
    path.hasPrefix("file://") ? path : "file://\(path)"
}

func pathFromUri(_ uri: String) -> String {
    uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
}

public struct BlobFileError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class FileBlobBytesSource: BlobBytesSource {
    private let driver: BlobFileDriver

    public init(_ driver: BlobFileDriver) {
        self.driver = driver
    }

    public func persist(blobId: String, bytes: Data) async throws -> String {
        try await driver.ensureRoot()
        return try await driver.write(name: blobFilename(blobId), bytes: bytes)
    }

    public func read(localUri: String, offset: Int, length: Int) async throws -> Data {
        guard offset >= 0 else { throw BlobFileError("invalid blob read offset \(offset)") }
        guard length >= 0 else { throw BlobFileError("invalid blob read length \(length)") }
        let bytes = try await driver.read(uri: localUri)
        let start = min(offset, bytes.count)
        let end = min(offset + length, bytes.count)
        return bytes.subdata(in: start..<end)
    }

    public func delete(localUri: String) async throws {
        try await driver.delete(uri: localUri)
    }
}

/// Native blob file driver rooted in the app's private documents area (captures/), excluded from
/// backup and protected until first unlock — the RN version's NSURLIsExcludedFromBackupKey +
/// NSFileProtectionCompleteUntilFirstUserAuthentication, expressed natively.
public func createNativeBlobFileDriver(rootPath: String? = nil) -> BlobFileDriver {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    return NativeBlobFileDriver(rootPath: rootPath ?? "\(documents)/captures")
}

final class NativeBlobFileDriver: BlobFileDriver {
    let rootPath: String
    var rootUri: String { fileUri(rootPath) }

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    func ensureRoot() async throws {
        var url = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: rootPath)
        #endif
    }

    func write(name: String, bytes: Data) async throws -> String {
        try await ensureRoot()
        let path = "\(rootPath)/\(name)"
        try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        return fileUri(path)
    }

    func read(uri: String) async throws -> Data {
        let path = pathFromUri(uri)
        guard FileManager.default.fileExists(atPath: path) else {
            throw BlobFileError("blob bytes file is missing: \(uri)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func delete(uri: String) async throws {
        let path = pathFromUri(uri)
        // Idempotent by design: a crash after deleting bytes but before stamping `purgedAt` must
        // be recoverable on the next purge sweep.
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
