// Port of fieldwork/types.ts — Field-work data model contracts (ADR 004, Slice 4). Types + the
// SR-lock and append-only invariants. The phone caches these; Hub is the authority that finalizes
// them.

public enum SrLockState: String, Equatable, Sendable, Codable {
    case unlocked
    case locked
}

/// Cached Service Request. Edits require a version precondition; Hub enforces the lock.
public struct ServiceRequest: Equatable, Sendable {
    public var srId: String
    public var version: Int
    public var ownerRef: String
    /// Callers must never rely on sharing storage with a previously-returned SR's array — Swift
    /// arrays are value types, so every copy is already independent (stronger than the TS
    /// `readonly string[]` comment, which only guards against in-place mutation of a shared ref).
    public var assistantRefs: [String]
    public var lockState: SrLockState
    /// Set by the first accepted authorized work-start event.
    public var workStartedAt: String?
    public var lockedByEventId: String?

    public init(
        srId: String,
        version: Int,
        ownerRef: String,
        assistantRefs: [String],
        lockState: SrLockState,
        workStartedAt: String? = nil,
        lockedByEventId: String? = nil
    ) {
        self.srId = srId
        self.version = version
        self.ownerRef = ownerRef
        self.assistantRefs = assistantRefs
        self.lockState = lockState
        self.workStartedAt = workStartedAt
        self.lockedByEventId = lockedByEventId
    }
}

/// Configured markers that count as "work started".
public enum WorkStartKind: String, Equatable, Sendable, Codable {
    case jhajsaSigned = "jhajsa-signed"
    case arrived
    case workEventSubmitted = "work-event-submitted"
    case fieldTicketStarted = "field-ticket-started"
    case photoUploaded = "photo-uploaded"
}

/// Immutable work-start event. The first accepted authorized one locks the SR on Hub.
public struct WorkStartEvent: Equatable, Sendable, Codable {
    public var eventId: String
    public var srId: String
    public var kind: WorkStartKind
    public var actorRef: String
    public var occurredAt: String

    public init(eventId: String, srId: String, kind: WorkStartKind, actorRef: String, occurredAt: String) {
        self.eventId = eventId
        self.srId = srId
        self.kind = kind
        self.actorRef = actorRef
        self.occurredAt = occurredAt
    }
}

/// Append-only JHA/JSA signature. Never overwritten or deleted.
public struct JhaJsaSignature: Equatable, Sendable {
    public var signatureId: String
    public var srId: String
    public var signerRef: String
    /// Reference to an immutable signature blob (see sync AttachBlobCommand).
    public var signatureBlobId: String
    public var signedAt: String

    public init(signatureId: String, srId: String, signerRef: String, signatureBlobId: String, signedAt: String) {
        self.signatureId = signatureId
        self.srId = srId
        self.signerRef = signerRef
        self.signatureBlobId = signatureBlobId
        self.signedAt = signedAt
    }
}

public enum FieldTicketState: String, Equatable, Sendable, Codable {
    case draft
    case submitted
    case amended
}

/// Minimal JSON-like value used to port TS's untyped `Record<string, unknown>` (`FieldTicket.fields`)
/// into an `Equatable` Swift type, so ported tests can assert equality the same way `toEqual` does.
/// Not a 1:1 file port — there is no equivalent TS source file for this; it exists purely so the
/// Swift port can express an opaque, structurally-comparable JSON payload.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

/**
 * Field ticket. Client-generated id; versioned while draft; immutable after submit except via
 * an explicit correction/amendment workflow.
 */
public struct FieldTicket: Equatable, Sendable {
    public var fieldTicketId: String
    public var srId: String
    public var version: Int
    public var state: FieldTicketState
    public var createdAt: String
    public var submittedAt: String?
    public var fields: [String: JSONValue]

    public init(
        fieldTicketId: String,
        srId: String,
        version: Int,
        state: FieldTicketState,
        createdAt: String,
        submittedAt: String? = nil,
        fields: [String: JSONValue] = [:]
    ) {
        self.fieldTicketId = fieldTicketId
        self.srId = srId
        self.version = version
        self.state = state
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.fields = fields
    }
}

/// Inline TS union on `PhotoAttachment.kind` — named here since Swift enums require a top-level
/// declaration.
public enum PhotoAttachmentKind: String, Equatable, Sendable, Codable {
    case fieldTicketPhoto = "field-ticket-photo"
    case disposalPhoto = "disposal-photo"
    case receiptPhoto = "receipt-photo"
}

/// Inline TS union on `PhotoAttachment.parentType`. Distinct from sync's `AttachBlobCommand`
/// parent-type union (which has two additional values) — kept as separate types since the value
/// sets differ.
public enum PhotoAttachmentParentType: String, Equatable, Sendable, Codable {
    case fieldTicket = "field-ticket"
    case sr
}

/// Immutable blob + append-only attachment link (no in-place overwrite).
public struct PhotoAttachment: Equatable, Sendable {
    public var attachmentId: String
    public var blobId: String
    public var sha256: String
    public var kind: PhotoAttachmentKind
    public var parentType: PhotoAttachmentParentType
    public var parentId: String
    public var capturedAt: String
    /**
     * True once Hub confirms BOTH upload and link commit; only then may the local copy purge. The
     * engine slice that sets this must require the same two confirmations the sync layer's
     * two-phase blob model gates on (see `Sync/Attachment.swift` `isBlobPurgeable`:
     * `state == .linked && uploadConfirmed && linkConfirmed`).
     */
    public var hubConfirmed: Bool

    public init(
        attachmentId: String,
        blobId: String,
        sha256: String,
        kind: PhotoAttachmentKind,
        parentType: PhotoAttachmentParentType,
        parentId: String,
        capturedAt: String,
        hubConfirmed: Bool
    ) {
        self.attachmentId = attachmentId
        self.blobId = blobId
        self.sha256 = sha256
        self.kind = kind
        self.parentType = parentType
        self.parentId = parentId
        self.capturedAt = capturedAt
        self.hubConfirmed = hubConfirmed
    }
}
