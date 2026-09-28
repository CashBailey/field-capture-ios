/**
 * Sync foundation contracts (ADR 004). Types only — NO engine, NO network, NO Hub here.
 *
 * Model: Field Capture submits commands + immutable events with strong write identity; Hub
 * validates transactionally and accepts / rejects / flags for manual review. Down-sync uses a
 * server-issued monotonic change token. Consistent with Field Time (UUIDs, idempotency keys,
 * local sequence, dependency ordering, retry/backoff, durable outbox).
 */

/** Server-issued version frontier. The server defines order, never client timestamps. */
export interface ChangeToken {
  authorityEpoch: number;
  commitSeq: number;
}

/** Compare two change tokens. Returns <0, 0, or >0. Higher epoch always wins. */
export function compareChangeTokens(a: ChangeToken, b: ChangeToken): number {
  if (a.authorityEpoch !== b.authorityEpoch) return a.authorityEpoch - b.authorityEpoch;
  return a.commitSeq - b.commitSeq;
}

export type OutboxItemState =
  | "pending"
  | "in-flight"
  | "accepted"
  | "rejected"
  | "needs-review";

/** Optimistic-concurrency precondition for mutable business edits. */
export interface VersionPrecondition {
  /** base_version / If-Match. Hub rejects (412) if stale, (428) if a required precondition is missing. */
  baseVersion: number;
}

/** Envelope shared by commands (mutations) and immutable events. */
export interface OperationEnvelope<TPayload = unknown> {
  /** Stable operation id (UUIDv7 recommended). */
  opId: string;
  /** "command" = mutate authoritative state; "event" = append immutable evidence. */
  kind: "command" | "event";
  /** Domain operation name, e.g. "sr.reassign", "jhajsa.sign", "ticket.submit". */
  type: string;
  /** Idempotency key — see buildIdempotencyKey(). */
  idempotencyKey: string;
  /** Per-device monotonic sequence number. */
  localSeq: number;
  /** opIds this operation depends on (must commit first). */
  dependsOn: string[];
  /** Required for mutable-edit commands; omitted for creates and append-only events. */
  precondition?: VersionPrecondition;
  payload: TPayload;
}

/** A durable outbox row wrapping one envelope plus delivery state. */
export interface OutboxItem<TPayload = unknown> {
  envelope: OperationEnvelope<TPayload>;
  state: OutboxItemState;
  retryCount: number;
  /** Set when Hub commits it. */
  committedToken?: ChangeToken;
  /** Machine-readable rejection, e.g. "stale_version", "locked_sr", "assignment_changed". */
  rejectionCode?: string;
  /** Human-readable detail of the most recent failure (Hub `detail` or transport error), verbatim. */
  lastError?: string;
  /**
   * Row timestamps (ISO 8601). Optional at the type level for in-memory fixtures, but durable
   * rows MUST populate them — the caller stamps (contracts stay clock-free).
   */
  createdAt?: string;
  updatedAt?: string;
}

/** Hub's response to a submitted operation. */
export type CommandResult<TPayload = unknown> =
  | { outcome: "accepted"; opId: string; token: ChangeToken }
  | {
      outcome: "rejected";
      opId: string;
      rejectionCode: string;
      /** Human-readable detail from Hub, preserved verbatim (never required, never lost). */
      detail?: string;
      latest?: TPayload;
    }
  | { outcome: "needs-review"; opId: string; reviewReason: string };

/**
 * Two-phase resumable upload (tus-style) contract for photos/documents. The local copy is
 * purged only after BOTH the upload completes AND the attachment link commits (ADR 004).
 */
export interface UploadSessionRequest {
  blobId: string;
  sha256: string;
  byteLength: number;
  mimeType: string;
  idempotencyKey: string;
}

export type UploadSessionResponse =
  | { result: "already-present"; blobId: string }
  | { result: "new-session"; uploadSessionId: string; uploadUrl: string };

/** Separate append-only command linking an uploaded blob to a parent record. */
export interface AttachBlobCommand {
  attachmentId: string;
  blobId: string;
  parentType: "field-ticket" | "sr" | "jhajsa" | "print-job";
  parentId: string;
  attachmentKind: "field-ticket-photo" | "disposal-photo" | "receipt-photo" | "signature";
  idempotencyKey: string;
}

/** Print-event sync contract — print jobs are output artifacts, logged then synced. */
export interface PrintEvent {
  printJobId: string;
  event: "queued" | "printed" | "failed" | "canceled";
  occurredAt: string;
  idempotencyKey: string;
}

/** Reference-data invalidation hint (push via MQTT/WebSocket; pull is the source of truth). */
export interface InvalidationHint {
  scope: "employees" | "permissions" | "cards" | `sr:${string}`;
  newVersion: number;
  reason: "revocation" | "assignment_change" | "permission_change";
}
