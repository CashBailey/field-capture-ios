// Port of fieldwork/rules.ts. `ReviewTrigger` is defined in Sync/Conflict.swift — same module, no
// import needed.

public struct FieldworkRuleError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// SR header/assistants are editable only while unlocked (ADR 004).
public func canEditSr(_ sr: ServiceRequest) -> Bool {
    sr.lockState == .unlocked
}

/**
 * Low-level lock primitive: apply a work-start event that is ALREADY known authorized (the
 * authorization gate is `resolveWorkStart`, not this function). The first event locks the SR; later
 * events are preserved as evidence only and never re-lock or change the locker. The version is
 * intentionally NOT bumped — the lock is server-DERIVED from an immutable event, not a versioned
 * header edit (ADR 004). Pure: returns a new SR and never mutates the input.
 */
public func applyWorkStart(_ sr: ServiceRequest, _ event: WorkStartEvent) throws -> ServiceRequest {
    guard event.srId == sr.srId else {
        throw FieldworkRuleError("work-start event srId does not match SR")
    }
    if sr.lockState == .locked {
        return sr  // already locked; event is evidence only
    }
    var next = sr
    next.lockState = .locked
    next.workStartedAt = event.occurredAt
    next.lockedByEventId = event.eventId
    return next
}

/**
 * Append a signature to an existing set. Append-only: a signatureId already present is a
 * programming error (would overwrite). Returns a new array.
 */
public func appendSignature(_ existing: [JhaJsaSignature], _ next: JhaJsaSignature) throws -> [JhaJsaSignature] {
    if existing.contains(where: { $0.signatureId == next.signatureId }) {
        throw FieldworkRuleError("signature \(next.signatureId) already exists — signatures are append-only")
    }
    return existing + [next]
}

/// Edit a draft ticket. Rejects edits to a submitted ticket (use the amendment workflow).
public func editDraftTicket(_ ticket: FieldTicket, _ fields: [String: JSONValue]) throws -> FieldTicket {
    guard ticket.state == .draft else {
        throw FieldworkRuleError(
            "ticket \(ticket.fieldTicketId) is \(ticket.state.rawValue); submitted tickets are immutable except via amendment"
        )
    }
    var next = ticket
    next.version += 1
    for (key, value) in fields { next.fields[key] = value }
    return next
}

/// Submit a draft ticket, making it immutable.
public func submitTicket(_ ticket: FieldTicket, _ submittedAt: String) throws -> FieldTicket {
    guard ticket.state == .draft else {
        throw FieldworkRuleError("ticket \(ticket.fieldTicketId) is already \(ticket.state.rawValue)")
    }
    var next = ticket
    next.state = .submitted
    next.submittedAt = submittedAt
    return next
}

/**
 * Amend an already-submitted ticket via the explicit correction workflow — the ONLY way to change a
 * ticket after submit (ADR 004). `submitted` → `amended`, and a previously-amended ticket may be
 * amended again; version bumps each time. Draft edits use `editDraftTicket` instead. Pure.
 */
public func amendTicket(_ ticket: FieldTicket, _ fields: [String: JSONValue], _ amendedAt: String) throws -> FieldTicket
{
    guard ticket.state == .submitted || ticket.state == .amended else {
        throw FieldworkRuleError(
            "ticket \(ticket.fieldTicketId) is \(ticket.state.rawValue); only submitted tickets can be amended"
        )
    }
    var next = ticket
    next.state = .amended
    next.version += 1
    for (key, value) in fields { next.fields[key] = value }
    return next
}

// ---- SR assignment + authorization (ADR 004: dispatch-only, before lock) ----

/// True iff the actor is the SR owner or a listed assistant.
public func isActorAuthorized(_ sr: ServiceRequest, _ actorRef: String) -> Bool {
    sr.ownerRef == actorRef || sr.assistantRefs.contains(actorRef)
}

public func assertActorAuthorized(_ sr: ServiceRequest, _ actorRef: String) throws {
    guard isActorAuthorized(sr, actorRef) else {
        throw FieldworkRuleError("actor \(actorRef) is not authorized on SR \(sr.srId)")
    }
}

