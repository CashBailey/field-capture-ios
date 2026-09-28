import type { ReviewTrigger } from "../sync/index";
import type {
  FieldTicket,
  JhaJsaSignature,
  PhotoAttachment,
  ServiceRequest,
  WorkStartEvent,
} from "./types";

export class FieldworkRuleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FieldworkRuleError";
  }
}

/** SR header/assistants are editable only while unlocked (ADR 004). */
export function canEditSr(sr: ServiceRequest): boolean {
  return sr.lockState === "unlocked";
}

/**
 * Low-level lock primitive: apply a work-start event that is ALREADY known authorized (the
 * authorization gate is `resolveWorkStart`, not this function). The first event locks the SR; later
 * events are preserved as evidence only and never re-lock or change the locker. The version is
 * intentionally NOT bumped — the lock is server-DERIVED from an immutable event, not a versioned
 * header edit (ADR 004). Pure: returns a new SR and never mutates the input (arrays are `readonly`).
 */
export function applyWorkStart(sr: ServiceRequest, event: WorkStartEvent): ServiceRequest {
  if (event.srId !== sr.srId) {
    throw new FieldworkRuleError("work-start event srId does not match SR");
  }
  if (sr.lockState === "locked") {
    return sr; // already locked; event is evidence only
  }
  return {
    ...sr,
    lockState: "locked",
    workStartedAt: event.occurredAt,
    lockedByEventId: event.eventId,
  };
}

/**
 * Append a signature to an existing set. Append-only: a signatureId already present is a
 * programming error (would overwrite). Returns a new array.
 */
export function appendSignature(
  existing: readonly JhaJsaSignature[],
  next: JhaJsaSignature,
): JhaJsaSignature[] {
  if (existing.some((s) => s.signatureId === next.signatureId)) {
    throw new FieldworkRuleError(
      `signature ${next.signatureId} already exists — signatures are append-only`,
    );
  }
  return [...existing, next];
}

/** Edit a draft ticket. Rejects edits to a submitted ticket (use the amendment workflow). */
export function editDraftTicket(
  ticket: FieldTicket,
  fields: Record<string, unknown>,
): FieldTicket {
  if (ticket.state !== "draft") {
    throw new FieldworkRuleError(
      `ticket ${ticket.fieldTicketId} is ${ticket.state}; submitted tickets are immutable except via amendment`,
    );
  }
  return { ...ticket, version: ticket.version + 1, fields: { ...ticket.fields, ...fields } };
}

/** Submit a draft ticket, making it immutable. */
export function submitTicket(ticket: FieldTicket, submittedAt: string): FieldTicket {
  if (ticket.state !== "draft") {
    throw new FieldworkRuleError(`ticket ${ticket.fieldTicketId} is already ${ticket.state}`);
  }
  return { ...ticket, state: "submitted", submittedAt };
}

/**
 * Amend an already-submitted ticket via the explicit correction workflow — the ONLY way to change a
 * ticket after submit (ADR 004). `submitted` → `amended`, and a previously-amended ticket may be
 * amended again; version bumps each time. Draft edits use `editDraftTicket` instead. Pure.
 */
export function amendTicket(
  ticket: FieldTicket,
  fields: Record<string, unknown>,
  _amendedAt: string,
): FieldTicket {
  if (ticket.state !== "submitted" && ticket.state !== "amended") {
    throw new FieldworkRuleError(
      `ticket ${ticket.fieldTicketId} is ${ticket.state}; only submitted tickets can be amended`,
    );
  }
  return {
    ...ticket,
    state: "amended",
    version: ticket.version + 1,
    fields: { ...ticket.fields, ...fields },
  };
}

// ---- SR assignment + authorization (ADR 004: dispatch-only, before lock) ----

/** True iff the actor is the SR owner or a listed assistant. */
export function isActorAuthorized(sr: ServiceRequest, actorRef: string): boolean {
  return sr.ownerRef === actorRef || sr.assistantRefs.includes(actorRef);
}

export function assertActorAuthorized(sr: ServiceRequest, actorRef: string): void {
  if (!isActorAuthorized(sr, actorRef)) {
    throw new FieldworkRuleError(`actor ${actorRef} is not authorized on SR ${sr.srId}`);
  }
}

/**
 * Reassign the SR owner. Allowed only while UNLOCKED (ADR 004); after lock the assignment is frozen.
 * The dispatch-role check itself is Hub-authoritative — the client cannot grant authority, only
 * refuse an obviously-illegal edit. Returns a new SR with the version bumped (precondition material).
 */
export function reassignOwner(sr: ServiceRequest, newOwnerRef: string): ServiceRequest {
  if (sr.lockState === "locked") {
    throw new FieldworkRuleError(
      `SR ${sr.srId} is locked; owner cannot be reassigned after work starts`,
    );
  }
  return { ...sr, ownerRef: newOwnerRef, version: sr.version + 1 };
}

/** Replace the assistant list. Allowed only while UNLOCKED (after lock: a manager-review workflow). */
export function setAssistants(
  sr: ServiceRequest,
  assistantRefs: readonly string[],
): ServiceRequest {
  if (sr.lockState === "locked") {
    throw new FieldworkRuleError(
      `SR ${sr.srId} is locked; assistants cannot be changed after work starts`,
    );
  }
  return { ...sr, assistantRefs: [...assistantRefs], version: sr.version + 1 };
}

// ---- work-start authorization + manual-review escalation (ADR 004 / report 03) ----

export type WorkStartOutcome =
  | { decision: "locked"; sr: ServiceRequest }
  | { decision: "evidence-only"; sr: ServiceRequest }
  | { decision: "needs-review"; sr: ServiceRequest; trigger: ReviewTrigger };

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
 * `preserve-evidence-and-flag`, `freeze: true`). Do not misread the unchanged lockState as editable.
 */
export function resolveWorkStart(
  sr: ServiceRequest,
  event: WorkStartEvent,
  currentlyAuthorized: ReadonlySet<string>,
): WorkStartOutcome {
  if (event.srId !== sr.srId) {
    throw new FieldworkRuleError("work-start event srId does not match SR");
  }
  if (sr.lockState === "locked") {
    return { decision: "evidence-only", sr };
  }
  if (!currentlyAuthorized.has(event.actorRef)) {
    return { decision: "needs-review", sr, trigger: "offline-work-start-after-reassignment" };
  }
  return { decision: "locked", sr: applyWorkStart(sr, event) };
}

// ---- photo attachments (immutable blob + append-only link, ADR 004) ----

/** Append a photo attachment link. Append-only: a duplicate attachmentId would overwrite. */
export function appendAttachment(
  existing: readonly PhotoAttachment[],
  next: PhotoAttachment,
): PhotoAttachment[] {
  if (existing.some((a) => a.attachmentId === next.attachmentId)) {
    throw new FieldworkRuleError(
      `attachment ${next.attachmentId} already exists — attachment links are append-only`,
    );
  }
  return [...existing, next];
}

/**
 * A local photo copy is purgeable only once Hub confirms BOTH the blob upload AND the
 * attachment-link commit (`hubConfirmed`). Mirrors the sync two-phase blob invariant: never purge
 * unsynced evidence (cross-cutting invariant #2).
 */
export function canPurgeAttachment(att: PhotoAttachment): boolean {
  return att.hubConfirmed;
}
