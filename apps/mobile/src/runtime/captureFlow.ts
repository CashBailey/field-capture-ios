/**
 * Photo/signature capture flow — the capture/import abstraction in front of the upload engine.
 * One path for all four attachment kinds (field-ticket photo, disposal photo, receipt photo,
 * signature) and all three sources (camera, import, signature pad):
 *
 *   bytes → SHA-256 (integrity anchor, computed at capture) → durable local bytes → durable
 *   blob record linked to its parent → UploadEngine drives tus upload + attachment-link.
 *
 * Capture is a FIELD ACTION: locked unless the clock gate is unlocked. Once captured, the bytes
 * are protected by the blob purge invariant (upload + link both Hub-confirmed) regardless of
 * gate or connectivity — capture works fully offline.
 */
import { sync } from '@fieldcapture/contracts';

import { fieldWorkGateLockReason, type BlobUploadRecord, type FieldWorkGate } from '../domain';
import type { RegisterBlobInput, UploadEngine, WriteIdentity } from './uploadEngine';

export type CaptureSource = 'camera' | 'import' | 'signature-pad';

export interface CaptureInput {
  bytes: Uint8Array;
  mimeType: string;
  source: CaptureSource;
  attachmentKind: sync.AttachBlobCommand['attachmentKind'];
  parentType: sync.AttachBlobCommand['parentType'];
  parentId: string;
  /** opId of the parent's own outbox operation — the link command will depend on it. */
  parentOpId?: string;
  /** Stable ids for re-imports; generated when absent. */
  blobId?: string;
  attachmentId?: string;
}

export type CaptureResult =
  | { status: 'captured'; record: BlobUploadRecord; sha256: string }
  | { status: 'locked'; reason: string };

export interface CaptureFlowDeps {
  uploads: Pick<UploadEngine, 'register' | 'get' | 'getByAttachmentId'>;
  /** Persist the raw bytes durably; returns the local URI. (Filesystem adapter in production.) */
  persistBytes: (blobId: string, bytes: Uint8Array) => Promise<string>;
  gateState: () => FieldWorkGate;
  identity: Pick<WriteIdentity, 'generateUuid'>;
}

export class CaptureFlow {
  constructor(private readonly deps: CaptureFlowDeps) {}

  /**
   * Capture one attachment. The SHA-256 is computed HERE, before anything persists — every
   * later integrity check (tus hash verification, Hub-side dedupe) anchors on it. Idempotent on
   * blobId (UploadEngine.register); a duplicate attachmentId bound to a different blob throws.
   */
  async capture(input: CaptureInput): Promise<CaptureResult> {
    const gate = this.deps.gateState();
    if (gate.state === 'locked') return { status: 'locked', reason: fieldWorkGateLockReason(gate) };

    const sha256 = sync.sha256Hex(input.bytes);
    const blobId = input.blobId ?? this.deps.identity.generateUuid();
    const requestedAttachmentId = input.attachmentId;
    const existingBlob = this.deps.uploads.get(blobId);
    if (existingBlob !== undefined) {
      if (existingBlob.sha256 !== sha256 || existingBlob.byteLength !== input.bytes.length) {
        throw new Error(`blobId ${blobId} is already bound to different bytes`);
      }
      if (
        requestedAttachmentId !== undefined &&
        existingBlob.attachmentId !== requestedAttachmentId
      ) {
        throw new Error(
          `blobId ${blobId} is already bound to attachment ${existingBlob.attachmentId}`,
        );
      }
      return { status: 'captured', record: existingBlob, sha256 };
    }
    const attachmentId = requestedAttachmentId ?? this.deps.identity.generateUuid();
    const existingAttachment = this.deps.uploads.getByAttachmentId(attachmentId);
    if (existingAttachment !== undefined) {
      throw new Error(
        `attachmentId ${attachmentId} is already bound to blob ${existingAttachment.blobId}`,
      );
    }
    const localUri = await this.deps.persistBytes(blobId, input.bytes);
    const register: RegisterBlobInput = {
      blobId,
      sha256,
      byteLength: input.bytes.length,
      mimeType: input.mimeType,
      localUri,
      attachmentId,
      parentType: input.parentType,
      parentId: input.parentId,
      attachmentKind: input.attachmentKind,
      ...(input.parentOpId !== undefined ? { parentOpId: input.parentOpId } : {}),
    };
    const record = this.deps.uploads.register(register);
    return { status: 'captured', record, sha256 };
  }

  /** Signature-pad convenience: signatures are serialized-vector bytes with the 'signature' kind. */
  async captureSignature(input: {
    bytes: Uint8Array;
    parentType: sync.AttachBlobCommand['parentType'];
    parentId: string;
    parentOpId?: string;
    attachmentId?: string;
  }): Promise<CaptureResult> {
    return this.capture({
      ...input,
      mimeType: 'application/octet-stream',
      source: 'signature-pad',
      attachmentKind: 'signature',
    });
  }
}
