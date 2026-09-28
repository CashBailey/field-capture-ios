/**
 * Field-work data model contracts (ADR 004, Slice 4). Types + the SR-lock and append-only
 * invariants. The phone caches these; Hub is the authority that finalizes them.
 */

export type SrLockState = "unlocked" | "locked";

/** Cached Service Request. Edits require a version precondition; Hub enforces the lock. */
export interface ServiceRequest {
  srId: string;
  version: number;
  ownerRef: string;
  /** Readonly: SR snapshots are shared by value; callers must never mutate a returned SR's array. */
  assistantRefs: readonly string[];
  lockState: SrLockState;
  /** Set by the first accepted authorized work-start event. */
  workStartedAt: string | null;
  lockedByEventId: string | null;
}

/** Configured markers that count as "work started". */
export type WorkStartKind =
  | "jhajsa-signed"
  | "arrived"
  | "work-event-submitted"
  | "field-ticket-started"
  | "photo-uploaded";

/** Immutable work-start event. The first accepted authorized one locks the SR on Hub. */
export interface WorkStartEvent {
  eventId: string;
  srId: string;
  kind: WorkStartKind;
  actorRef: string;
  occurredAt: string;
}

/** Append-only JHA/JSA signature. Never overwritten or deleted. */
export interface JhaJsaSignature {
  signatureId: string;
  srId: string;
  signerRef: string;
  /** Reference to an immutable signature blob (see sync AttachBlobCommand). */
  signatureBlobId: string;
  signedAt: string;
}

export type FieldTicketState = "draft" | "submitted" | "amended";

/**
 * Field ticket. Client-generated id; versioned while draft; immutable after submit except via
 * an explicit correction/amendment workflow.
 */
export interface FieldTicket {
  fieldTicketId: string;
  srId: string;
  version: number;
  state: FieldTicketState;
  createdAt: string;
  submittedAt: string | null;
  fields: Record<string, unknown>;
}

/** Immutable blob + append-only attachment link (no in-place overwrite). */
export interface PhotoAttachment {
  attachmentId: string;
  blobId: string;
  sha256: string;
  kind: "field-ticket-photo" | "disposal-photo" | "receipt-photo";
  parentType: "field-ticket" | "sr";
  parentId: string;
  capturedAt: string;
  /**
   * True once Hub confirms BOTH upload and link commit; only then may the local copy purge. The
   * engine slice that sets this must require the same two confirmations the sync layer's
   * two-phase blob model gates on (see `sync/attachment.ts` `isBlobPurgeable`:
   * `state === "linked" && uploadConfirmed && linkConfirmed`).
   */
  hubConfirmed: boolean;
}
