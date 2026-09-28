// Port of src/runtime/uploadEngine.ts — Photo/signature/document upload engine (ADR 004 two-phase
// attachments) driving the contracts blob state machine from real transport events:
//
//   register → local-only ─open session─→ uploading ─chunks─→ uploaded ─link commit─→ linked
//                  │                          │ session expired / hash mismatch
//                  └──────── already-present ─┴→ upload-expired (bytes kept, restart later)
//
// Invariants (cross-cutting #2):
//  - The local bytes are purgeable ONLY when `isBlobPurgeable` holds — Hub confirmed BOTH the
//    whole-file upload (sha256 verified) AND the attachment-link command commit.
//  - Progress is durable: `bytesAcked` persists after EVERY chunk, so an interrupted upload resumes
//    from the server's offset instead of restarting.
//  - A hash mismatch NEVER confirms the upload: the session is abandoned (`upload-expired`), the
//    local bytes stay, and a fresh session restarts from them.
//  - The link command goes through the durable sync outbox with its own idempotency key; a
//    rejected/needs-review link leaves the blob preserved on-device and visible for review.
import Foundation
import FieldContracts
import FieldDomain

/// Write-identity allocator seam (FieldData's `DeviceIdentity` wired to this shape in production;
/// fakes in tests).
public protocol WriteIdentity {
    var deviceInstanceId: String { get }
    func allocateLocalSeq() -> Int
    func generateUuid() -> String
}

// ---- Tus resumable-upload client seam ----
//
// ponytail: `adapters/sync/TusUploadClient.ts` (the concrete HTTP tus client) maps to the App
// target per PORTING.md's module table, not to FieldRuntime — it is out of this port's scope. The
// engine only ever depends on the client's `probe`/`uploadChunk` surface and three of its error
// types (mirroring the TS `Pick<TusUploadClient, 'probe' | 'uploadChunk'>` seam), so that surface
// is declared here as the seam a future adapter conforms to, instead of duplicating a whole client.

/// The server's durable view of a session: bytes held, and the whole-file hash once complete.
public struct TusProbeResult: Equatable, Sendable {
    public var offset: Int
    public var sha256: String?
    public init(offset: Int, sha256: String? = nil) {
        self.offset = offset
        self.sha256 = sha256
    }
}

public struct TusPatchResult: Equatable, Sendable {
    public var offset: Int
    /// Present on the final PATCH (server verified the whole file).
    public var sha256: String?
    public init(offset: Int, sha256: String? = nil) {
        self.offset = offset
        self.sha256 = sha256
    }
}

/// The upload session no longer exists on Hub (expired/garbage-collected). Restart locally.
public struct TusSessionGoneError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// The Hub holds bytes that hash to something DIFFERENT than the declared sha256. FATAL:
/// re-sending the same bytes can never fix it — the engine restarts the blob from the durable
/// local copy.
public struct TusHashMismatchError: Error, CustomStringConvertible {
    public let message: String
    public let serverSha256: String?
    public var description: String { message }
    public init(_ message: String, serverSha256: String? = nil) {
        self.message = message
        self.serverSha256 = serverSha256
    }
}

public protocol TusChunkTransport {
    /// The server's current durable offset for this session (and hash, once complete).
    func probe(_ uploadUrl: String) async throws -> TusProbeResult
    /// Upload one chunk at `offset`. Returns the server's new offset (and the whole-file hash on the
    /// final chunk).
    func uploadChunk(_ uploadUrl: String, _ offset: Int, _ chunk: Data) async throws -> TusPatchResult
}

/// Narrowed `SyncTransport` seam this engine actually drives (opening an upload session), mirroring
/// the TS `Pick<sync.SyncTransport, 'openUploadSession'>`.
public protocol UploadSessionOpening {
    func openUploadSession(_ request: UploadSessionRequest) async throws -> UploadSessionResponse
}

public struct RegisterBlobInput {
    public var blobId: String
    public var sha256: String
    public var byteLength: Int
    public var mimeType: String
    public var localUri: String
    public var attachmentId: String
    public var parentType: AttachBlobParentType
    public var parentId: String
    public var attachmentKind: AttachBlobKind
    /// opId of the parent's own outbox operation, when the link must commit after it.
    public var parentOpId: String?

