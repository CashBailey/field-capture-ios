// Port of src/data/SqliteBlobUploadStore.ts — Durable `BlobUploadStore` over SQLite: the
// blob/attachment records behind the tus-style upload flow. Rows survive restart with the full
// lifecycle state (`local-only` → `uploading` → `uploaded` → `linked`), both confirmation flags,
// the durable resume point (`bytes_acked`), session identity, and the link command's opId.
// Nothing here deletes the actual bytes — the upload engine purges them only for
// `isBlobPurgeable` records.
import Foundation
import FieldContracts
import FieldDomain

private let COLUMNS =
    "blob_id, sha256, byte_length, mime_type, local_uri, state, upload_confirmed, link_confirmed, "
    + "bytes_acked, upload_session_id, upload_url, attachment_id, parent_type, parent_id, "
    + "attachment_kind, session_idempotency_key, parent_op_id, link_op_id, purged_at, created_at, updated_at"

private func toRowParams(_ r: BlobUploadRecord) -> [SqlValue] {
    [
        .text(r.blobId),
        .text(r.sha256),
        .int(Int64(r.byteLength)),
        .text(r.mimeType),
        .text(r.localUri),
        .text(r.state.rawValue),
        .int(r.uploadConfirmed ? 1 : 0),
        .int(r.linkConfirmed ? 1 : 0),
        .int(Int64(r.bytesAcked)),
        r.uploadSessionId.map(SqlValue.text) ?? .null,
        r.uploadUrl.map(SqlValue.text) ?? .null,
        .text(r.attachmentId),
        .text(r.parentType.rawValue),
        .text(r.parentId),
        .text(r.attachmentKind.rawValue),
        .text(r.sessionIdempotencyKey),
        r.parentOpId.map(SqlValue.text) ?? .null,
        r.linkOpId.map(SqlValue.text) ?? .null,
        r.purgedAt.map(SqlValue.text) ?? .null,
        .text(r.createdAt),
        .text(r.updatedAt),
    ]
}

