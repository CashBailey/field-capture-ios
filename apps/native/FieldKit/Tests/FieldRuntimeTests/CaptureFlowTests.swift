import FieldContracts
import FieldDomain
// Port of __tests__/capture-flow.test.ts — photo/signature capture flow: SHA-256 anchored at
// capture, bytes preserved locally until upload + link both commit, parent linking correct for
// every attachment kind, duplicate attachment ids refused, and the clock gate locks capture.
import XCTest

@testable import FieldRuntime

private let UNLOCKED = FieldWorkGate.unlocked(
    clockedInSince: "2026-06-10T06:00:00Z", source: "timeclock", employeeId: nil)
private let PHOTO = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

private final class OpeningStub: UploadSessionOpening {
    var remainingOpenFailures: Int
    init(remainingOpenFailures: Int) { self.remainingOpenFailures = remainingOpenFailures }
    func openUploadSession(_ request: UploadSessionRequest) async throws -> UploadSessionResponse {
        if remainingOpenFailures > 0 {
            remainingOpenFailures -= 1
            struct HubUnreachable: Error {}
            throw HubUnreachable()
        }
        return .alreadyPresent(blobId: request.blobId)  // dedupe: upload confirmed
    }
}

private struct NoopTus: TusChunkTransport {
    func probe(_ uploadUrl: String) async throws -> TusProbeResult { TusProbeResult(offset: 0) }
    func uploadChunk(_ uploadUrl: String, _ offset: Int, _ chunk: Data) async throws -> TusPatchResult {
        TusPatchResult(offset: 0)
    }
}

private final class LinkStates {
    var states: [String: OutboxItemState] = [:]
}

private func makeFlow(gate: FieldWorkGate = UNLOCKED, failSessionOpens: Int = 0) -> (
    flow: CaptureFlow, uploads: UploadEngine, blobs: VolatileBlobUploadStore, bytes: VolatileBlobBytesSource,
    enqueued: Box<OperationEnvelope<AttachBlobCommand>>, linkStates: LinkStates
) {
    let blobs = VolatileBlobUploadStore()
    let bytes = VolatileBlobBytesSource()
    let enqueued = Box<OperationEnvelope<AttachBlobCommand>>()
    let linkStates = LinkStates()
    var seq = 0
    var uuid = 0
    let uploads = UploadEngine(
        UploadEngineDeps(
            blobs: blobs, bytes: bytes, transport: OpeningStub(remainingOpenFailures: failSessionOpens), tus: NoopTus(),
            enqueueLink: { enqueued.items.append($0) }, linkState: { linkStates.states[$0] },
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
            now: { TEST_NOW_2026_06_10_12_00_00Z }))
    let flow = CaptureFlow(
        CaptureFlowDeps(
            uploads: uploads,
            persistBytes: { blobId, data in
                let uri = "file:///captures/\(blobId)"
                bytes.put(uri, data)
                return uri
            },
            gateState: { gate },
            identity: CaptureIdentity(generateUuid: {
                defer { uuid += 1 }
                return "cap-\(uuid)"
            })))
    return (flow, uploads, blobs, bytes, enqueued, linkStates)
}

