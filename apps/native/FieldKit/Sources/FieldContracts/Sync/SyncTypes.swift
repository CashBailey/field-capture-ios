// Port of sync/types.ts — Sync foundation contracts (ADR 004). Types only — NO engine, NO
// network, NO Hub here.
//
// Model: Field Capture submits commands + immutable events with strong write identity; Hub
// validates transactionally and accepts / rejects / flags for manual review. Down-sync uses a
// server-issued monotonic change token. Consistent with Field Time (UUIDs, idempotency keys,
// local sequence, dependency ordering, retry/backoff, durable outbox).

/// Server-issued version frontier. The server defines order, never client timestamps.
public struct ChangeToken: Equatable, Sendable, Codable {
    public var authorityEpoch: Int
    public var commitSeq: Int

    public init(authorityEpoch: Int, commitSeq: Int) {
        self.authorityEpoch = authorityEpoch
        self.commitSeq = commitSeq
    }
}

/// Compare two change tokens. Returns <0, 0, or >0. Higher epoch always wins.
public func compareChangeTokens(_ a: ChangeToken, _ b: ChangeToken) -> Int {
    if a.authorityEpoch != b.authorityEpoch { return a.authorityEpoch - b.authorityEpoch }
    return a.commitSeq - b.commitSeq
}

public enum OutboxItemState: String, Equatable, Sendable, Codable {
    case pending
    case inFlight = "in-flight"
    case accepted
    case rejected
    case needsReview = "needs-review"
}

/// Optimistic-concurrency precondition for mutable business edits.
public struct VersionPrecondition: Equatable, Sendable, Codable {
    /// base_version / If-Match. Hub rejects (412) if stale, (428) if a required precondition is missing.
    public var baseVersion: Int

    public init(baseVersion: Int) {
        self.baseVersion = baseVersion
    }
}

/// "command" = mutate authoritative state; "event" = append immutable evidence.
public enum OperationKind: String, Equatable, Sendable, Codable {
    case command
    case event
}

/// Envelope shared by commands (mutations) and immutable events.
public struct OperationEnvelope<Payload: Sendable>: Sendable {
    /// Stable operation id (UUIDv7 recommended).
    public var opId: String
    public var kind: OperationKind
    /// Domain operation name, e.g. "sr.reassign", "jhajsa.sign", "ticket.submit".
    public var type: String
    /// Idempotency key — see buildIdempotencyKey().
    public var idempotencyKey: String
    /// Per-device monotonic sequence number.
    public var localSeq: Int
    /// opIds this operation depends on (must commit first).
    public var dependsOn: [String]
    /// Required for mutable-edit commands; omitted for creates and append-only events.
    public var precondition: VersionPrecondition?
    public var payload: Payload

    public init(
        opId: String,
        kind: OperationKind,
        type: String,
        idempotencyKey: String,
        localSeq: Int,
        dependsOn: [String],
        precondition: VersionPrecondition? = nil,
        payload: Payload
    ) {
        self.opId = opId
        self.kind = kind
        self.type = type
        self.idempotencyKey = idempotencyKey
        self.localSeq = localSeq
        self.dependsOn = dependsOn
        self.precondition = precondition
        self.payload = payload
    }
}
extension OperationEnvelope: Equatable where Payload: Equatable {}

/// A durable outbox row wrapping one envelope plus delivery state.
public struct OutboxItem<Payload: Sendable>: Sendable {
    public var envelope: OperationEnvelope<Payload>
    public var state: OutboxItemState
    public var retryCount: Int
    /// Set when Hub commits it.
    public var committedToken: ChangeToken?
    /// Machine-readable rejection, e.g. "stale_version", "locked_sr", "assignment_changed".
    public var rejectionCode: String?
    /// Human-readable detail of the most recent failure (Hub `detail` or transport error), verbatim.
    public var lastError: String?
    /**
     * Row timestamps (ISO 8601). Optional at the type level for in-memory fixtures, but durable
     * rows MUST populate them — the caller stamps (contracts stay clock-free).
     */
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        envelope: OperationEnvelope<Payload>,
        state: OutboxItemState = .pending,
        retryCount: Int = 0,
        committedToken: ChangeToken? = nil,
        rejectionCode: String? = nil,
        lastError: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.envelope = envelope
        self.state = state
        self.retryCount = retryCount
        self.committedToken = committedToken
        self.rejectionCode = rejectionCode
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
extension OutboxItem: Equatable where Payload: Equatable {}

/// Hub's response to a submitted operation. Ported as an enum with associated values (PORTING.md:
/// TS discriminated unions → Swift enums); `opId` is exposed as a computed property since every
/// case carries one, mirroring how the TS union is accessed regardless of which member it is.
public enum CommandResult<Payload: Sendable>: Sendable {
    case accepted(opId: String, token: ChangeToken)
    case rejected(opId: String, rejectionCode: String, detail: String? = nil, latest: Payload? = nil)
    case needsReview(opId: String, reviewReason: String)

