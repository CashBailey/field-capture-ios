import FieldContracts
import FieldDomain
// Port of __tests__/upload-engine.test.ts — upload engine behaviour (ADR 004 two-phase
// attachments): capture -> resumable upload -> link command -> purge, with the hard invariant
// that local bytes survive until Hub confirms BOTH the upload and the link commit. Hardware-free:
// volatile stores, scripted transport/tus fakes.
import XCTest

@testable import FieldRuntime

private let BYTES = Data((0..<10).map { UInt8($0) })
private let SHA = "aa11"

private func registerInput(
    blobId: String = "blob-1", parentOpId: String? = nil
) -> RegisterBlobInput {
    RegisterBlobInput(
        blobId: blobId, sha256: SHA, byteLength: BYTES.count, mimeType: "image/jpeg",
        localUri: "file:///photos/blob-1.jpg", attachmentId: "att-1", parentType: .fieldTicket,
        parentId: "ft-1", attachmentKind: .fieldTicketPhoto, parentOpId: parentOpId)
}

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

/// Scripted Hub upload server: in-memory session with configurable failures.
private final class FakeUploadServer: UploadSessionOpening, TusChunkTransport {
    var opened: [UploadSessionRequest] = []
    var alreadyPresent = false
    var openFailure: Error?
    /// Bytes durably received per session URL.
    var received: [String: Int] = [:]
    /// Hash the server reports on completion (default: echo the client's).
    var reportSha: String?
    /// Throw after N successful chunks (simulated interruption).
    var failAfterChunks: Int?
    /// Reject the FINAL PATCH with a fatal tus hash-mismatch 409 (Upload-Sha256 present).
    var hashMismatchOnFinal = false
    /// Return a deliberately contradictory PATCH offset while retaining the bytes server-side.
    var reportedPatchOffset: Int?
    private(set) var patchCalls = 0
    private var chunksSeen = 0
    var sessionGone = false

    func openUploadSession(_ request: UploadSessionRequest) async throws -> UploadSessionResponse {
        opened.append(request)
        if let openFailure { throw openFailure }
        if alreadyPresent { return .alreadyPresent(blobId: request.blobId) }
        let url = "http://hub.test/uploads/\(request.blobId)"
        if received[url] == nil { received[url] = 0 }
        return .newSession(uploadSessionId: "sess-\(request.blobId)", uploadUrl: url)
    }

    func probe(_ uploadUrl: String) async throws -> TusProbeResult {
        if sessionGone { throw TusSessionGoneError("gone") }
        return TusProbeResult(offset: received[uploadUrl] ?? 0)
    }

    func uploadChunk(_ uploadUrl: String, _ offset: Int, _ chunk: Data) async throws -> TusPatchResult {
        patchCalls += 1
        if sessionGone { throw TusSessionGoneError("gone") }
        if let failAfterChunks, chunksSeen >= failAfterChunks {
            struct ConnectionReset: Error {}
            throw ConnectionReset()
        }
        chunksSeen += 1
        let current = received[uploadUrl] ?? 0
        guard offset == current else {
            struct OffsetConflict: Error {}
            throw OffsetConflict()
        }
        let next = current + chunk.count
        if hashMismatchOnFinal && next == BYTES.count {
            throw TusHashMismatchError("server hash mismatch", serverSha256: "server-digest")
        }
        received[uploadUrl] = next
        return TusPatchResult(
            offset: reportedPatchOffset ?? next,
            sha256: next == BYTES.count ? (reportSha ?? SHA) : nil)
    }
}

