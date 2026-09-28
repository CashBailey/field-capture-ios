// Port of src/runtime/captureFlow.ts — Photo/signature capture flow — the capture/import
// abstraction in front of the upload engine. One path for all four attachment kinds (field-ticket
// photo, disposal photo, receipt photo, signature) and all three sources (camera, import, signature
// pad):
//
//   bytes → SHA-256 (integrity anchor, computed at capture) → durable local bytes → durable blob
//   record linked to its parent → UploadEngine drives tus upload + attachment-link.
//
// Capture is a FIELD ACTION: locked unless the clock gate is unlocked. Once captured, the bytes are
// protected by the blob purge invariant (upload + link both Hub-confirmed) regardless of gate or
// connectivity — capture works fully offline.
import Foundation
import FieldContracts
import FieldDomain

public enum CaptureSource {
    case camera
    case importSource
    case signaturePad
}

public struct CaptureInput {
    public var bytes: Data
    public var mimeType: String
    public var source: CaptureSource
    public var attachmentKind: AttachBlobKind
    public var parentType: AttachBlobParentType
    public var parentId: String
    /// opId of the parent's own outbox operation — the link command will depend on it.
    public var parentOpId: String?
    /// Stable ids for re-imports; generated when absent.
    public var blobId: String?
    public var attachmentId: String?

    public init(
        bytes: Data, mimeType: String, source: CaptureSource, attachmentKind: AttachBlobKind,
        parentType: AttachBlobParentType, parentId: String, parentOpId: String? = nil,
        blobId: String? = nil, attachmentId: String? = nil
    ) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.source = source
        self.attachmentKind = attachmentKind
        self.parentType = parentType
        self.parentId = parentId
        self.parentOpId = parentOpId
        self.blobId = blobId
        self.attachmentId = attachmentId
    }
}

public enum CaptureResult {
    case captured(record: BlobUploadRecord, sha256: String)
    case locked(reason: String)
}

public struct CaptureFlowError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Mirrors the TS `Pick<WriteIdentity, 'generateUuid'>` — capture only needs to mint ids, not
/// allocate write-identity sequence numbers.
public struct CaptureIdentity {
    public var generateUuid: () -> String
    public init(generateUuid: @escaping () -> String) {
        self.generateUuid = generateUuid
    }
}

public struct CaptureFlowDeps {
    public var uploads: UploadEngine
    /// Persist the raw bytes durably; returns the local URI. (Filesystem adapter in production.)
    public var persistBytes: (_ blobId: String, _ bytes: Data) async throws -> String
    public var gateState: () -> FieldWorkGate
    public var identity: CaptureIdentity

    public init(
        uploads: UploadEngine,
        persistBytes: @escaping (_ blobId: String, _ bytes: Data) async throws -> String,
        gateState: @escaping () -> FieldWorkGate,
        identity: CaptureIdentity
    ) {
        self.uploads = uploads
        self.persistBytes = persistBytes
        self.gateState = gateState
        self.identity = identity
    }
}

public final class CaptureFlow {
    private let deps: CaptureFlowDeps

    public init(_ deps: CaptureFlowDeps) {
        self.deps = deps
    }

    /// Capture one attachment. The SHA-256 is computed HERE, before anything persists — every later
    /// integrity check (tus hash verification, Hub-side dedupe) anchors on it. Idempotent on blobId
    /// (UploadEngine.register); a duplicate attachmentId bound to a different blob throws.
    public func capture(_ input: CaptureInput) async throws -> CaptureResult {
        let gate = deps.gateState()
        if case .locked(let reason, _) = gate {
            return .locked(reason: fieldWorkGateLockReason(reason))
        }

        let sha256 = sha256Hex(input.bytes)
        let blobId = input.blobId ?? deps.identity.generateUuid()
        let requestedAttachmentId = input.attachmentId
        if let existingBlob = try deps.uploads.get(blobId) {
            guard existingBlob.sha256 == sha256, existingBlob.byteLength == input.bytes.count else {
                throw CaptureFlowError("blobId \(blobId) is already bound to different bytes")
            }
            if let requestedAttachmentId, existingBlob.attachmentId != requestedAttachmentId {
                throw CaptureFlowError("blobId \(blobId) is already bound to attachment \(existingBlob.attachmentId)")
            }
            return .captured(record: existingBlob, sha256: sha256)
        }
        let attachmentId = requestedAttachmentId ?? deps.identity.generateUuid()
        if let existingAttachment = try deps.uploads.getByAttachmentId(attachmentId) {
            throw CaptureFlowError("attachmentId \(attachmentId) is already bound to blob \(existingAttachment.blobId)")
        }
        let localUri = try await deps.persistBytes(blobId, input.bytes)
        let register = RegisterBlobInput(
            blobId: blobId, sha256: sha256, byteLength: input.bytes.count, mimeType: input.mimeType,
            localUri: localUri, attachmentId: attachmentId, parentType: input.parentType,
            parentId: input.parentId, attachmentKind: input.attachmentKind, parentOpId: input.parentOpId)
        let record = try deps.uploads.register(register)
        return .captured(record: record, sha256: sha256)
    }

    /// Signature-pad convenience: signatures are serialized-vector bytes with the 'signature' kind.
    public func captureSignature(
        bytes: Data, parentType: AttachBlobParentType, parentId: String, parentOpId: String? = nil,
        attachmentId: String? = nil
    ) async throws -> CaptureResult {
        try await capture(
            CaptureInput(
                bytes: bytes, mimeType: "application/octet-stream", source: .signaturePad,
                attachmentKind: .signature, parentType: parentType, parentId: parentId,
                parentOpId: parentOpId, attachmentId: attachmentId))
    }
}