    public var opId: String {
        switch self {
        case .accepted(let opId, _): return opId
        case .rejected(let opId, _, _, _): return opId
        case .needsReview(let opId, _): return opId
        }
    }
}
extension CommandResult: Equatable where Payload: Equatable {}

/**
 * Two-phase resumable upload (tus-style) contract for photos/documents. The local copy is
 * purged only after BOTH the upload completes AND the attachment link commits (ADR 004).
 */
public struct UploadSessionRequest: Equatable, Sendable {
    public var blobId: String
    public var sha256: String
    public var byteLength: Int
    public var mimeType: String
    public var idempotencyKey: String

    public init(blobId: String, sha256: String, byteLength: Int, mimeType: String, idempotencyKey: String) {
        self.blobId = blobId
        self.sha256 = sha256
        self.byteLength = byteLength
        self.mimeType = mimeType
        self.idempotencyKey = idempotencyKey
    }
}

public enum UploadSessionResponse: Equatable, Sendable {
    case alreadyPresent(blobId: String)
    case newSession(uploadSessionId: String, uploadUrl: String)
}

/// Inline TS union on `AttachBlobCommand.parentType`. Distinct from fieldwork's
/// `PhotoAttachmentParentType` (a narrower value set) — kept separate since the value sets differ.
public enum AttachBlobParentType: String, Equatable, Sendable, Codable {
    case fieldTicket = "field-ticket"
    case sr
    case jhajsa
    case printJob = "print-job"
}

/// Inline TS union on `AttachBlobCommand.attachmentKind`. Distinct from fieldwork's
/// `PhotoAttachmentKind` (which lacks `.signature`).
public enum AttachBlobKind: String, Equatable, Sendable, Codable {
    case fieldTicketPhoto = "field-ticket-photo"
    case disposalPhoto = "disposal-photo"
    case receiptPhoto = "receipt-photo"
    case signature
}

/// Separate append-only command linking an uploaded blob to a parent record.
public struct AttachBlobCommand: Equatable, Sendable, Codable {
    public var attachmentId: String
    public var blobId: String
    public var parentType: AttachBlobParentType
    public var parentId: String
    public var attachmentKind: AttachBlobKind
    public var idempotencyKey: String

    public init(
        attachmentId: String,
        blobId: String,
        parentType: AttachBlobParentType,
        parentId: String,
        attachmentKind: AttachBlobKind,
        idempotencyKey: String
    ) {
        self.attachmentId = attachmentId
        self.blobId = blobId
        self.parentType = parentType
        self.parentId = parentId
        self.attachmentKind = attachmentKind
        self.idempotencyKey = idempotencyKey
    }
}

/// Inline TS union on `PrintEvent.event`. Distinct from printer's `PrintJobStatus` (different
/// value set — this one has no "rendering"/"printing"/"synced").
public enum PrintEventKind: String, Equatable, Sendable, Codable {
    case queued
    case printed
    case failed
    case canceled
}

/// Print-event sync contract — print jobs are output artifacts, logged then synced.
public struct PrintEvent: Equatable, Sendable, Codable {
    public var printJobId: String
    public var event: PrintEventKind
    public var occurredAt: String
    public var idempotencyKey: String

    public init(printJobId: String, event: PrintEventKind, occurredAt: String, idempotencyKey: String) {
        self.printJobId = printJobId
        self.event = event
        self.occurredAt = occurredAt
        self.idempotencyKey = idempotencyKey
    }
}

/// Inline TS union on `InvalidationHint.scope`: `"employees" | "permissions" | "cards" |
/// \`sr:${string}\``. The template-literal member becomes `.sr(String)`.
public enum InvalidationScope: Equatable, Sendable {
    case employees
    case permissions
    case cards
    case sr(String)
}

/// Reference-data invalidation hint (push via MQTT/WebSocket; pull is the source of truth).
public struct InvalidationHint: Equatable, Sendable {
    public var scope: InvalidationScope
    public var newVersion: Int
    public var reason: InvalidationReason

    public init(scope: InvalidationScope, newVersion: Int, reason: InvalidationReason) {
        self.scope = scope
        self.newVersion = newVersion
        self.reason = reason
    }
}

/// Inline TS union on `InvalidationHint.reason`.
public enum InvalidationReason: String, Equatable, Sendable, Codable {
    case revocation
    case assignmentChange = "assignment_change"
    case permissionChange = "permission_change"
}