private func makeEngine(
    chunkSizeBytes: Int = 4,
    storedBytes: Data = BYTES,
    onError: ((String, Error) -> Void)? = nil
) -> (
    engine: UploadEngine, blobs: VolatileBlobUploadStore, bytes: VolatileBlobBytesSource,
    server: FakeUploadServer, enqueued: Box<OperationEnvelope<AttachBlobCommand>>, linkStates: LinkStates
) {
    let blobs = VolatileBlobUploadStore()
    let bytes = VolatileBlobBytesSource()
    bytes.put("file:///photos/blob-1.jpg", storedBytes)
    let server = FakeUploadServer()
    let enqueued = Box<OperationEnvelope<AttachBlobCommand>>()
    let linkStates = LinkStates()
    var seq = 0
    var uuid = 0
    let engine = UploadEngine(
        UploadEngineDeps(
            blobs: blobs, bytes: bytes, transport: server, tus: server,
            enqueueLink: { envelope in
                if let failure = linkStates.enqueueFailure { throw failure }
                enqueued.items.append(envelope)
            },
            linkState: { opId in
                if let failure = linkStates.readFailure { throw failure }
                return linkStates.states[opId]
            },
            identity: FakeWriteIdentity(
                deviceInstanceId: "devA",
                allocateLocalSeqImpl: {
                    defer { seq += 1 }
                    return seq
                },
                generateUuidImpl: {
                    defer { uuid += 1 }
                    return "uuid-\(uuid)"
                }),
            chunkSizeBytes: chunkSizeBytes, now: { TEST_NOW_2026_06_10_12_00_00Z },
            onError: onError))
    return (engine, blobs, bytes, server, enqueued, linkStates)
}

private final class LinkStates {
    var states: [String: OutboxItemState] = [:]
    var enqueueFailure: LinkOutboxFailure?
    var readFailure: LinkOutboxFailure?
}

private enum LinkOutboxFailure: Error, Equatable {
    case enqueue
    case read
}

private enum BlobStoreOperation: Equatable {
    case save
    case get
    case getByAttachmentId
    case list
    case listByState
    case listReadyToPurge
}

private enum InjectedBlobStoreFailure: Error, Equatable {
    case failed(BlobStoreOperation)
}

private final class FailingBlobUploadStore: BlobUploadStore {
    let durability: StoreDurability = .volatileMemory
    let backing = VolatileBlobUploadStore()
    var failure: BlobStoreOperation?

    private func check(_ operation: BlobStoreOperation) throws {
        if failure == operation { throw InjectedBlobStoreFailure.failed(operation) }
    }

    func save(_ record: BlobUploadRecord) throws {
        try check(.save)
        backing.save(record)
    }

    func get(_ blobId: String) throws -> BlobUploadRecord? {
        try check(.get)
        return backing.get(blobId)
    }

    func getByAttachmentId(_ attachmentId: String) throws -> BlobUploadRecord? {
        try check(.getByAttachmentId)
        return backing.getByAttachmentId(attachmentId)
    }

    func list() throws -> [BlobUploadRecord] {
        try check(.list)
        return backing.list()
    }

    func listByState(_ state: BlobLifecycleState) throws -> [BlobUploadRecord] {
        try check(.listByState)
        return backing.listByState(state)
    }

    func listReadyToPurge() throws -> [BlobUploadRecord] {
        try check(.listReadyToPurge)
        return backing.listReadyToPurge()
    }
}

private func makeEngineWithStore(
    _ store: BlobUploadStore,
    bytes: VolatileBlobBytesSource = VolatileBlobBytesSource(),
    server: FakeUploadServer = FakeUploadServer()
) -> UploadEngine {
    var seq = 0
    var uuid = 0
    return UploadEngine(
        UploadEngineDeps(
            blobs: store,
            bytes: bytes,
            transport: server,
            tus: server,
            enqueueLink: { _ in },
            linkState: { _ in nil },
            identity: FakeWriteIdentity(
                deviceInstanceId: "devA",
                allocateLocalSeqImpl: {
                    defer { seq += 1 }
                    return seq
                },
                generateUuidImpl: {
                    defer { uuid += 1 }
                    return "failure-uuid-\(uuid)"
                }),
            chunkSizeBytes: 4,
            now: { TEST_NOW_2026_06_10_12_00_00Z }))
}

