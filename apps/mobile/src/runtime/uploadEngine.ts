/**
 * Photo/signature/document upload engine (ADR 004 two-phase attachments) driving the contracts
 * blob state machine from real transport events:
 *
 *   register → local-only ─open session─→ uploading ─chunks─→ uploaded ─link commit─→ linked
 *                  │                          │ session expired / hash mismatch
 *                  └──────── already-present ─┴→ upload-expired (bytes kept, restart later)
 *
 * Invariants (cross-cutting #2):
 *  - The local bytes are purgeable ONLY when `sync.isBlobPurgeable` holds — Hub confirmed BOTH
 *    the whole-file upload (sha256 verified) AND the attachment-link command commit.
 *  - Progress is durable: `bytesAcked` persists after EVERY chunk, so an interrupted upload
 *    resumes from the server's offset instead of restarting.
 *  - A hash mismatch NEVER confirms the upload: the session is abandoned (`upload-expired`),
 *    the local bytes stay, and a fresh session restarts from them.
 *  - The link command goes through the durable sync outbox with its own idempotency key; a
 *    rejected/needs-review link leaves the blob preserved on-device and visible for review.
 */
import { sync } from '@fieldcapture/contracts';

import { HubAuthError } from '../domain';
import type { BlobBytesSource, BlobUploadRecord, BlobUploadStore } from '../domain';
import {
  TusHashMismatchError,
  TusSessionGoneError,
  type TusPatchResult,
  type TusUploadClient,
} from '../adapters/sync/TusUploadClient';

/** Write-identity allocator seam (DeviceIdentity in production; fakes in tests). */
export interface WriteIdentity {
  deviceInstanceId: string;
  allocateLocalSeq(): number;
  generateUuid(): string;
}

export interface RegisterBlobInput {
  blobId: string;
  sha256: string;
  byteLength: number;
  mimeType: string;
  localUri: string;
  attachmentId: string;
  parentType: sync.AttachBlobCommand['parentType'];
  parentId: string;
  attachmentKind: sync.AttachBlobCommand['attachmentKind'];
  /** opId of the parent's own outbox operation, when the link must commit after it. */
  parentOpId?: string;
}

export interface UploadSweepReport {
  /** Blobs whose upload completed (hash verified) this pass. */
  uploaded: number;
  /** Blobs deduped server-side (content already present). */
  dedupedAlreadyPresent: number;
  /** Attachment-link commands enqueued this pass. */
  linksEnqueued: number;
  /** Blobs advanced to fully-linked this pass. */
  linked: number;
  /** Blobs whose session died or hash mismatched — bytes kept, will restart. */
  expired: number;
  /** Blobs left untouched on a transient failure — bytes and state kept, retry later. */
  deferred: number;
  /** True when a 401/403 (HubAuthError) surfaced this pass — items deferred and due the moment a
   *  fresh token exists; a driver should PAUSE rather than hammer the Hub with a dead token. */
  authRequired: boolean;
}

export interface UploadEngineDeps {
  blobs: BlobUploadStore;
  bytes: BlobBytesSource;
  transport: Pick<sync.SyncTransport, 'openUploadSession'>;
  tus: Pick<TusUploadClient, 'probe' | 'uploadChunk'>;
  /** Enqueue the attachment-link command into the durable sync outbox (SyncEngine.enqueue). */
  enqueueLink: (envelope: sync.OperationEnvelope<sync.AttachBlobCommand>) => void;
  /** Outbox state of a previously-enqueued link op (SyncOutboxStore.get(...).state). */
  linkState: (opId: string) => sync.OutboxItemState | undefined;
  /** Fired when a NEW blob is registered — lets a runtime driver kick an immediate upload pass. */
  onRegister?: () => void;
  identity: WriteIdentity;
  chunkSizeBytes?: number;
  now?: () => Date;
  onError?: (blobId: string, error: unknown) => void;
}

const DEFAULT_CHUNK_SIZE = 256 * 1024;