    public init(
        blobId: String, sha256: String, byteLength: Int, mimeType: String, localUri: String,
        attachmentId: String, parentType: AttachBlobParentType, parentId: String,
        attachmentKind: AttachBlobKind, parentOpId: String? = nil
    ) {
        self.blobId = blobId
        self.sha256 = sha256
        self.byteLength = byteLength
        self.mimeType = mimeType
        self.localUri = localUri
        self.attachmentId = attachmentId
        self.parentType = parentType
        self.parentId = parentId
        self.attachmentKind = attachmentKind
        self.parentOpId = parentOpId
    }
}

public struct UploadSweepReport: Equatable, Sendable {
    /// Blobs whose upload completed (hash verified) this pass.
    public var uploaded = 0
    /// Blobs deduped server-side (content already present).
    public var dedupedAlreadyPresent = 0
    /// Attachment-link commands enqueued this pass.
    public var linksEnqueued = 0
    /// Blobs advanced to fully-linked this pass.
    public var linked = 0
    /// Blobs whose session died or hash mismatched — bytes kept, will restart.
    public var expired = 0
    /// Blobs left untouched on a transient failure — bytes and state kept, retry later.
    public var deferred = 0
    /// True when a 401/403 surfaced this pass — items deferred and due the moment a fresh token
    /// exists; a driver should PAUSE rather than hammer the Hub with a dead token.
    public var authRequired = false
}

public struct UploadEngineDeps {
    public var blobs: BlobUploadStore
    public var bytes: BlobBytesSource
    public var transport: UploadSessionOpening
    public var tus: TusChunkTransport
    /// Enqueue the attachment-link command into the durable sync outbox (`SyncEngine.enqueue`).
    /// A failed durable write must propagate; the blob must not record a phantom `linkOpId`.
    public var enqueueLink: (OperationEnvelope<AttachBlobCommand>) throws -> Void
    /// Outbox state of a previously-enqueued link op (`SyncOutboxStore.get(...).state`). Read
    /// failures are distinct from a missing row and must propagate.
    public var linkState: (String) throws -> OutboxItemState?
    /// Fired when a NEW blob is registered — lets a runtime driver kick an immediate upload pass.
    public var onRegister: (() -> Void)?
    public var identity: WriteIdentity
    public var chunkSizeBytes: Int?
    public var now: (() -> Date)?
    public var onError: ((String, Error) -> Void)?

    public init(
        blobs: BlobUploadStore, bytes: BlobBytesSource, transport: UploadSessionOpening,
        tus: TusChunkTransport, enqueueLink: @escaping (OperationEnvelope<AttachBlobCommand>) throws -> Void,
        linkState: @escaping (String) throws -> OutboxItemState?, onRegister: (() -> Void)? = nil,
        identity: WriteIdentity, chunkSizeBytes: Int? = nil, now: (() -> Date)? = nil,
        onError: ((String, Error) -> Void)? = nil
    ) {
        self.blobs = blobs
        self.bytes = bytes
        self.transport = transport
        self.tus = tus
        self.enqueueLink = enqueueLink
        self.linkState = linkState
        self.onRegister = onRegister
        self.identity = identity
        self.chunkSizeBytes = chunkSizeBytes
        self.now = now
        self.onError = onError
    }
}

/// Narrowed `UploadEngine` seam `UploadRunner` drives, mirroring the TS
/// `Pick<UploadEngine, 'processOnce' | 'purgeOnce'>`.
public protocol UploadProcessing {
    func processOnce() async throws -> UploadSweepReport
    func purgeOnce() async throws -> [String]
}

private let DEFAULT_CHUNK_SIZE = 256 * 1024

/// ponytail: `advanceBlob`/`isBlobPurgeable`/`assertLinkAllowed` (FieldContracts) operate on the
/// contracts' narrower `BlobRecord`; `BlobUploadRecord` (FieldDomain) is its domain superset. TS
/// gets a free structural upcast via object spread — Swift needs an explicit shim (same shape as
/// `SyncEngine`'s `DurableSyncOutboxItem` <-> `OutboxItem` conversion).
private extension BlobUploadRecord {
    var asBlobRecord: BlobRecord {
        BlobRecord(
            blobId: blobId, sha256: sha256, byteLength: byteLength, state: state, uploadConfirmed: uploadConfirmed,
            linkConfirmed: linkConfirmed)
    }