final class CaptureFlowTests: XCTestCase {
    func testAnchorsTheSha256AtCaptureAndStoresTheBlobDurablyLocallyPreserved() async throws {
        let (flow, _, blobs, bytes, _, _) = makeFlow()
        let result = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .camera, attachmentKind: .fieldTicketPhoto,
                parentType: .fieldTicket, parentId: "ft-1"))

        guard case .captured(let record, let sha256) = result else { return XCTFail("expected captured") }
        XCTAssertEqual(sha256, sha256Hex(PHOTO))  // real digest, not a stub
        let saved = blobs.get(record.blobId)
        XCTAssertEqual(saved?.state, .localOnly)
        XCTAssertEqual(saved?.sha256, sha256)
        XCTAssertEqual(saved?.byteLength, 10)
        XCTAssertEqual(saved?.parentType, .fieldTicket)
        XCTAssertEqual(saved?.parentId, "ft-1")
        XCTAssertEqual(saved?.attachmentKind, .fieldTicketPhoto)
        XCTAssertTrue(bytes.has(saved!.localUri))
    }

    func testLockedClockGateRefusesCaptureNoBytesPersistedNothingRegistered() async throws {
        let (flow, _, blobs, _, _, _) = makeFlow(gate: .locked(reason: .hubUnreachable, detail: nil))
        let result = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .camera, attachmentKind: .receiptPhoto,
                parentType: .fieldTicket, parentId: "ft-1"))
        guard case .locked(let reason) = result else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, "hub-unreachable")
        XCTAssertEqual(blobs.list().count, 0)
    }

    func testParentLinkCorrectnessEachKindLinksToItsOwnParentAndTheLinkOpCarriesIt() async throws {
        let (flow, uploads, _, _, enqueued, _) = makeFlow()
        _ = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .camera, attachmentKind: .disposalPhoto,
                parentType: .sr, parentId: "sr-9", parentOpId: "op-parent"))
        _ = try await flow.captureSignature(bytes: PHOTO, parentType: .jhajsa, parentId: "jha-1")

        _ = try await uploads.processOnce()  // dedupe-confirms uploads, enqueues links
        XCTAssertEqual(enqueued.items.count, 2)
        let disposal = enqueued.items.first { $0.payload.attachmentKind == .disposalPhoto }
        let signature = enqueued.items.first { $0.payload.attachmentKind == .signature }
        XCTAssertEqual(disposal?.payload.parentType, .sr)
        XCTAssertEqual(disposal?.payload.parentId, "sr-9")
        XCTAssertEqual(disposal?.dependsOn, ["op-parent"])  // link waits for its parent's commit
        XCTAssertEqual(signature?.payload.parentType, .jhajsa)
        XCTAssertEqual(signature?.payload.parentId, "jha-1")
        XCTAssertNotEqual(signature?.payload.idempotencyKey, disposal?.payload.idempotencyKey)
    }

    func testDuplicateAttachmentIdsSameBlobIsIdempotentADifferentBlobRefuses() async throws {
        let (flow, _, _, bytes, _, _) = makeFlow()
        let first = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .importSource, attachmentKind: .receiptPhoto,
                parentType: .fieldTicket, parentId: "ft-1", blobId: "blob-1", attachmentId: "att-1"))
        guard case .captured = first else { return XCTFail("expected captured") }

        // Same blobId again -> same record, no fork.
        let replay = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .importSource, attachmentKind: .receiptPhoto,
                parentType: .fieldTicket, parentId: "ft-1", blobId: "blob-1", attachmentId: "att-1"))
        guard case .captured(let record, _) = replay else { return XCTFail("expected captured") }
        XCTAssertEqual(record.blobId, "blob-1")

        // Same attachmentId bound to DIFFERENT bytes -> loud refusal.
        do {
            _ = try await flow.capture(
                CaptureInput(
                    bytes: Data([9, 9, 9]), mimeType: "image/jpeg", source: .importSource,
                    attachmentKind: .receiptPhoto,
                    parentType: .fieldTicket, parentId: "ft-1", blobId: "blob-2", attachmentId: "att-1"))
            XCTFail("expected capture to throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("att-1 is already bound"))
        }
        XCTAssertFalse(bytes.has("file:///captures/blob-2"))  // refused before writing bytes
    }

    func testAReplayWithTheSameBlobIdButDifferentBytesIsRefusedBeforeLocalBytesChange() async throws {
        let (flow, _, _, bytes, _, _) = makeFlow()
        let first = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .importSource, attachmentKind: .fieldTicketPhoto,
                parentType: .fieldTicket, parentId: "ft-1", blobId: "blob-1", attachmentId: "att-1"))
        guard case .captured(let record, _) = first else { return XCTFail("expected captured") }

        do {
            _ = try await flow.capture(
                CaptureInput(
                    bytes: Data([9, 9, 9]), mimeType: "image/jpeg", source: .importSource,
                    attachmentKind: .fieldTicketPhoto,
                    parentType: .fieldTicket, parentId: "ft-1", blobId: "blob-1", attachmentId: "att-1"))
            XCTFail("expected capture to throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("blobId blob-1 is already bound to different bytes"))
        }
        let readBack = try await bytes.read(localUri: record.localUri, offset: 0, length: PHOTO.count)
        XCTAssertEqual(readBack, PHOTO)
    }

    func testRetryATransientSessionOpenFailureDefersAndALaterSweepSucceedsBytesIntact() async throws {
        let (flow, uploads, blobs, bytes, _, _) = makeFlow(failSessionOpens: 1)
        let result = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .camera, attachmentKind: .fieldTicketPhoto,
                parentType: .fieldTicket, parentId: "ft-1"))
        guard case .captured(let record, _) = result else { return XCTFail("expected captured") }

        let first = try await uploads.processOnce()
        XCTAssertEqual(first.deferred, 1)
        XCTAssertEqual(blobs.get(record.blobId)?.state, .localOnly)
        XCTAssertTrue(bytes.has(record.localUri))  // preserved across the failure

        let second = try await uploads.processOnce()
        XCTAssertEqual(second.dedupedAlreadyPresent, 1)
        XCTAssertEqual(blobs.get(record.blobId)?.state, .uploaded)
    }

    func testPurgeGatingAndNeedsReviewPreservationBytesSurviveUntilUploadAndLinkCommit() async throws {
        let (flow, uploads, blobs, bytes, _, linkStates) = makeFlow()
        let result = try await flow.capture(
            CaptureInput(
                bytes: PHOTO, mimeType: "image/jpeg", source: .camera, attachmentKind: .fieldTicketPhoto,
                parentType: .fieldTicket, parentId: "ft-1"))
        guard case .captured(let record, _) = result else { return XCTFail("expected captured") }
        _ = try await uploads.processOnce()  // uploaded + link enqueued
        let linkOpId = blobs.get(record.blobId)!.linkOpId!

        // Uploaded but link not committed -> NOT purgeable.
        _ = try await uploads.purgeOnce()
        XCTAssertTrue(bytes.has(record.localUri))

        // Hub flags the link needs-review -> blob preserved on-device, still not purgeable.
        linkStates.states[linkOpId] = .needsReview
        _ = try await uploads.processOnce()
        _ = try await uploads.purgeOnce()
        XCTAssertEqual(blobs.get(record.blobId)?.state, .uploaded)
        XCTAssertTrue(bytes.has(record.localUri))

        // Only an ACCEPTED link makes it purgeable.
        linkStates.states[linkOpId] = .accepted
        _ = try await uploads.processOnce()
        let purged = try await uploads.purgeOnce()
        XCTAssertEqual(purged, [record.blobId])
        XCTAssertFalse(bytes.has(record.localUri))
    }
}