export class UploadEngine {
  private readonly chunkSize: number;
  private readonly now: () => Date;

  constructor(private readonly deps: UploadEngineDeps) {
    this.chunkSize = deps.chunkSizeBytes ?? DEFAULT_CHUNK_SIZE;
    this.now = deps.now ?? (() => new Date());
  }

  get(blobId: string): BlobUploadRecord | undefined {
    return this.deps.blobs.get(blobId);
  }

  getByAttachmentId(attachmentId: string): BlobUploadRecord | undefined {
    return this.deps.blobs.getByAttachmentId(attachmentId);
  }

  /**
   * Record a captured blob durably. Idempotent on blobId AND attachmentId: re-registering the
   * same capture returns the existing record; a different blob under an existing attachmentId
   * throws (duplicate attachment identity must never silently fork).
   */
  register(input: RegisterBlobInput): BlobUploadRecord {
    const existingBlob = this.deps.blobs.get(input.blobId);
    if (existingBlob !== undefined) return existingBlob;
    const existingAttachment = this.deps.blobs.getByAttachmentId(input.attachmentId);
    if (existingAttachment !== undefined) {
      throw new Error(
        `attachmentId ${input.attachmentId} is already bound to blob ${existingAttachment.blobId}`,
      );
    }
    const seq = this.deps.identity.allocateLocalSeq();
    const at = this.now().toISOString();
    const record: BlobUploadRecord = {
      blobId: input.blobId,
      sha256: input.sha256,
      byteLength: input.byteLength,
      mimeType: input.mimeType,
      localUri: input.localUri,
      attachmentId: input.attachmentId,
      parentType: input.parentType,
      parentId: input.parentId,
      attachmentKind: input.attachmentKind,
      state: 'local-only',
      uploadConfirmed: false,
      linkConfirmed: false,
      bytesAcked: 0,
      sessionIdempotencyKey: sync.buildIdempotencyKey(
        this.deps.identity.deviceInstanceId,
        seq,
        this.deps.identity.generateUuid(),
      ),
      ...(input.parentOpId !== undefined ? { parentOpId: input.parentOpId } : {}),
      createdAt: at,
      updatedAt: at,
    };
    this.deps.blobs.save(record);
    // Kick a runtime driver (if any) to upload the fresh blob promptly. The producer (CaptureFlow)
    // persists the bytes BEFORE register, so the kicked sweep finds them; even if a future caller
    // raced ahead, a missing-bytes read just defers and retries — work is never lost.
    this.deps.onRegister?.();
    return record;
  }

  /** Drive every non-terminal blob one step forward. Transient failures defer; nothing is lost. */
  async processOnce(): Promise<UploadSweepReport> {
    const report: UploadSweepReport = {
      uploaded: 0,
      dedupedAlreadyPresent: 0,
      linksEnqueued: 0,
      linked: 0,
      expired: 0,
      deferred: 0,
      authRequired: false,
    };
    for (const record of this.deps.blobs.list()) {
      try {
        await this.processBlob(record, report);
      } catch (error) {
        // One bad blob must never kill the sweep for the healthy blobs behind it.
        if (error instanceof HubAuthError) report.authRequired = true;
        report.deferred += 1;
        this.deps.onError?.(record.blobId, error);
      }
    }
    return report;
  }

  private async processBlob(record: BlobUploadRecord, report: UploadSweepReport): Promise<void> {
    let current = record;
    if (current.state === 'local-only' || current.state === 'upload-expired') {
      const opened = await this.openSession(current, report);
      if (opened === undefined) return; // deferred on transient failure
      current = opened;
    }
    if (current.state === 'uploading') {
      const advanced = await this.uploadRemaining(current, report);
      if (advanced === undefined) return;
      current = advanced;
    }
    if (current.state === 'uploaded') {
      current = this.ensureLinkEnqueued(current, report);
      this.reconcileLink(current, report);
    }
  }