    func advancing(_ event: BlobEvent) throws -> BlobUploadRecord {
        let next = try advanceBlob(asBlobRecord, event)
        var updated = self
        updated.state = next.state
        updated.uploadConfirmed = next.uploadConfirmed
        updated.linkConfirmed = next.linkConfirmed
        return updated
    }
}

public final class UploadEngine: UploadProcessing {
    private let deps: UploadEngineDeps
    private let chunkSize: Int
    private let now: () -> Date

    public init(_ deps: UploadEngineDeps) {
        self.deps = deps
        self.chunkSize = deps.chunkSizeBytes ?? DEFAULT_CHUNK_SIZE
        self.now = deps.now ?? { Date() }
    }

    public func get(_ blobId: String) throws -> BlobUploadRecord? {
        try deps.blobs.get(blobId)
    }

    public func getByAttachmentId(_ attachmentId: String) throws -> BlobUploadRecord? {
        try deps.blobs.getByAttachmentId(attachmentId)
    }

    /// Record a captured blob durably. Idempotent on blobId AND attachmentId: re-registering the
    /// same capture returns the existing record; a different blob under an existing attachmentId
    /// throws (duplicate attachment identity must never silently fork).
    @discardableResult
    public func register(_ input: RegisterBlobInput) throws -> BlobUploadRecord {
        if let existingBlob = try deps.blobs.get(input.blobId) { return existingBlob }
        if let existingAttachment = try deps.blobs.getByAttachmentId(input.attachmentId) {
            throw UploadEngineError(
                "attachmentId \(input.attachmentId) is already bound to blob \(existingAttachment.blobId)")
        }
        let seq = deps.identity.allocateLocalSeq()
        let at = isoStamp(now())
        let record = BlobUploadRecord(
            blobId: input.blobId, sha256: input.sha256, byteLength: input.byteLength,
            state: .localOnly, uploadConfirmed: false, linkConfirmed: false, mimeType: input.mimeType,
            localUri: input.localUri, attachmentId: input.attachmentId, parentType: input.parentType,
            parentId: input.parentId, attachmentKind: input.attachmentKind,
            sessionIdempotencyKey: try buildIdempotencyKey(
                deps.identity.deviceInstanceId, seq, deps.identity.generateUuid()),
            parentOpId: input.parentOpId, bytesAcked: 0, createdAt: at, updatedAt: at)
        try deps.blobs.save(record)
        // Kick a runtime driver (if any) to upload the fresh blob promptly. The producer
        // (CaptureFlow) persists the bytes BEFORE register, so the kicked sweep finds them; even if
        // a future caller raced ahead, a missing-bytes read just defers and retries — work is never
        // lost.
        deps.onRegister?()
        return record
    }

    /// Drive every non-terminal blob one step forward. Per-blob transport failures defer without
    /// blocking healthy blobs. Outbox I/O failures propagate because they affect the durability
    /// boundary for every blob, not just one upload attempt.
    public func processOnce() async throws -> UploadSweepReport {
        var report = UploadSweepReport()
        for record in try deps.blobs.list() {
            do {
                try await processBlob(record, &report)
            } catch let error as UploadBlobStoreAccessError {
                deps.onError?(record.blobId, error.underlying)
                throw error.underlying
            } catch let error as UploadOutboxAccessError {
                deps.onError?(record.blobId, error.underlying)
                throw error.underlying
            } catch {
                // One bad blob must never kill the sweep for the healthy blobs behind it.
                if error is HubAuthError { report.authRequired = true }
                report.deferred += 1
                deps.onError?(record.blobId, error)
            }
        }
        return report
    }

    private func processBlob(_ record: BlobUploadRecord, _ report: inout UploadSweepReport) async throws {
        var current = record
        if current.state == .localOnly || current.state == .uploadExpired {
            guard let opened = try await openSession(current, &report) else { return }  // deferred
            current = opened
        }
        if current.state == .uploading {
            guard let advanced = try await uploadRemaining(current, &report) else { return }
            current = advanced
        }
        if current.state == .uploaded {
            current = try ensureLinkEnqueued(current, &report)
            try reconcileLink(current, &report)
        }
    }