/**
 * Reassign the SR owner. Allowed only while UNLOCKED (ADR 004); after lock the assignment is frozen.
 * The dispatch-role check itself is Hub-authoritative — the client cannot grant authority, only
 * refuse an obviously-illegal edit. Returns a new SR with the version bumped (precondition material).
 */
public func reassignOwner(_ sr: ServiceRequest, _ newOwnerRef: String) throws -> ServiceRequest {
    guard sr.lockState != .locked else {
        throw FieldworkRuleError("SR \(sr.srId) is locked; owner cannot be reassigned after work starts")
    }
    var next = sr
    next.ownerRef = newOwnerRef
    next.version += 1
    return next
}

/// Replace the assistant list. Allowed only while UNLOCKED (after lock: a manager-review workflow).
public func setAssistants(_ sr: ServiceRequest, _ assistantRefs: [String]) throws -> ServiceRequest {
    guard sr.lockState != .locked else {
        throw FieldworkRuleError("SR \(sr.srId) is locked; assistants cannot be changed after work starts")
    }
    var next = sr
    next.assistantRefs = assistantRefs
    next.version += 1
    return next
}

// ---- work-start authorization + manual-review escalation (ADR 004 / report 03) ----

public enum WorkStartOutcome: Equatable, Sendable {
    case locked(sr: ServiceRequest)
    case evidenceOnly(sr: ServiceRequest)
    case needsReview(sr: ServiceRequest, trigger: ReviewTrigger)
}

/**
 * Resolve a work-start event against the actors authorized AT SYNC TIME. The first work-start from a
 * currently-authorized actor locks the SR. If the SR is already locked, the event is preserved as
 * evidence only. If the actor is NO LONGER authorized (e.g. the SR was reassigned while they were
 * offline), the event must NOT lock or win authority — it is flagged for manual review and the
 * caller preserves it as evidence (report 03: "the phone never retroactively wins authority, but
 * evidence is never discarded" — cross-cutting invariant #2). Pure; never mutates inputs.
 *
 * Two deliberate scope boundaries: (1) the already-locked → "evidence-only" path does NOT detect a
 * COMPETING work-start from a different actor — that needs cross-event correlation state owned by
 * Hub, so the "competing-work-start-evidence" ReviewTrigger is raised by the Hub/sync layer, not
 * here. (2) The "needs-review" outcome returns the SR UNFROZEN (lockState unchanged) — locking would
 * wrongly grant authority; the caller MUST apply the freeze (sync `localActionFor` →
 * `.preserveEvidenceAndFlag`, `freeze: true`). Do not misread the unchanged lockState as editable.
 */
public func resolveWorkStart(
    _ sr: ServiceRequest,
    _ event: WorkStartEvent,
    _ currentlyAuthorized: Set<String>
) throws -> WorkStartOutcome {
    guard event.srId == sr.srId else {
        throw FieldworkRuleError("work-start event srId does not match SR")
    }
    if sr.lockState == .locked {
        return .evidenceOnly(sr: sr)
    }
    if !currentlyAuthorized.contains(event.actorRef) {
        return .needsReview(sr: sr, trigger: .offlineWorkStartAfterReassignment)
    }
    return .locked(sr: try applyWorkStart(sr, event))
}

// ---- photo attachments (immutable blob + append-only link, ADR 004) ----

/// Append a photo attachment link. Append-only: a duplicate attachmentId would overwrite.
public func appendAttachment(_ existing: [PhotoAttachment], _ next: PhotoAttachment) throws -> [PhotoAttachment] {
    if existing.contains(where: { $0.attachmentId == next.attachmentId }) {
        throw FieldworkRuleError("attachment \(next.attachmentId) already exists — attachment links are append-only")
    }
    return existing + [next]
}

/**
 * A local photo copy is purgeable only once Hub confirms BOTH the blob upload AND the
 * attachment-link commit (`hubConfirmed`). Mirrors the sync two-phase blob invariant: never purge
 * unsynced evidence (cross-cutting invariant #2).
 */
public func canPurgeAttachment(_ att: PhotoAttachment) -> Bool {
    att.hubConfirmed
}