  private async openSession(
    record: BlobUploadRecord,
    report: UploadSweepReport,
  ): Promise<BlobUploadRecord | undefined> {
    let response: sync.UploadSessionResponse;
    try {
      response = await this.deps.transport.openUploadSession({
        blobId: record.blobId,
        sha256: record.sha256,
        byteLength: record.byteLength,
        mimeType: record.mimeType,
        idempotencyKey: record.sessionIdempotencyKey,
      });
    } catch (error) {
      if (error instanceof HubAuthError) report.authRequired = true;
      report.deferred += 1;
      this.deps.onError?.(record.blobId, error);
      return undefined;
    }
    if (response.result === 'already-present') {
      // Hub already holds these exact bytes (content-hash dedupe) — durably uploaded.
      const next = this.stamp({
        ...sync.advanceBlob(record, 'already-present'),
        bytesAcked: record.byteLength,
      } as BlobUploadRecord);
      this.deps.blobs.save(next);
      report.dedupedAlreadyPresent += 1;
      return next;
    }
    const next = this.stamp({
      ...sync.advanceBlob(record, 'upload-started'),
      uploadSessionId: response.uploadSessionId,
      uploadUrl: response.uploadUrl,
      bytesAcked: 0,
    } as BlobUploadRecord);
    this.deps.blobs.save(next);
    return next;
  }

  private async uploadRemaining(
    record: BlobUploadRecord,
    report: UploadSweepReport,
  ): Promise<BlobUploadRecord | undefined> {
    if (record.uploadUrl === undefined) {
      // Session identity lost (corrupt row) — abandon the session, keep the bytes, restart.
      return void this.expire(record, report, 'uploading row has no uploadUrl');
    }
    let current = record;
    let lastResult: TusPatchResult | undefined;
    try {
      // The server's offset is the truth on resume — local bookkeeping adjusts to it.
      const probed = await this.deps.tus.probe(current.uploadUrl as string);
      const offset = sync.reconcileOffset(current.bytesAcked, probed.offset, current.byteLength);
      if (probed.sha256 !== undefined) lastResult = { offset, sha256: probed.sha256 };
      current = this.stamp({ ...current, bytesAcked: offset });
      this.deps.blobs.save(current);

      for (;;) {
        const plan = sync.planNextChunk(current.bytesAcked, current.byteLength, this.chunkSize);
        if (plan === 'complete') break;
        const chunk = await this.deps.bytes.read(current.localUri, plan.offset, plan.length);
        lastResult = await this.deps.tus.uploadChunk(
          current.uploadUrl as string,
          plan.offset,
          chunk,
        );
        // Persist the server-acknowledged offset after EVERY chunk — durable resume point.
        current = this.stamp({
          ...current,
          bytesAcked: sync.reconcileOffset(
            current.bytesAcked,
            lastResult.offset,
            current.byteLength,
          ),
        });
        this.deps.blobs.save(current);
      }
    } catch (error) {
      if (error instanceof TusSessionGoneError) {
        return void this.expire(current, report, String(error));
      }
      if (error instanceof TusHashMismatchError) {
        // The Hub holds bytes that don't match our declared hash — re-sending can't fix it.
        // Restart the blob clean from the durable local copy (which was never purged).
        return void this.expire(current, report, String(error));
      }
      // Everything else (incl. TusOffsetConflictError) is transient: the next sweep re-probes
      // (HEAD) for the server's true offset and resumes from bytesAcked. Bytes are never lost.
      if (error instanceof HubAuthError) report.authRequired = true;
      report.deferred += 1;
      this.deps.onError?.(current.blobId, error);
      return undefined;
    }

    if (!sync.verifyUploadHash(current.sha256, lastResult?.sha256)) {
      // The server holds DIFFERENT bytes than we captured. Never confirm; restart clean.
      return void this.expire(
        current,
        report,
        `upload hash mismatch (local ${current.sha256}, server ${lastResult?.sha256 ?? 'none'})`,
      );
    }
    const next = this.stamp(sync.advanceBlob(current, 'upload-confirmed') as BlobUploadRecord);
    this.deps.blobs.save(next);
    report.uploaded += 1;
    return next;
  }