    private func openSession(_ record: BlobUploadRecord, _ report: inout UploadSweepReport) async throws
        -> BlobUploadRecord?
    {
        let response: UploadSessionResponse
        do {
            response = try await deps.transport.openUploadSession(
                UploadSessionRequest(
                    blobId: record.blobId, sha256: record.sha256, byteLength: record.byteLength,
                    mimeType: record.mimeType, idempotencyKey: record.sessionIdempotencyKey))
        } catch {
            if error is HubAuthError { report.authRequired = true }
            report.deferred += 1
            deps.onError?(record.blobId, error)
            return nil
        }
        switch response {
        case .alreadyPresent:
            // Hub already holds these exact bytes (content-hash dedupe) — durably uploaded.
            var next = try record.advancing(.alreadyPresent)
            next.bytesAcked = record.byteLength
            next = stamp(next)
            try saveBlob(next)
            report.dedupedAlreadyPresent += 1
            return next
        case .newSession(let uploadSessionId, let uploadUrl):
            var next = try record.advancing(.uploadStarted)
            next.uploadSessionId = uploadSessionId
            next.uploadUrl = uploadUrl
            next.bytesAcked = 0
            next = stamp(next)
            try saveBlob(next)
            return next
        }
    }

    private func uploadRemaining(_ record: BlobUploadRecord, _ report: inout UploadSweepReport) async throws
        -> BlobUploadRecord?
    {
        guard let uploadUrl = record.uploadUrl else {
            // Session identity lost (corrupt row) — abandon the session, keep the bytes, restart.
            try expire(record, &report, "uploading row has no uploadUrl")
            return nil
        }
        var current = record
        var lastResult: TusPatchResult?
        do {
            // The server's offset is the truth on resume — local bookkeeping adjusts to it.
            let probed = try await deps.tus.probe(uploadUrl)
            let offset = try reconcileOffset(current.bytesAcked, probed.offset, current.byteLength)
            if let sha256 = probed.sha256 { lastResult = TusPatchResult(offset: offset, sha256: sha256) }
            current.bytesAcked = offset
            current = stamp(current)
            try saveBlob(current)

            while true {
                let plan = try planNextChunk(current.bytesAcked, current.byteLength, chunkSize)
                guard case .chunk(let planOffset, let length) = plan else { break }
                let chunk = try await deps.bytes.read(localUri: current.localUri, offset: planOffset, length: length)
                guard chunk.count == length else {
                    throw UploadEngineError(
                        "blob read at offset \(planOffset) returned \(chunk.count) bytes; expected \(length)")
                }
                let result = try await deps.tus.uploadChunk(uploadUrl, planOffset, chunk)
                let expectedOffset = planOffset + length
                guard result.offset == expectedOffset else {
                    throw UploadEngineError(
                        "PATCH at offset \(planOffset) acknowledged offset \(result.offset); expected \(expectedOffset)"
                    )
                }
                lastResult = result
                // Persist the server-acknowledged offset after EVERY chunk — durable resume point.
                current.bytesAcked = try reconcileOffset(current.bytesAcked, result.offset, current.byteLength)
                current = stamp(current)
                try saveBlob(current)
            }
        } catch let error as TusSessionGoneError {
            try expire(current, &report, String(describing: error))
            return nil
        } catch let error as TusHashMismatchError {
            // The Hub holds bytes that don't match our declared hash — re-sending can't fix it.
            // Restart the blob clean from the durable local copy (which was never purged).
            try expire(current, &report, String(describing: error))
            return nil
        } catch let error as UploadBlobStoreAccessError {
            throw error
        } catch {
            // Everything else (incl. an offset conflict) is transient: the next sweep re-probes
            // (HEAD) for the server's true offset and resumes from bytesAcked. Bytes are never lost.
            if error is HubAuthError { report.authRequired = true }
            report.deferred += 1
            deps.onError?(current.blobId, error)
            return nil
        }

        if !(try verifyUploadHash(current.sha256, lastResult?.sha256)) {
            // The server holds DIFFERENT bytes than we captured. Never confirm; restart clean.
            try expire(
                current, &report,
                "upload hash mismatch (local \(current.sha256), server \(lastResult?.sha256 ?? "none"))")
            return nil
        }
        let next = stamp(try current.advancing(.uploadConfirmed))
        try saveBlob(next)
        report.uploaded += 1
        return next
    }

