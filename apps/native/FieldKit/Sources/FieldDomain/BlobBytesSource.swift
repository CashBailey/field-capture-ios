// From src/domain/blobUpload.ts — seam over the device's blob bytes (photo/signature files).
// The engine never touches the filesystem directly; tests use an in-memory source. `delete` is
// called ONLY for purgeable blobs — implementations need no further guard, but must fail loud
// rather than silently succeed on a missing file.
import Foundation

public protocol BlobBytesSource {
    func read(localUri: String, offset: Int, length: Int) async throws -> Data
    func delete(localUri: String) async throws
}
