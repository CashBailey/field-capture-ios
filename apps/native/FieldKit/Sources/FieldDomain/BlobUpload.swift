// Port of src/domain/blobUpload.ts — Domain seams for the photo/signature/document upload flow
// (ADR 004 two-phase attachments). A captured blob is stored durably on the device with its
// SHA-256, uploaded via a tus-style resumable session, then linked to its parent record by a
// separate append-only command. The local bytes are purgeable ONLY after Hub confirms BOTH the
// upload AND the link commit (`isBlobPurgeable`) — anything less stays on the phone.
//
// Pure protocols + volatile test seams. Production: FieldData's durable SQLite blob-upload store +
// a filesystem-backed `BlobBytesSource` (see `FileBlobBytesSource` in FieldData).
//
// `BlobBytesSource` itself lives in BlobBytesSource.swift (seeded ahead of this port); this file
// carries everything else from blobUpload.ts, plus the `VolatileBlobBytesSource` test seam.
import Foundation
import FieldContracts

/// The contracts blob lifecycle record plus capture metadata, session state, and link identity.
public struct BlobUploadRecord: Equatable, Sendable {
    public var blobId: String
    public var sha256: String
    public var byteLength: Int
    public var state: BlobLifecycleState
    /// Set once Hub confirms whole-file receipt.
    public var uploadConfirmed: Bool
    /// Set once the append-only attachment-link command commits.
    public var linkConfirmed: Bool
    public var mimeType: String
    /// Where the bytes live on the device (file URI). Opaque to the engine.
    public var localUri: String
    /// Client-generated attachment identity — duplicate registrations are idempotent on this.
    public var attachmentId: String
    public var parentType: AttachBlobParentType
    public var parentId: String
    public var attachmentKind: AttachBlobKind
    /// Idempotency key for the upload-session open (dedupe by content hash happens Hub-side).
    public var sessionIdempotencyKey: String
    /// opId of the parent record's own outbox operation — the link command depends on it.
    public var parentOpId: String?
    /// Bytes the server has acknowledged (durable resume point).
    public var bytesAcked: Int
    public var uploadSessionId: String?
    public var uploadUrl: String?
    /// opId of the enqueued attachment-link command, once built.
    public var linkOpId: String?
    /// Set when the local bytes were deleted after full sync (record stays as proof).
    public var purgedAt: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        blobId: String,
        sha256: String,
        byteLength: Int,
        state: BlobLifecycleState,
        uploadConfirmed: Bool,
        linkConfirmed: Bool,
        mimeType: String,
        localUri: String,
        attachmentId: String,
        parentType: AttachBlobParentType,
        parentId: String,
        attachmentKind: AttachBlobKind,
        sessionIdempotencyKey: String,
        parentOpId: String? = nil,
        bytesAcked: Int,
        uploadSessionId: String? = nil,
        uploadUrl: String? = nil,
        linkOpId: String? = nil,
        purgedAt: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.blobId = blobId
        self.sha256 = sha256
        self.byteLength = byteLength
        self.state = state
        self.uploadConfirmed = uploadConfirmed
        self.linkConfirmed = linkConfirmed
        self.mimeType = mimeType
        self.localUri = localUri
        self.attachmentId = attachmentId
        self.parentType = parentType
        self.parentId = parentId
        self.attachmentKind = attachmentKind
        self.sessionIdempotencyKey = sessionIdempotencyKey
        self.parentOpId = parentOpId
        self.bytesAcked = bytesAcked
        self.uploadSessionId = uploadSessionId
        self.uploadUrl = uploadUrl
        self.linkOpId = linkOpId
        self.purgedAt = purgedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol BlobUploadStore {
    var durability: StoreDurability { get }
    func save(_ record: BlobUploadRecord) throws
    func get(_ blobId: String) throws -> BlobUploadRecord?
    func getByAttachmentId(_ attachmentId: String) throws -> BlobUploadRecord?
    func list() throws -> [BlobUploadRecord]
    func listByState(_ state: BlobLifecycleState) throws -> [BlobUploadRecord]
    /// Fully confirmed records whose local bytes have not already been deleted.
    ///
    /// Keeping this query in the store lets a durable implementation select only the safe purge
    /// candidates without hiding a read failure behind an empty in-memory filter.
    func listReadyToPurge() throws -> [BlobUploadRecord]
}

/// In-memory blob store. VOLATILE — TEST SEAM ONLY.
public final class VolatileBlobUploadStore: BlobUploadStore {
    public let durability: StoreDurability = .volatileMemory
    private var byBlobId: [String: BlobUploadRecord] = [:]

    public init() {}

    public func save(_ record: BlobUploadRecord) {
        byBlobId[record.blobId] = record
    }

    public func get(_ blobId: String) -> BlobUploadRecord? {
        byBlobId[blobId]
    }

    public func getByAttachmentId(_ attachmentId: String) -> BlobUploadRecord? {
        list().first { $0.attachmentId == attachmentId }
    }

    public func list() -> [BlobUploadRecord] {
        Array(byBlobId.values)
    }

    public func listByState(_ state: BlobLifecycleState) -> [BlobUploadRecord] {
        list().filter { $0.state == state }
    }

    public func listReadyToPurge() -> [BlobUploadRecord] {
        list().filter {
            $0.purgedAt == nil
                && isBlobPurgeable(
                    BlobRecord(
                        blobId: $0.blobId,
                        sha256: $0.sha256,
                        byteLength: $0.byteLength,
                        state: $0.state,
                        uploadConfirmed: $0.uploadConfirmed,
                        linkConfirmed: $0.linkConfirmed
                    ))
        }
    }
}

public struct BlobBytesSourceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// In-memory bytes source for tests: register a buffer per URI.
public final class VolatileBlobBytesSource: BlobBytesSource {
    private var byUri: [String: Data] = [:]

    public init() {}

    public func put(_ localUri: String, _ bytes: Data) {
        byUri[localUri] = bytes
    }

    public func has(_ localUri: String) -> Bool {
        byUri[localUri] != nil
    }

    public func read(localUri: String, offset: Int, length: Int) async throws -> Data {
        guard let bytes = byUri[localUri] else {
            throw BlobBytesSourceError("no bytes at \(localUri)")
        }
        let start = min(offset, bytes.count)
        let end = min(offset + length, bytes.count)
        return bytes.subdata(in: start..<end)
    }

    public func delete(localUri: String) async throws {
        byUri.removeValue(forKey: localUri)
    }
}
