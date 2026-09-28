// Port of __tests__/blob-bytes-source.test.ts — file-backed blob bytes source: production
// capture bytes live outside SQLite, but with the same never-silently-lose behavior as the
// upload engine. This test uses a fake file driver so it stays hardware-free and does not touch
// native modules.
import XCTest

@testable import FieldData

private final class FakeBlobFileDriver: BlobFileDriver {
    let rootUri = "file:///private/captures"
    private var files: [String: Data] = [:]

    func ensureRoot() async throws {
        // no-op: the fake root always exists
    }

    func write(name: String, bytes: Data) async throws -> String {
        let uri = "\(rootUri)/\(name)"
        files[uri] = bytes
        return uri
    }

    func read(uri: String) async throws -> Data {
        guard let bytes = files[uri] else {
            throw NSError(
                domain: "FakeBlobFileDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fake file \(uri)"]
            )
        }
        return bytes
    }

    func delete(uri: String) async throws {
        files.removeValue(forKey: uri)
    }

    func has(_ uri: String) -> Bool { files[uri] != nil }
}

final class FileBlobBytesSourceTests: XCTestCase {
    func testPersistsCaptureBytesUnderAStableBlobFilenameAndReadsTusChunks() async throws {
        let driver = FakeBlobFileDriver()
        let source = FileBlobBytesSource(driver)

        let uri = try await source.persist(blobId: "blob/with spaces", bytes: Data([1, 2, 3, 4, 5]))

        XCTAssertEqual(uri, "file:///private/captures/\(blobFilename("blob/with spaces"))")
        XCTAssertTrue(driver.has(uri))
        let chunk = try await source.read(localUri: uri, offset: 1, length: 3)
        XCTAssertEqual(chunk, Data([2, 3, 4]))
    }

    func testOverwritesTheSameBlobIdAndDeletesIdempotently() async throws {
        let driver = FakeBlobFileDriver()
        let source = FileBlobBytesSource(driver)

        let first = try await source.persist(blobId: "blob-1", bytes: Data([1, 2, 3]))
        let second = try await source.persist(blobId: "blob-1", bytes: Data([9]))

        XCTAssertEqual(second, first)
        let readBack = try await source.read(localUri: first, offset: 0, length: 10)
        XCTAssertEqual(readBack, Data([9]))
        try await source.delete(localUri: first)
        XCTAssertFalse(driver.has(first))
        try await source.delete(localUri: first)
        XCTAssertFalse(driver.has(first))
    }

    func testSanitizedNamesRemainDistinctForDifferentBlobIds() {
        XCTAssertNotEqual(blobFilename("blob/a"), blobFilename("blob-a"))
    }
}
