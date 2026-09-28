/**
 * Pure tus-style resumable-upload protocol logic (ADR 004). No I/O — an engine slice drives a
 * real HTTP client from these decisions. Three concerns live here:
 *
 *   1. Chunk planning: which byte range to send next, given how many bytes the server has
 *      acknowledged.
 *   2. Offset reconciliation on resume: the SERVER's offset is the truth (HEAD `Upload-Offset`);
 *      local bookkeeping adjusts to it — except an offset beyond the blob's length, which means
 *      the session is corrupt and must fail loud.
 *   3. Whole-file hash verification: an upload is "confirmed" ONLY when the server-computed
 *      sha256 matches the local one recorded at capture time (cross-cutting invariant #2 — never
 *      mark work durable on a guess).
 */

export class UploadProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UploadProtocolError";
  }
}

/** The next byte range to PATCH, or `"complete"` when every byte is acknowledged. */
export type ChunkPlan = { offset: number; length: number } | "complete";

function assertNonNegativeInt(label: string, value: number): void {
  if (!Number.isInteger(value) || value < 0) {
    throw new UploadProtocolError(`${label} must be a non-negative integer (got ${value})`);
  }
}

/**
 * Plan the next chunk after `bytesAcked` acknowledged bytes of a `byteLength`-byte blob. The
 * final chunk is naturally partial. `bytesAcked > byteLength` is corrupt local bookkeeping —
 * fail loud, never silently clamp.
 */
export function planNextChunk(
  bytesAcked: number,
  byteLength: number,
  chunkSizeBytes: number,
): ChunkPlan {
  assertNonNegativeInt("bytesAcked", bytesAcked);
  assertNonNegativeInt("byteLength", byteLength);
  if (!Number.isInteger(chunkSizeBytes) || chunkSizeBytes <= 0) {
    throw new UploadProtocolError(`chunkSizeBytes must be a positive integer (got ${chunkSizeBytes})`);
  }
  if (bytesAcked > byteLength) {
    throw new UploadProtocolError(
      `bytesAcked (${bytesAcked}) exceeds the blob length (${byteLength}) — session state is corrupt`,
    );
  }
  if (bytesAcked === byteLength) return "complete";
  return { offset: bytesAcked, length: Math.min(chunkSizeBytes, byteLength - bytesAcked) };
}

/**
 * Reconcile local bookkeeping with the server-reported offset on resume. The server defines how
 * many bytes it durably holds — ahead OR behind local state, its answer wins. An offset beyond
 * the blob's length can never be honest; throw instead of "resuming" a corrupt session.
 */
export function reconcileOffset(
  localBytesAcked: number,
  serverOffset: number,
  byteLength: number,
): number {
  assertNonNegativeInt("localBytesAcked", localBytesAcked);
  assertNonNegativeInt("serverOffset", serverOffset);
  assertNonNegativeInt("byteLength", byteLength);
  if (serverOffset > byteLength) {
    throw new UploadProtocolError(
      `server offset (${serverOffset}) exceeds the blob length (${byteLength}) — refuse to resume`,
    );
  }
  return serverOffset;
}

/**
 * Whole-file integrity gate. True ONLY when the server reported a non-empty sha256 equal
 * (case-insensitively) to the local hash. Absent/empty server hash = not verified — the upload
 * must not be confirmed. An empty LOCAL hash is the caller's bug: without its own integrity
 * anchor nothing can ever verify, so fail loud.
 */
export function verifyUploadHash(localSha256: string, serverSha256: string | undefined): boolean {
  if (localSha256.length === 0) {
    throw new UploadProtocolError("local sha256 is empty — the blob has no integrity anchor");
  }
  if (serverSha256 === undefined || serverSha256.length === 0) return false;
  return localSha256.toLowerCase() === serverSha256.toLowerCase();
}
