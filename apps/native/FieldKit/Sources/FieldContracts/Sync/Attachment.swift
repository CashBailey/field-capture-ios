// Port of sync/attachment.ts — Two-phase attachment lifecycle (ADR 004). Photos/documents are
// immutable blobs uploaded with a tus-style resumable session, then linked to a parent record by a
// SEPARATE append-only command. The hard invariant (cross-cutting #2, "never silently lose work"):
// the on-device copy is purgeable ONLY after Hub confirms BOTH the upload AND the attachment-link
// commit. Anything less stays on the phone.
//
// Pure state machine — no I/O. A later engine slice drives it from real tus/HTTP events.

public enum BlobLifecycleState: String, Equatable, Sendable, Codable {
    case localOnly = "local-only"  // captured on device, nothing uploaded yet
    case uploading  // tus session open, bytes transferring
    case uploaded  // Hub verified whole-file sha256 + size; durable on Hub
    case linked  // AttachBlob command committed — fully synced, purgeable
    case uploadExpired = "upload-expired"  // tus session abandoned/expired; restart from a local copy
}

public struct BlobRecord: Equatable, Sendable {
    public var blobId: String
    public var sha256: String
    public var byteLength: Int
    public var state: BlobLifecycleState
    /// Set once Hub confirms whole-file receipt.
    public var uploadConfirmed: Bool
    /// Set once the append-only attachment-link command commits.
    public var linkConfirmed: Bool

    public init(
        blobId: String, sha256: String, byteLength: Int, state: BlobLifecycleState, uploadConfirmed: Bool,
        linkConfirmed: Bool
    ) {
        self.blobId = blobId
        self.sha256 = sha256
        self.byteLength = byteLength
        self.state = state
        self.uploadConfirmed = uploadConfirmed
        self.linkConfirmed = linkConfirmed
    }
}

public enum BlobEvent: String, Equatable, Sendable, Codable {
    case uploadStarted = "upload-started"
    case uploadConfirmed = "upload-confirmed"
    case linkConfirmed = "link-confirmed"
    case uploadExpired = "upload-expired"
    case alreadyPresent = "already-present"  // dedupe hit: Hub already holds this (sha256, byteLength) blob
}

public struct AttachmentError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/**
 * THE invariant. A blob may be purged from the device only in the fully-synced terminal state with
 * both confirmations. The triple check is deliberate redundancy: state and the two flags must agree.
 */
public func isBlobPurgeable(_ b: BlobRecord) -> Bool {
    b.state == .linked && b.uploadConfirmed && b.linkConfirmed
}

private let BLOB_TRANSITIONS: [BlobLifecycleState: [BlobEvent: BlobLifecycleState]] = [
    .localOnly: [.uploadStarted: .uploading, .alreadyPresent: .uploaded],
    .uploading: [.uploadConfirmed: .uploaded, .uploadExpired: .uploadExpired, .alreadyPresent: .uploaded],
    .uploaded: [.linkConfirmed: .linked],
    .uploadExpired: [.uploadStarted: .uploading, .alreadyPresent: .uploaded],
    .linked: [:],  // terminal
]

/**
 * Advance a blob by one lifecycle event, returning a new record (input never mutated). Throws on an
 * illegal transition. Sets `uploadConfirmed`/`linkConfirmed` as the corresponding confirmations land
 * — these flags are monotonic (once true, never cleared), so an expired re-upload of an
 * already-confirmed blob keeps its confirmation.
 */
public func advanceBlob(_ record: BlobRecord, _ event: BlobEvent) throws -> BlobRecord {
    guard let next = BLOB_TRANSITIONS[record.state]?[event] else {
        throw AttachmentError("illegal blob transition: \(record.state.rawValue) --\(event.rawValue)-->")
    }
    var updated = record
    updated.state = next
    updated.uploadConfirmed = record.uploadConfirmed || event == .uploadConfirmed || event == .alreadyPresent
    updated.linkConfirmed = record.linkConfirmed || event == .linkConfirmed
    return updated
}

/**
 * Guard the second phase: an attachment link may only be submitted once the blob is durably
 * uploaded (you cannot link bytes Hub does not yet have). Throws otherwise.
 */
public func assertLinkAllowed(_ record: BlobRecord) throws {
    guard record.uploadConfirmed && (record.state == .uploaded || record.state == .linked) else {
        throw AttachmentError(
            "cannot link blob \(record.blobId) before its upload is confirmed (state=\(record.state.rawValue))"
        )
    }
}

/// The blobs that are safe to purge from device storage right now.
public func purgeableBlobs(_ records: [BlobRecord]) -> [BlobRecord] {
    records.filter(isBlobPurgeable)
}
