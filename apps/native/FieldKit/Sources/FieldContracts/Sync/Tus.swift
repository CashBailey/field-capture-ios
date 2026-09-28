// Port of sync/tus.ts — Pure tus-style resumable-upload protocol logic (ADR 004). No I/O — an
// engine slice drives a real HTTP client from these decisions. Three concerns live here:
//
//   1. Chunk planning: which byte range to send next, given how many bytes the server has
//      acknowledged.
//   2. Offset reconciliation on resume: the SERVER's offset is the truth (HEAD `Upload-Offset`);
//      local bookkeeping adjusts to it — except an offset beyond the blob's length, which means
//      the session is corrupt and must fail loud.
//   3. Whole-file hash verification: an upload is "confirmed" ONLY when the server-computed
//      sha256 matches the local one recorded at capture time (cross-cutting invariant #2 — never
//      mark work durable on a guess).

public struct UploadProtocolError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// The next byte range to PATCH, or `.complete` when every byte is acknowledged.
public enum ChunkPlan: Equatable, Sendable {
    case chunk(offset: Int, length: Int)
    case complete
}

/**
 * Plan the next chunk after `bytesAcked` acknowledged bytes of a `byteLength`-byte blob. The
 * final chunk is naturally partial. `bytesAcked > byteLength` is corrupt local bookkeeping —
 * fail loud, never silently clamp.
 *
 * ponytail: TS also asserts `Number.isInteger` on every count here; all three params are Swift
 * `Int`, so only the non-negativity/positivity halves are meaningful (kept below) — the
 * corresponding "fractional input" sub-case of the ported test is dropped as unreachable.
 */
public func planNextChunk(_ bytesAcked: Int, _ byteLength: Int, _ chunkSizeBytes: Int) throws -> ChunkPlan {
    guard bytesAcked >= 0 else {
        throw UploadProtocolError("bytesAcked must be a non-negative integer (got \(bytesAcked))")
    }
    guard byteLength >= 0 else {
        throw UploadProtocolError("byteLength must be a non-negative integer (got \(byteLength))")
    }
    guard chunkSizeBytes > 0 else {
        throw UploadProtocolError("chunkSizeBytes must be a positive integer (got \(chunkSizeBytes))")
    }
    guard bytesAcked <= byteLength else {
        throw UploadProtocolError(
            "bytesAcked (\(bytesAcked)) exceeds the blob length (\(byteLength)) — session state is corrupt"
        )
    }
    if bytesAcked == byteLength { return .complete }
    return .chunk(offset: bytesAcked, length: min(chunkSizeBytes, byteLength - bytesAcked))
}

/**
 * Reconcile local bookkeeping with the server-reported offset on resume. The server defines how
 * many bytes it durably holds — ahead OR behind local state, its answer wins. An offset beyond
 * the blob's length can never be honest; throw instead of "resuming" a corrupt session.
 */
public func reconcileOffset(_ localBytesAcked: Int, _ serverOffset: Int, _ byteLength: Int) throws -> Int {
    guard localBytesAcked >= 0 else {
        throw UploadProtocolError("localBytesAcked must be a non-negative integer (got \(localBytesAcked))")
    }
    guard serverOffset >= 0 else {
        throw UploadProtocolError("serverOffset must be a non-negative integer (got \(serverOffset))")
    }
    guard byteLength >= 0 else {
        throw UploadProtocolError("byteLength must be a non-negative integer (got \(byteLength))")
    }
    guard serverOffset <= byteLength else {
        throw UploadProtocolError(
            "server offset (\(serverOffset)) exceeds the blob length (\(byteLength)) — refuse to resume"
        )
    }
    return serverOffset
}

/**
 * Whole-file integrity gate. True ONLY when the server reported a non-empty sha256 equal
 * (case-insensitively) to the local hash. Absent/empty server hash = not verified — the upload
 * must not be confirmed. An empty LOCAL hash is the caller's bug: without its own integrity
 * anchor nothing can ever verify, so fail loud.
 */
public func verifyUploadHash(_ localSha256: String, _ serverSha256: String?) throws -> Bool {
    guard !localSha256.isEmpty else {
        throw UploadProtocolError("local sha256 is empty — the blob has no integrity anchor")
    }
    guard let serverSha256, !serverSha256.isEmpty else { return false }
    return localSha256.lowercased() == serverSha256.lowercased()
}
