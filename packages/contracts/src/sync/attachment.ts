/**
 * Two-phase attachment lifecycle (ADR 004). Photos/documents are immutable blobs uploaded with a
 * tus-style resumable session, then linked to a parent record by a SEPARATE append-only command.
 * The hard invariant (cross-cutting #2, "never silently lose work"): the on-device copy is
 * purgeable ONLY after Hub confirms BOTH the upload AND the attachment-link commit. Anything less
 * stays on the phone.
 *
 * Pure state machine — no I/O. A later engine slice drives it from real tus/HTTP events.
 */

export type BlobLifecycleState =
  | "local-only" // captured on device, nothing uploaded yet
  | "uploading" // tus session open, bytes transferring
  | "uploaded" // Hub verified whole-file sha256 + size; durable on Hub
  | "linked" // AttachBlob command committed — fully synced, purgeable
  | "upload-expired"; // tus session abandoned/expired; restart from a local copy

export interface BlobRecord {
  blobId: string;
  sha256: string;
  byteLength: number;
  state: BlobLifecycleState;
  /** Set once Hub confirms whole-file receipt. */
  uploadConfirmed: boolean;
  /** Set once the append-only attachment-link command commits. */
  linkConfirmed: boolean;
}

export type BlobEvent =
  | "upload-started"
  | "upload-confirmed"
  | "link-confirmed"
  | "upload-expired"
  | "already-present"; // dedupe hit: Hub already holds this (sha256, byteLength) blob

export class AttachmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AttachmentError";
  }
}

/**
 * THE invariant. A blob may be purged from the device only in the fully-synced terminal state with
 * both confirmations. The triple check is deliberate redundancy: state and the two flags must agree.
 */
export function isBlobPurgeable(b: BlobRecord): boolean {
  return b.state === "linked" && b.uploadConfirmed && b.linkConfirmed;
}

const BLOB_TRANSITIONS: Record<BlobLifecycleState, Partial<Record<BlobEvent, BlobLifecycleState>>> =
  {
    "local-only": {
      "upload-started": "uploading",
      "already-present": "uploaded",
    },
    uploading: {
      "upload-confirmed": "uploaded",
      "upload-expired": "upload-expired",
      "already-present": "uploaded",
    },
    uploaded: {
      "link-confirmed": "linked",
    },
    "upload-expired": {
      "upload-started": "uploading",
      "already-present": "uploaded",
    },
    linked: {}, // terminal
  };

/**
 * Advance a blob by one lifecycle event, returning a new record (input never mutated). Throws on an
 * illegal transition. Sets `uploadConfirmed`/`linkConfirmed` as the corresponding confirmations land
 * — these flags are monotonic (once true, never cleared), so an expired re-upload of an
 * already-confirmed blob keeps its confirmation.
 */
export function advanceBlob(record: BlobRecord, event: BlobEvent): BlobRecord {
  const next = BLOB_TRANSITIONS[record.state][event];
  if (next === undefined) {
    throw new AttachmentError(`illegal blob transition: ${record.state} --${event}-->`);
  }
  const uploadConfirmed =
    record.uploadConfirmed || event === "upload-confirmed" || event === "already-present";
  const linkConfirmed = record.linkConfirmed || event === "link-confirmed";
  return { ...record, state: next, uploadConfirmed, linkConfirmed };
}

/**
 * Guard the second phase: an attachment link may only be submitted once the blob is durably
 * uploaded (you cannot link bytes Hub does not yet have). Throws otherwise.
 */
export function assertLinkAllowed(record: BlobRecord): void {
  if (!record.uploadConfirmed || (record.state !== "uploaded" && record.state !== "linked")) {
    throw new AttachmentError(
      `cannot link blob ${record.blobId} before its upload is confirmed (state=${record.state})`,
    );
  }
}

/** The blobs that are safe to purge from device storage right now. */
export function purgeableBlobs(records: readonly BlobRecord[]): BlobRecord[] {
  return records.filter(isBlobPurgeable);
}