  private ensureLinkEnqueued(
    record: BlobUploadRecord,
    report: UploadSweepReport,
  ): BlobUploadRecord {
    if (record.linkOpId !== undefined) return record;
    sync.assertLinkAllowed(record); // cannot link bytes Hub does not yet have
    const opId = this.deps.identity.generateUuid();
    const seq = this.deps.identity.allocateLocalSeq();
    const envelope: sync.OperationEnvelope<sync.AttachBlobCommand> = {
      opId,
      kind: 'command',
      type: 'attachment.link',
      idempotencyKey: sync.buildIdempotencyKey(this.deps.identity.deviceInstanceId, seq, opId),
      localSeq: seq,
      dependsOn: record.parentOpId !== undefined ? [record.parentOpId] : [],
      payload: {
        attachmentId: record.attachmentId,
        blobId: record.blobId,
        parentType: record.parentType,
        parentId: record.parentId,
        attachmentKind: record.attachmentKind,
        idempotencyKey: sync.buildIdempotencyKey(this.deps.identity.deviceInstanceId, seq, opId),
      },
    };
    this.deps.enqueueLink(envelope);
    const next = this.stamp({ ...record, linkOpId: opId });
    this.deps.blobs.save(next);
    report.linksEnqueued += 1;
    return next;
  }

  private reconcileLink(record: BlobUploadRecord, report: UploadSweepReport): void {
    if (record.linkOpId === undefined || record.state !== 'uploaded') return;
    const state = this.deps.linkState(record.linkOpId);
    if (state === 'accepted') {
      const next = this.stamp(sync.advanceBlob(record, 'link-confirmed') as BlobUploadRecord);
      this.deps.blobs.save(next);
      report.linked += 1;
    }
    // rejected / needs-review / pending / in-flight: the blob stays 'uploaded' with its bytes —
    // preserved on-device, never purgeable, visible for review alongside the outbox row.
  }

  /** Abandon the current session: bytes and confirmations are kept; a fresh session restarts. */
  private expire(record: BlobUploadRecord, report: UploadSweepReport, reason: string): void {
    const rest = { ...record };
    delete rest.uploadSessionId;
    delete rest.uploadUrl;
    const next = this.stamp({
      ...(sync.advanceBlob(rest as BlobUploadRecord, 'upload-expired') as BlobUploadRecord),
      bytesAcked: 0,
      // Mint a NEW session idempotency key — the abandoned session is dead, so the next openSession
      // must look like a genuinely new session. If the Hub keys upload dedupe on this key (not on
      // content sha256), reusing it could hand back `already-present` for bytes the Hub already
      // garbage-collected; a fresh key is correct under BOTH dedupe strategies (HIGH#3).
      sessionIdempotencyKey: sync.buildIdempotencyKey(
        this.deps.identity.deviceInstanceId,
        this.deps.identity.allocateLocalSeq(),
        this.deps.identity.generateUuid(),
      ),
    });
    this.deps.blobs.save(next);
    report.expired += 1;
    this.deps.onError?.(record.blobId, new Error(reason));
  }

  /**
   * Delete the device bytes of every fully-synced blob (`isBlobPurgeable` — upload AND link
   * confirmed). The record itself stays as proof, stamped with `purgedAt`.
   */
  async purgeOnce(): Promise<string[]> {
    const purged: string[] = [];
    for (const record of this.deps.blobs.list()) {
      if (record.purgedAt !== undefined || !sync.isBlobPurgeable(record)) continue;
      await this.deps.bytes.delete(record.localUri);
      this.deps.blobs.save(this.stamp({ ...record, purgedAt: this.now().toISOString() }));
      purged.push(record.blobId);
    }
    return purged;
  }

  private stamp<T extends BlobUploadRecord>(record: T): T {
    return { ...record, updatedAt: this.now().toISOString() };
  }
}
