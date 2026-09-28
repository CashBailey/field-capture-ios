/**
 * Durable `BlobUploadStore` over SQLite — the blob/attachment records behind the tus-style
 * upload flow. Rows survive restart with the full lifecycle state (`local-only` → `uploading` →
 * `uploaded` → `linked`), both confirmation flags, the durable resume point (`bytes_acked`),
 * session identity, and the link command's opId. Nothing here deletes the actual bytes — the
 * upload engine purges them only for `isBlobPurgeable` records.
 */
import type { sync } from '@fieldcapture/contracts';

import type { BlobUploadRecord, BlobUploadStore, StoreDurability } from '../domain';
import type { SqlDriver, SqlValue } from './sqlDriver';

interface BlobRow extends Record<string, unknown> {
  blob_id: string;
  sha256: string;
  byte_length: number;
  mime_type: string;
  local_uri: string;
  state: string;
  upload_confirmed: number;
  link_confirmed: number;
  bytes_acked: number;
  upload_session_id: string | null;
  upload_url: string | null;
  attachment_id: string;
  parent_type: string;
  parent_id: string;
  attachment_kind: string;
  session_idempotency_key: string;
  parent_op_id: string | null;
  link_op_id: string | null;
  purged_at: string | null;
  created_at: string;
  updated_at: string;
}

const COLUMNS =
  'blob_id, sha256, byte_length, mime_type, local_uri, state, upload_confirmed, link_confirmed, ' +
  'bytes_acked, upload_session_id, upload_url, attachment_id, parent_type, parent_id, ' +
  'attachment_kind, session_idempotency_key, parent_op_id, link_op_id, purged_at, created_at, updated_at';

function toRowParams(r: BlobUploadRecord): SqlValue[] {
  return [
    r.blobId,
    r.sha256,
    r.byteLength,
    r.mimeType,
    r.localUri,
    r.state,
    r.uploadConfirmed ? 1 : 0,
    r.linkConfirmed ? 1 : 0,
    r.bytesAcked,
    r.uploadSessionId ?? null,
    r.uploadUrl ?? null,
    r.attachmentId,
    r.parentType,
    r.parentId,
    r.attachmentKind,
    r.sessionIdempotencyKey,
    r.parentOpId ?? null,
    r.linkOpId ?? null,
    r.purgedAt ?? null,
    r.createdAt,
    r.updatedAt,
  ];
}

function fromRow(row: BlobRow): BlobUploadRecord {
  return {
    blobId: row.blob_id,
    sha256: row.sha256,
    byteLength: row.byte_length,
    mimeType: row.mime_type,
    localUri: row.local_uri,
    state: row.state as sync.BlobLifecycleState,
    uploadConfirmed: row.upload_confirmed === 1,
    linkConfirmed: row.link_confirmed === 1,
    bytesAcked: row.bytes_acked,
    attachmentId: row.attachment_id,
    parentType: row.parent_type as BlobUploadRecord['parentType'],
    parentId: row.parent_id,
    attachmentKind: row.attachment_kind as BlobUploadRecord['attachmentKind'],
    sessionIdempotencyKey: row.session_idempotency_key,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.upload_session_id !== null ? { uploadSessionId: row.upload_session_id } : {}),
    ...(row.upload_url !== null ? { uploadUrl: row.upload_url } : {}),
    ...(row.parent_op_id !== null ? { parentOpId: row.parent_op_id } : {}),
    ...(row.link_op_id !== null ? { linkOpId: row.link_op_id } : {}),
    ...(row.purged_at !== null ? { purgedAt: row.purged_at } : {}),
  };
}

export class SqliteBlobUploadStore implements BlobUploadStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(record: BlobUploadRecord): void {
    this.db.run(
      `INSERT OR REPLACE INTO blob_records (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      toRowParams(record),
    );
  }

  get(blobId: string): BlobUploadRecord | undefined {
    const row = this.db.first<BlobRow>(`SELECT ${COLUMNS} FROM blob_records WHERE blob_id = ?`, [
      blobId,
    ]);
    return row === null ? undefined : fromRow(row);
  }

  getByAttachmentId(attachmentId: string): BlobUploadRecord | undefined {
    const row = this.db.first<BlobRow>(
      `SELECT ${COLUMNS} FROM blob_records WHERE attachment_id = ?`,
      [attachmentId],
    );
    return row === null ? undefined : fromRow(row);
  }

  list(): BlobUploadRecord[] {
    return this.db
      .all<BlobRow>(`SELECT ${COLUMNS} FROM blob_records ORDER BY created_at, blob_id`)
      .map(fromRow);
  }

  listByState(state: sync.BlobLifecycleState): BlobUploadRecord[] {
    return this.db
      .all<BlobRow>(
        `SELECT ${COLUMNS} FROM blob_records WHERE state = ? ORDER BY created_at, blob_id`,
        [state],
      )
      .map(fromRow);
  }
}