final class UploadEngineTests: XCTestCase {
    // MARK: register

    func testStoresADurableLocalOnlyRecordWithSha256AndParentIdentity() throws {
        let (engine, blobs, _, _, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        let record = blobs.get("blob-1")
        XCTAssertEqual(record?.state, .localOnly)
        XCTAssertEqual(record?.sha256, SHA)
        XCTAssertEqual(record?.parentType, .fieldTicket)
        XCTAssertEqual(record?.parentId, "ft-1")
        XCTAssertEqual(record?.attachmentKind, .fieldTicketPhoto)
        XCTAssertEqual(record?.uploadConfirmed, false)
        XCTAssertEqual(record?.linkConfirmed, false)
    }

    func testIsIdempotentOnBlobIdADuplicateAttachmentIdOnADifferentBlobThrows() throws {
        let (engine, _, _, _, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        XCTAssertEqual(try engine.register(registerInput()).blobId, "blob-1")
        XCTAssertThrowsError(try engine.register(registerInput(blobId: "blob-2")))
    }

    func testRegisterPropagatesBlobStoreReadAndWriteFailures() throws {
        let store = FailingBlobUploadStore()
        let engine = makeEngineWithStore(store)

        store.failure = .get
        XCTAssertThrowsError(try engine.register(registerInput())) { error in
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.get))
        }

        store.failure = .getByAttachmentId
        XCTAssertThrowsError(try engine.register(registerInput())) { error in
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.getByAttachmentId))
        }

        store.failure = .save
        XCTAssertThrowsError(try engine.register(registerInput())) { error in
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.save))
        }
    }

    // MARK: upload happy path + duplicate upload

    func testOpensASessionChunksTheBytesVerifiesTheHashAndEnqueuesTheLink() async throws {
        let (engine, blobs, _, server, enqueued, _) = makeEngine()
        _ = try engine.register(registerInput(parentOpId: "op-parent"))

        let report = try await engine.processOnce()

        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(report.linksEnqueued, 1)
        XCTAssertEqual(server.received["http://hub.test/uploads/blob-1"], 10)
        let record = blobs.get("blob-1")
        XCTAssertEqual(record?.state, .uploaded)
        XCTAssertEqual(record?.uploadConfirmed, true)
        XCTAssertEqual(record?.bytesAcked, 10)
        XCTAssertEqual(enqueued.items.count, 1)
        let link = enqueued.items[0]
        XCTAssertEqual(link.type, "attachment.link")
        XCTAssertEqual(link.kind, .command)
        XCTAssertEqual(link.dependsOn, ["op-parent"])
        XCTAssertEqual(link.payload.blobId, "blob-1")
        XCTAssertEqual(link.payload.attachmentId, "att-1")
        XCTAssertEqual(link.payload.parentId, "ft-1")
        XCTAssertNoThrow(try assertEnvelopeConsistent(link))
    }

    func testDuplicateUploadAContentHashDedupeHitConfirmsWithoutSendingAByte() async throws {
        let (engine, blobs, _, server, _, _) = makeEngine()
        server.alreadyPresent = true
        _ = try engine.register(registerInput())

        let report = try await engine.processOnce()

        XCTAssertEqual(report.dedupedAlreadyPresent, 1)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploaded)
        XCTAssertEqual(blobs.get("blob-1")?.uploadConfirmed, true)
        XCTAssertEqual(server.received.count, 0)
    }

    func testReRegisteringAndReprocessingNeverDoubleEnqueuesTheLink() async throws {
        let (engine, _, _, _, enqueued, _) = makeEngine()
        _ = try engine.register(registerInput())
        _ = try await engine.processOnce()
        _ = try await engine.processOnce()
        XCTAssertEqual(enqueued.items.count, 1)
    }

    func testProcessSweepPropagatesBlobStoreReadsAndWritesInsteadOfReportingNetworkDeferral()
        async throws
    {
        let store = FailingBlobUploadStore()
        let bytes = VolatileBlobBytesSource()
        bytes.put("file:///photos/blob-1.jpg", BYTES)
        let server = FakeUploadServer()
        let engine = makeEngineWithStore(store, bytes: bytes, server: server)
        _ = try engine.register(registerInput())

        store.failure = .list
        do {
            _ = try await engine.processOnce()
            XCTFail("expected blob-list failure")
        } catch {
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.list))
        }

        var uploading = try XCTUnwrap(store.backing.get("blob-1"))
        uploading.state = .uploading
        uploading.uploadSessionId = "sess-blob-1"
        uploading.uploadUrl = "http://hub.test/uploads/blob-1"
        store.backing.save(uploading)
        server.received["http://hub.test/uploads/blob-1"] = 0
        store.failure = .save
        do {
            _ = try await engine.processOnce()
            XCTFail("expected blob-save failure")
        } catch {
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.save))
        }
    }

    // MARK: interruption and resume

    func testAnInterruptedUploadKeepsItsDurableProgressAndResumesFromTheServerOffset() async throws {
        let (engine, blobs, _, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        server.failAfterChunks = 1

        let first = try await engine.processOnce()
        XCTAssertEqual(first.deferred, 1)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploading)
        XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, 4)

        server.failAfterChunks = nil
        let second = try await engine.processOnce()
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(server.received["http://hub.test/uploads/blob-1"], 10)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploaded)
        XCTAssertEqual(blobs.get("blob-1")?.uploadConfirmed, true)
    }

    func testAShortBlobReadDefersWithoutSendingAPartialChunkAndRetriesFromDurableBytes() async throws {
        let errors = Box<String>()
        let (engine, blobs, bytes, server, _, _) = makeEngine(
            storedBytes: Data(BYTES.prefix(2)),
            onError: { _, error in errors.items.append(String(describing: error)) })
        _ = try engine.register(registerInput())

        let first = try await engine.processOnce()

        XCTAssertEqual(first.deferred, 1)
        XCTAssertEqual(server.patchCalls, 0)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploading)
        XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, 0)
        XCTAssertTrue(bytes.has("file:///photos/blob-1.jpg"))
        XCTAssertTrue(errors.items.last?.contains("returned 2 bytes; expected 4") == true)

        bytes.put("file:///photos/blob-1.jpg", BYTES)
        let retry = try await engine.processOnce()
        XCTAssertEqual(retry.uploaded, 1)
        XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, BYTES.count)
    }

    func testAnUnchangedOrInvalidPatchOffsetDefersWithoutLoopingAndReconcilesOnRetry() async throws {
        for reportedOffset in [0, BYTES.count + 1] {
            let errors = Box<String>()
            let (engine, blobs, bytes, server, _, _) = makeEngine(
                onError: { _, error in errors.items.append(String(describing: error)) })
            server.reportedPatchOffset = reportedOffset
            _ = try engine.register(registerInput())

            let first = try await engine.processOnce()

            XCTAssertEqual(first.deferred, 1, "reported offset: \(reportedOffset)")
            XCTAssertEqual(server.patchCalls, 1, "reported offset: \(reportedOffset)")
            XCTAssertEqual(blobs.get("blob-1")?.state, .uploading)
            XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, 0)
            XCTAssertTrue(bytes.has("file:///photos/blob-1.jpg"))
            XCTAssertTrue(
                errors.items.last?.contains("acknowledged offset \(reportedOffset); expected 4") == true)

            server.reportedPatchOffset = nil
            let retry = try await engine.processOnce()
            XCTAssertEqual(retry.uploaded, 1, "reported offset: \(reportedOffset)")
            XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, BYTES.count)
        }
    }

    func testResumeAdoptsTheServerOffsetWhenLocalBookkeepingIsBehind() async throws {
        let (engine, blobs, _, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        server.failAfterChunks = 2
        _ = try await engine.processOnce()  // 8 bytes durable on server
        var record = blobs.get("blob-1")!
        record.bytesAcked = 4
        blobs.save(record)

        server.failAfterChunks = nil
        _ = try await engine.processOnce()

        XCTAssertEqual(server.received["http://hub.test/uploads/blob-1"], 10)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploaded)
    }

    func testADeadSessionExpiresTheBlobBytesKeptRestartFromScratchWorks() async throws {
        let (engine, blobs, bytes, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        server.failAfterChunks = 1
        _ = try await engine.processOnce()
        server.sessionGone = true

        let report = try await engine.processOnce()
        XCTAssertEqual(report.expired, 1)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploadExpired)
        XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, 0)
        XCTAssertTrue(bytes.has("file:///photos/blob-1.jpg"))  // never purged

        server.sessionGone = false
        server.failAfterChunks = nil
        server.received.removeAll()
        let retry = try await engine.processOnce()
        XCTAssertEqual(retry.uploaded, 1)
    }

    func testExpiringASessionRotatesTheSessionIdempotencyKey() async throws {
        let (engine, blobs, _, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        let before = blobs.get("blob-1")!.sessionIdempotencyKey
        server.failAfterChunks = 1
        _ = try await engine.processOnce()
        server.sessionGone = true

        _ = try await engine.processOnce()  // session-gone -> expire
        let after = blobs.get("blob-1")!.sessionIdempotencyKey
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploadExpired)
        XCTAssertNotEqual(after, before)  // a fresh session, not the dead one's key
        XCTAssertFalse(after.isEmpty)
    }

    func testATransientOpenSessionFailureDefersTheBlobStaysLocalOnlyAndRetryable() async throws {
        let (engine, blobs, _, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        struct HubUnreachable: Error {}
        server.openFailure = HubUnreachable()

        let report = try await engine.processOnce()
        XCTAssertEqual(report.deferred, 1)
        XCTAssertEqual(blobs.get("blob-1")?.state, .localOnly)

        server.openFailure = nil
        let retry = try await engine.processOnce()
        XCTAssertEqual(retry.uploaded, 1)
    }

    // MARK: hash verification

    func testAServerHashMismatchNeverConfirmsSessionAbandonedBytesKept() async throws {
        let (engine, blobs, bytes, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        server.reportSha = "bb22"  // server holds different bytes than we captured

        let report = try await engine.processOnce()

        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(report.expired, 1)
        let record = blobs.get("blob-1")
        XCTAssertEqual(record?.state, .uploadExpired)
        XCTAssertEqual(record?.uploadConfirmed, false)
        XCTAssertTrue(bytes.has("file:///photos/blob-1.jpg"))
    }

    func testAFatalPatchHashMismatch409ExpiresRestartCleanBytesKept() async throws {
        let (engine, blobs, bytes, server, _, _) = makeEngine()
        _ = try engine.register(registerInput())
        server.hashMismatchOnFinal = true  // Hub rejects the final chunk: bytes != declared hash

        let report = try await engine.processOnce()

        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(report.deferred, 0)  // NOT a transient retry
        XCTAssertEqual(report.expired, 1)
        XCTAssertEqual(blobs.get("blob-1")?.state, .uploadExpired)
        XCTAssertEqual(blobs.get("blob-1")?.bytesAcked, 0)
        XCTAssertTrue(bytes.has("file:///photos/blob-1.jpg"))
    }

    // MARK: link commit and purge gating

    func testLinkEnqueueFailurePropagatesWithoutRecordingAPhantomLinkAndRetrySucceeds() async throws {
        let f = makeEngine()
        f.linkStates.enqueueFailure = .enqueue
        _ = try f.engine.register(registerInput())

        do {
            _ = try await f.engine.processOnce()
            XCTFail("expected outbox enqueue failure")
        } catch {
            XCTAssertEqual(error as? LinkOutboxFailure, .enqueue)
        }
        XCTAssertTrue(f.enqueued.items.isEmpty)
        XCTAssertEqual(f.blobs.get("blob-1")?.state, .uploaded)
        XCTAssertNil(f.blobs.get("blob-1")?.linkOpId)

        f.linkStates.enqueueFailure = nil
        let retry = try await f.engine.processOnce()
        XCTAssertEqual(retry.linksEnqueued, 1)
        XCTAssertEqual(f.enqueued.items.count, 1)
        XCTAssertNotNil(f.blobs.get("blob-1")?.linkOpId)
    }

    func testLinkStateReadFailurePropagatesAsIoErrorAndNeverDuplicatesTheLink() async throws {
        let f = makeEngine()
        f.linkStates.readFailure = .read
        _ = try f.engine.register(registerInput())

        do {
            _ = try await f.engine.processOnce()
            XCTFail("expected outbox read failure")
        } catch {
            XCTAssertEqual(error as? LinkOutboxFailure, .read)
        }
        let linkOpId = try XCTUnwrap(f.blobs.get("blob-1")?.linkOpId)
        XCTAssertEqual(f.enqueued.items.count, 1)
        XCTAssertEqual(f.blobs.get("blob-1")?.state, .uploaded)

        f.linkStates.readFailure = nil
        f.linkStates.states[linkOpId] = .accepted
        let retry = try await f.engine.processOnce()
        XCTAssertEqual(retry.linked, 1)
        XCTAssertEqual(f.enqueued.items.count, 1)
        XCTAssertEqual(f.blobs.get("blob-1")?.state, .linked)
    }

    private func uploadedWithLink() async throws -> (
        engine: UploadEngine, blobs: VolatileBlobUploadStore, bytes: VolatileBlobBytesSource, server: FakeUploadServer,
        enqueued: Box<OperationEnvelope<AttachBlobCommand>>, linkStates: LinkStates, linkOpId: String
    ) {
        let fixture = makeEngine()
        _ = try fixture.engine.register(registerInput())
        _ = try await fixture.engine.processOnce()
        let linkOpId = fixture.blobs.get("blob-1")!.linkOpId!
        return (
            fixture.engine, fixture.blobs, fixture.bytes, fixture.server, fixture.enqueued, fixture.linkStates, linkOpId
        )
    }

    func testTheBlobIsNotPurgeableAfterUploadAloneLinkCommitIsRequired() async throws {
        let f = try await uploadedWithLink()
        XCTAssertFalse(
            isBlobPurgeable(
                BlobRecord(
                    blobId: f.blobs.get("blob-1")!.blobId, sha256: f.blobs.get("blob-1")!.sha256,
                    byteLength: f.blobs.get("blob-1")!.byteLength, state: f.blobs.get("blob-1")!.state,
                    uploadConfirmed: f.blobs.get("blob-1")!.uploadConfirmed,
                    linkConfirmed: f.blobs.get("blob-1")!.linkConfirmed)))
        _ = try await f.engine.purgeOnce()
        XCTAssertTrue(f.bytes.has("file:///photos/blob-1.jpg"))
    }

    func testAnAcceptedLinkAdvancesToLinkedPurgeThenDeletesTheBytesOnce() async throws {
        let f = try await uploadedWithLink()
        f.linkStates.states[f.linkOpId] = .accepted

        let report = try await f.engine.processOnce()
        XCTAssertEqual(report.linked, 1)
        let record = f.blobs.get("blob-1")!
        XCTAssertEqual(record.state, .linked)
        XCTAssertTrue(record.uploadConfirmed)
        XCTAssertTrue(record.linkConfirmed)

        let purged = try await f.engine.purgeOnce()
        XCTAssertEqual(purged, ["blob-1"])
        XCTAssertFalse(f.bytes.has("file:///photos/blob-1.jpg"))
        XCTAssertNotNil(f.blobs.get("blob-1")?.purgedAt)
        let secondPurge = try await f.engine.purgeOnce()
        XCTAssertEqual(secondPurge, [])
    }

    func testPurgeRecoversWhenBytesWereDeletedBeforeTheRecordWasStamped() async throws {
        let f = try await uploadedWithLink()
        f.linkStates.states[f.linkOpId] = .accepted
        _ = try await f.engine.processOnce()

        try await f.bytes.delete(localUri: "file:///photos/blob-1.jpg")
        XCTAssertNil(f.blobs.get("blob-1")?.purgedAt)

        let purged = try await f.engine.purgeOnce()
        XCTAssertEqual(purged, ["blob-1"])
        XCTAssertNotNil(f.blobs.get("blob-1")?.purgedAt)
    }

    func testPurgePropagatesMetadataFailuresAndRecoversAfterTheStampWriteFails() async throws {
        let store = FailingBlobUploadStore()
        let bytes = VolatileBlobBytesSource()
        bytes.put("file:///photos/blob-1.jpg", BYTES)
        var record = BlobUploadRecord(
            blobId: "blob-1",
            sha256: SHA,
            byteLength: BYTES.count,
            state: .linked,
            uploadConfirmed: true,
            linkConfirmed: true,
            mimeType: "image/jpeg",
            localUri: "file:///photos/blob-1.jpg",
            attachmentId: "att-1",
            parentType: .fieldTicket,
            parentId: "ft-1",
            attachmentKind: .fieldTicketPhoto,
            sessionIdempotencyKey: "gtr:devA:1:blob-1",
            bytesAcked: BYTES.count,
            createdAt: "2026-06-10T10:00:00.000Z",
            updatedAt: "2026-06-10T10:00:00.000Z")
        store.backing.save(record)
        let engine = makeEngineWithStore(store, bytes: bytes)

        store.failure = .listReadyToPurge
        do {
            _ = try await engine.purgeOnce()
            XCTFail("expected purge-query failure")
        } catch {
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.listReadyToPurge))
        }
        XCTAssertTrue(bytes.has(record.localUri))

        store.failure = .save
        do {
            _ = try await engine.purgeOnce()
            XCTFail("expected purge-stamp failure")
        } catch {
            XCTAssertEqual(error as? InjectedBlobStoreFailure, .failed(.save))
        }
        XCTAssertFalse(bytes.has(record.localUri))
        XCTAssertNil(store.backing.get(record.blobId)?.purgedAt)

        store.failure = nil
        let purged = try await engine.purgeOnce()
        XCTAssertEqual(purged, [record.blobId])
        record = try XCTUnwrap(store.backing.get(record.blobId))
        XCTAssertNotNil(record.purgedAt)
    }

    func testANeedsReviewLinkPreservesTheBlobOnDeviceNeverPurgeable() async throws {
        let f = try await uploadedWithLink()
        f.linkStates.states[f.linkOpId] = .needsReview
        _ = try await f.engine.processOnce()
        _ = try await f.engine.purgeOnce()
        XCTAssertEqual(f.blobs.get("blob-1")?.state, .uploaded)
        XCTAssertEqual(f.blobs.get("blob-1")?.linkConfirmed, false)
        XCTAssertTrue(f.bytes.has("file:///photos/blob-1.jpg"))
    }

    func testARejectedLinkLikewisePreservesTheBlobForReview() async throws {
        let f = try await uploadedWithLink()
        f.linkStates.states[f.linkOpId] = .rejected
        _ = try await f.engine.processOnce()
        _ = try await f.engine.purgeOnce()
        XCTAssertEqual(f.blobs.get("blob-1")?.state, .uploaded)
        XCTAssertTrue(f.bytes.has("file:///photos/blob-1.jpg"))
    }
}