public enum SqliteBlobUploadStoreError: Error, Equatable, Sendable, CustomStringConvertible,
    LocalizedError
{
    case corruptRecord(blobId: String, detail: String)

    public var description: String {
        switch self {
        case .corruptRecord(let blobId, let detail):
            return "blob upload \(blobId) is corrupt: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

private func corruptBlob(_ blobId: String, _ detail: String) -> SqliteBlobUploadStoreError {
    .corruptRecord(blobId: blobId, detail: detail)
}

private func requiredString(_ row: SqlRow, _ column: String, blobId: String) throws -> String {
    guard let value = row.string(column), !value.isEmpty else {
        throw corruptBlob(blobId, "missing or invalid \(column)")
    }
    return value
}

private func optionalString(_ row: SqlRow, _ column: String, blobId: String) throws -> String? {
    switch row[column] {
    case .text(let value)?: return value
    case .null?: return nil
    default: throw corruptBlob(blobId, "invalid \(column)")
    }
}

private func requiredInt(_ row: SqlRow, _ column: String, blobId: String) throws -> Int {
    guard case .int(let value)? = row[column], let converted = Int(exactly: value) else {
        throw corruptBlob(blobId, "missing or invalid \(column)")
    }
    return converted
}

private func requiredBool(_ row: SqlRow, _ column: String, blobId: String) throws -> Bool {
    guard case .int(let value)? = row[column], value == 0 || value == 1 else {
        throw corruptBlob(blobId, "missing or invalid \(column)")
    }
    return value == 1
}

private func fromRow(_ row: SqlRow) throws -> BlobUploadRecord {
    let blobId = row.string("blob_id") ?? "<unknown>"
    let stateRaw = try requiredString(row, "state", blobId: blobId)
    guard let state = BlobLifecycleState(rawValue: stateRaw) else {
        throw corruptBlob(blobId, "unknown state '\(stateRaw)'")
    }
    let parentTypeRaw = try requiredString(row, "parent_type", blobId: blobId)
    guard let parentType = AttachBlobParentType(rawValue: parentTypeRaw) else {
        throw corruptBlob(blobId, "unknown parent_type '\(parentTypeRaw)'")
    }
    let attachmentKindRaw = try requiredString(row, "attachment_kind", blobId: blobId)
    guard let attachmentKind = AttachBlobKind(rawValue: attachmentKindRaw) else {
        throw corruptBlob(blobId, "unknown attachment_kind '\(attachmentKindRaw)'")
    }

    let byteLength = try requiredInt(row, "byte_length", blobId: blobId)
    let bytesAcked = try requiredInt(row, "bytes_acked", blobId: blobId)
    guard byteLength >= 0 else { throw corruptBlob(blobId, "byte_length cannot be negative") }
    guard (0...byteLength).contains(bytesAcked) else {
        throw corruptBlob(blobId, "bytes_acked must be between zero and byte_length")
    }

    let uploadConfirmed = try requiredBool(row, "upload_confirmed", blobId: blobId)
    let linkConfirmed = try requiredBool(row, "link_confirmed", blobId: blobId)
    guard !linkConfirmed || uploadConfirmed else {
        throw corruptBlob(blobId, "link_confirmed requires upload_confirmed")
    }
    switch state {
    case .localOnly, .uploading, .uploadExpired:
        guard !uploadConfirmed, !linkConfirmed else {
            throw corruptBlob(blobId, "state \(state.rawValue) cannot contain confirmation flags")
        }
    case .uploaded:
        guard uploadConfirmed, !linkConfirmed else {
            throw corruptBlob(blobId, "uploaded state requires only upload confirmation")
        }
    case .linked:
        guard uploadConfirmed, linkConfirmed else {
            throw corruptBlob(blobId, "linked state requires both confirmations")
        }
    }

    return BlobUploadRecord(
        blobId: try requiredString(row, "blob_id", blobId: blobId),
        sha256: try requiredString(row, "sha256", blobId: blobId),
        byteLength: byteLength,
        state: state,
        uploadConfirmed: uploadConfirmed,
        linkConfirmed: linkConfirmed,
        mimeType: try requiredString(row, "mime_type", blobId: blobId),
        localUri: try requiredString(row, "local_uri", blobId: blobId),
        attachmentId: try requiredString(row, "attachment_id", blobId: blobId),
        parentType: parentType,
        parentId: try requiredString(row, "parent_id", blobId: blobId),
        attachmentKind: attachmentKind,
        sessionIdempotencyKey: try requiredString(
            row, "session_idempotency_key", blobId: blobId),
        parentOpId: try optionalString(row, "parent_op_id", blobId: blobId),
        bytesAcked: bytesAcked,
        uploadSessionId: try optionalString(row, "upload_session_id", blobId: blobId),
        uploadUrl: try optionalString(row, "upload_url", blobId: blobId),
        linkOpId: try optionalString(row, "link_op_id", blobId: blobId),
        purgedAt: try optionalString(row, "purged_at", blobId: blobId),
        createdAt: try requiredString(row, "created_at", blobId: blobId),
        updatedAt: try requiredString(row, "updated_at", blobId: blobId)
    )
}

public final class SqliteBlobUploadStore: BlobUploadStore {
    private let db: SqlDriver
    public let durability: StoreDurability

    public init(_ db: SqlDriver, _ durability: StoreDurability) {
        self.db = db
        self.durability = durability
    }

    public func save(_ record: BlobUploadRecord) throws {
        try db.run(
            "INSERT OR REPLACE INTO blob_records (\(COLUMNS)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            toRowParams(record))
    }

    public func get(_ blobId: String) throws -> BlobUploadRecord? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM blob_records WHERE blob_id = ?", [.text(blobId)])
        else { return nil }
        return try fromRow(row)
    }

    public func getByAttachmentId(_ attachmentId: String) throws -> BlobUploadRecord? {
        guard
            let row = try db.first(
                "SELECT \(COLUMNS) FROM blob_records WHERE attachment_id = ?", [.text(attachmentId)])
        else { return nil }
        return try fromRow(row)
    }

    public func list() throws -> [BlobUploadRecord] {
        try db.all("SELECT \(COLUMNS) FROM blob_records ORDER BY created_at, blob_id").map(fromRow)
    }

    public func listByState(_ state: BlobLifecycleState) throws -> [BlobUploadRecord] {
        try db.all(
            "SELECT \(COLUMNS) FROM blob_records WHERE state = ? ORDER BY created_at, blob_id",
            [.text(state.rawValue)]
        ).map(fromRow)
    }

    public func listReadyToPurge() throws -> [BlobUploadRecord] {
        try db.all(
            """
            SELECT \(COLUMNS)
            FROM blob_records
            WHERE purged_at IS NULL
              AND state = 'linked'
              AND upload_confirmed = 1
              AND link_confirmed = 1
            ORDER BY created_at, blob_id
            """
        ).map(fromRow)
    }
}
