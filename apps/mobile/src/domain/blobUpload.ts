/**
 * Domain seams for the photo/signature/document upload flow (ADR 004 two-phase attachments).
 * A captured blob is stored durably on the device with its SHA-256, uploaded via a tus-style
 * resumable session, then linked to its parent record by a separate append-only command. The
 * local bytes are purgeable ONLY after Hub confirms BOTH the upload AND the link commit
 * (`sync.isBlobPurgeable`) — anything less stays on the phone.
 *
 * Pure interfaces + volatile test seams. Production: `data/SqliteBlobUploadStore` + a
 * filesystem-backed `BlobBytesSource`.
 */
import { sync } from '@fieldcapture/contracts';

import type { StoreDurability } from './hubGateway';

/** The contracts blob lifecycle record plus capture metadata, session state, and link identity. */
export interface BlobUploadRecord extends sync.BlobRecord {
  mimeType: string;
  /** Where the bytes live on the device (file URI). Opaque to the engine. */
  localUri: string;
  /** Client-generated attachment identity — duplicate registrations are idempotent on this. */
  attachmentId: string;
  parentType: sync.AttachBlobCommand['parentType'];
  parentId: string;
  attachmentKind: sync.AttachBlobCommand['attachmentKind'];
  /** Idempotency key for the upload-session open (dedupe by content hash happens Hub-side). */
  sessionIdempotencyKey: string;
  /** opId of the parent record's own outbox operation — the link command depends on it. */
  parentOpId?: string;
  /** Bytes the server has acknowledged (durable resume point). */
  bytesAcked: number;
  uploadSessionId?: string;
  uploadUrl?: string;
  /** opId of the enqueued attachment-link command, once built. */
  linkOpId?: string;
  /** Set when the local bytes were deleted after full sync (record stays as proof). */
  purgedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface BlobUploadStore {
  readonly durability: StoreDurability;
  save(record: BlobUploadRecord): void;
  get(blobId: string): BlobUploadRecord | undefined;
  getByAttachmentId(attachmentId: string): BlobUploadRecord | undefined;
  list(): BlobUploadRecord[];
  listByState(state: sync.BlobLifecycleState): BlobUploadRecord[];
}

/** In-memory blob store. VOLATILE — TEST SEAM ONLY. */
export class VolatileBlobUploadStore implements BlobUploadStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private byBlobId = new Map<string, BlobUploadRecord>();

  save(record: BlobUploadRecord): void {
    this.byBlobId.set(record.blobId, record);
  }

  get(blobId: string): BlobUploadRecord | undefined {
    return this.byBlobId.get(blobId);
  }

  getByAttachmentId(attachmentId: string): BlobUploadRecord | undefined {
    return this.list().find((r) => r.attachmentId === attachmentId);
  }

  list(): BlobUploadRecord[] {
    return [...this.byBlobId.values()];
  }

  listByState(state: sync.BlobLifecycleState): BlobUploadRecord[] {
    return this.list().filter((r) => r.state === state);
  }
}

/**
 * Seam over the device's blob bytes (photo/signature files). The engine never touches the
 * filesystem directly; tests use an in-memory source. `delete` is called ONLY for purgeable
 * blobs — implementations need no further guard, but must fail loud rather than silently
 * succeed on a missing file.
 */
export interface BlobBytesSource {
  read(localUri: string, offset: number, length: number): Promise<Uint8Array>;
  delete(localUri: string): Promise<void>;
}

/** In-memory bytes source for tests: register a buffer per URI. */
export class VolatileBlobBytesSource implements BlobBytesSource {
  private byUri = new Map<string, Uint8Array>();

  put(localUri: string, bytes: Uint8Array): void {
    this.byUri.set(localUri, bytes);
  }

  has(localUri: string): boolean {
    return this.byUri.has(localUri);
  }

  async read(localUri: string, offset: number, length: number): Promise<Uint8Array> {
    const bytes = this.byUri.get(localUri);
    if (bytes === undefined) throw new Error(`no bytes at ${localUri}`);
    return bytes.slice(offset, offset + length);
  }

  async delete(localUri: string): Promise<void> {
    if (!this.byUri.delete(localUri)) throw new Error(`no bytes to delete at ${localUri}`);
  }
}