    private func ensureLinkEnqueued(_ record: BlobUploadRecord, _ report: inout UploadSweepReport) throws
        -> BlobUploadRecord
    {
        if record.linkOpId != nil { return record }
        try assertLinkAllowed(record.asBlobRecord)  // cannot link bytes Hub does not yet have
        let opId = deps.identity.generateUuid()
        let seq = deps.identity.allocateLocalSeq()
        let idempotencyKey = try buildIdempotencyKey(deps.identity.deviceInstanceId, seq, opId)
        let envelope = OperationEnvelope<AttachBlobCommand>(
            opId: opId, kind: .command, type: "attachment.link", idempotencyKey: idempotencyKey,
            localSeq: seq, dependsOn: record.parentOpId.map { [$0] } ?? [],
            payload: AttachBlobCommand(
                attachmentId: record.attachmentId, blobId: record.blobId, parentType: record.parentType,
                parentId: record.parentId, attachmentKind: record.attachmentKind, idempotencyKey: idempotencyKey))
        do {
            try deps.enqueueLink(envelope)
        } catch {
            throw UploadOutboxAccessError(underlying: error)
        }
        var next = record
        next.linkOpId = opId
        next = stamp(next)
        try saveBlob(next)
        report.linksEnqueued += 1
        return next
    }

    private func reconcileLink(_ record: BlobUploadRecord, _ report: inout UploadSweepReport) throws {
        guard let linkOpId = record.linkOpId, record.state == .uploaded else { return }
        let linkState: OutboxItemState?
        do {
            linkState = try deps.linkState(linkOpId)
        } catch {
            throw UploadOutboxAccessError(underlying: error)
        }
        if linkState == .accepted {
            let next = stamp(try record.advancing(.linkConfirmed))
            try saveBlob(next)
            report.linked += 1
        }
        // rejected / needs-review / pending / in-flight: the blob stays 'uploaded' with its bytes —
        // preserved on-device, never purgeable, visible for review alongside the outbox row.
    }

    /// Abandon the current session: bytes and confirmations are kept; a fresh session restarts.
    private func expire(_ record: BlobUploadRecord, _ report: inout UploadSweepReport, _ reason: String) throws {
        var rest = record
        rest.uploadSessionId = nil
        rest.uploadUrl = nil
        var next = try rest.advancing(.uploadExpired)
        next.bytesAcked = 0
        // Mint a NEW session idempotency key — the abandoned session is dead, so the next
        // openSession must look like a genuinely new session. If the Hub keys upload dedupe on this
        // key (not on content sha256), reusing it could hand back "already-present" for bytes the
        // Hub already garbage-collected; a fresh key is correct under BOTH dedupe strategies.
        next.sessionIdempotencyKey = try buildIdempotencyKey(
            deps.identity.deviceInstanceId, deps.identity.allocateLocalSeq(), deps.identity.generateUuid())
        next = stamp(next)
        try saveBlob(next)
        report.expired += 1
        deps.onError?(record.blobId, UploadEngineError(reason))
    }

    /// Delete the device bytes of every fully-synced blob (`isBlobPurgeable` — upload AND link
    /// confirmed). The record itself stays as proof, stamped with `purgedAt`.
    @discardableResult
    public func purgeOnce() async throws -> [String] {
        var purged: [String] = []
        for record in try deps.blobs.listReadyToPurge() {
            try await deps.bytes.delete(localUri: record.localUri)
            var next = record
            next.purgedAt = isoStamp(now())
            try deps.blobs.save(stamp(next))
            purged.append(record.blobId)
        }
        return purged
    }

    /// Store failures are sweep-wide durability failures, unlike a per-blob transport error. Wrap
    /// them so `processOnce` never converts a failed metadata write into an ordinary deferred
    /// upload and then continues with an in-memory state the device did not persist.
    private func saveBlob(_ record: BlobUploadRecord) throws {
        do {
            try deps.blobs.save(record)
        } catch {
            throw UploadBlobStoreAccessError(underlying: error)
        }
    }

    private func stamp(_ record: BlobUploadRecord) -> BlobUploadRecord {
        var next = record
        next.updatedAt = isoStamp(now())
        return next
    }
}

private struct UploadEngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

private struct UploadOutboxAccessError: Error {
    let underlying: Error
}

private struct UploadBlobStoreAccessError: Error {
    let underlying: Error
}
