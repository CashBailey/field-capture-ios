// Port of __tests__/sync-stores.test.ts — durable persistence for the full sync engine (migration
// v4): the generic operation outbox, the down-sync frontier, the committed-op ledger, and the
// blob/upload records — all against real SQL (system SQLite, same driver production uses).
import XCTest

@testable import FieldContracts
@testable import FieldData
@testable import FieldDomain

private func makeDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-sync-\(UUID().uuidString).db")
}

private func item(_ opId: String, _ localSeq: Int, state: OutboxItemState = .pending, retryCount: Int = 0)
    -> DurableSyncOutboxItem
{
    DurableSyncOutboxItem(
        envelope: OperationEnvelope<JSONValue>(
            opId: opId, kind: .event, type: "test.op", idempotencyKey: "gtr:devA:\(localSeq):\(opId)",
            localSeq: localSeq, dependsOn: [], payload: .object(["opId": .string(opId)])),
        state: state, retryCount: retryCount, createdAt: "2026-06-10T10:00:00.000Z",
        updatedAt: "2026-06-10T10:00:00.000Z")
}

final class SyncMigrationTests: XCTestCase {
    func testBringsAFreshDatabaseToTheLatestSchemaVersion() throws {
        let db = try makeDriver()
        try migrate(db)
        XCTAssertGreaterThanOrEqual(try currentSchemaVersion(db), 4)
    }

    func testUpgradesAV3DatabaseInPlaceWithoutTouchingExistingEvidence() throws {
        let db = try makeDriver()
        try db.transaction {
            for v in 0..<3 { try db.exec(MIGRATIONS[v]) }
            try db.exec("PRAGMA user_version = 3")
        }
        try db.run(
            "INSERT INTO ticket_evidence (idempotency_key, envelope_json, state, attempts, created_at, updated_at) VALUES ('gtr:d:1:u', '{\"opId\":\"u\"}', 'pending', 0, '2026-01-01', '2026-01-01')"
        )
        try migrate(db)
        XCTAssertGreaterThanOrEqual(try currentSchemaVersion(db), 4)
        XCTAssertEqual(try db.first("SELECT COUNT(*) AS n FROM ticket_evidence")?.int("n"), 1)
        XCTAssertNil(try db.first("SELECT 1 AS ok FROM sync_outbox LIMIT 1"))  // table exists, empty
    }
}

final class SqliteSyncOutboxStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testRoundTripsEveryFieldIncludingCommittedTokenAndBackoffStamp() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        var saved = item("op-1", 1, state: .accepted, retryCount: 3)
        saved.committedToken = ChangeToken(authorityEpoch: 1, commitSeq: 42)
        saved.rejectionCode = "was_cleared"
        saved.lastError = "earlier transient"
        saved.nextAttemptAtMs = 123456
        try store.save(saved)
        XCTAssertEqual(try store.get("op-1"), saved)
    }

    func testListsByStateAndSurfacesCorruptEnvelopesInsteadOfHidingThem() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try store.save(item("op-1", 1))
        try store.save(item("op-2", 2, state: .accepted))
        try db.run("UPDATE sync_outbox SET envelope_json = '{broken' WHERE op_id = 'op-1'")

        XCTAssertEqual(try store.listByState(.accepted).map { $0.envelope.opId }, ["op-2"])
        XCTAssertEqual(try store.list().map { $0.envelope.opId }, ["op-2"])
        XCTAssertEqual(try store.listCorruptOpIds(), ["op-1"])
    }

    func testQuarantinesMissingInvalidAndMismatchedRequiredValues() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try store.save(item("op-1", 1))
        try store.save(item("op-2", 2))
        try store.save(item("op-3", 3))
        try db.run("UPDATE sync_outbox SET retry_count = -1 WHERE op_id = 'op-1'")
        try db.run("UPDATE sync_outbox SET created_at = '' WHERE op_id = 'op-2'")
        try db.run("UPDATE sync_outbox SET idempotency_key = 'mismatch' WHERE op_id = 'op-3'")

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(Set(try store.listCorruptOpIds()), ["op-1", "op-2", "op-3"])
    }

    func testPruneAcceptedToLedgerMovesAcceptedRowsRefusesEverythingElse() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try store.save(item("op-1", 1, state: .accepted))
        try store.save(item("op-2", 2, state: .pending))

        try store.pruneAcceptedToLedger("op-1", "2026-06-10T12:00:00Z")
        XCTAssertNil(try store.get("op-1"))
        XCTAssertEqual(try store.committedOpIds(), ["op-1"])

        XCTAssertThrowsError(try store.pruneAcceptedToLedger("op-2", "2026-06-10T12:00:00Z")) { error in
            XCTAssertTrue((error as? SqlError)?.message.contains("only 'accepted' may be pruned") ?? false)
        }
        XCTAssertNotNil(try store.get("op-2"))
    }

    func testStorageErrorsThrowInsteadOfCrashingOrReturningEmptyResults() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        db.close()

        XCTAssertThrowsError(try store.save(item("op-1", 1)))
        XCTAssertThrowsError(try store.saveAll([item("op-1", 1)]))
        XCTAssertThrowsError(try store.get("op-1"))
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.listByState(.pending))
        XCTAssertThrowsError(try store.committedOpIds())
        XCTAssertThrowsError(try store.listCorruptOpIds())
    }

    func testSaveAllRollsBackTheEntireBatchWhenOneRowFails() throws {
        let store = SqliteSyncOutboxStore(db, .durablePlain)
        try db.exec(
            """
            CREATE TRIGGER reject_second_sync_outbox_row
            BEFORE INSERT ON sync_outbox
            WHEN NEW.op_id = 'op-2'
            BEGIN
              SELECT RAISE(ABORT, 'injected batch failure');
            END;
            """)

        XCTAssertThrowsError(try store.saveAll([item("op-1", 1), item("op-2", 2)]))
        XCTAssertNil(try store.get("op-1"))
        XCTAssertNil(try store.get("op-2"))
    }
}

final class SqliteSyncFrontierStoreTests: XCTestCase {
    func testStartsUndefinedPersistsAndOverwritesTheSingleFrontierRow() throws {
        let db = try makeDriver()
        try migrate(db)
        let store = SqliteSyncFrontierStore(db, .durablePlain)
        XCTAssertNil(store.get())
        store.set(ChangeToken(authorityEpoch: 1, commitSeq: 10))
        XCTAssertEqual(store.get(), ChangeToken(authorityEpoch: 1, commitSeq: 10))
        store.set(ChangeToken(authorityEpoch: 2, commitSeq: 0))
        XCTAssertEqual(store.get(), ChangeToken(authorityEpoch: 2, commitSeq: 0))
    }
}

final class SqliteBlobUploadStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func record(
        blobId: String = "blob-1",
        attachmentId: String = "att-1"
    ) -> BlobUploadRecord {
        BlobUploadRecord(
            blobId: blobId, sha256: "aa11", byteLength: 10, state: .uploading, uploadConfirmed: false,
            linkConfirmed: false, mimeType: "image/jpeg", localUri: "file:///photos/blob-1.jpg",
            attachmentId: attachmentId, parentType: .fieldTicket, parentId: "ft-1",
            attachmentKind: .fieldTicketPhoto,
            sessionIdempotencyKey: "gtr:devA:9:up-1", parentOpId: "op-parent", bytesAcked: 4,
            uploadSessionId: "sess-1", uploadUrl: "http://hub.test/uploads/blob-1", linkOpId: "op-link",
            createdAt: "2026-06-10T10:00:00.000Z", updatedAt: "2026-06-10T10:05:00.000Z")
    }

    func testRoundTripsTheFullRecordIncludingResumePointAndConfirmations() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        let r = record()
        try store.save(r)
        XCTAssertEqual(try store.get("blob-1"), r)

        var updated = r
        updated.state = .linked
        updated.uploadConfirmed = true
        updated.linkConfirmed = true
        updated.purgedAt = "2026-06-11T00:00:00Z"
        try store.save(updated)
        let reread = try XCTUnwrap(store.get("blob-1"))
        XCTAssertEqual(reread.state, .linked)
        XCTAssertEqual(reread.uploadConfirmed, true)
        XCTAssertEqual(reread.linkConfirmed, true)
        XCTAssertTrue(
            isBlobPurgeable(
                BlobRecord(
                    blobId: reread.blobId, sha256: reread.sha256, byteLength: reread.byteLength,
                    state: reread.state, uploadConfirmed: reread.uploadConfirmed,
                    linkConfirmed: reread.linkConfirmed
                )))
    }

    func testLooksUpByAttachmentIdAndListsByState() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        try store.save(record())
        var second = record()
        second.blobId = "blob-2"
        second.attachmentId = "att-2"
        second.state = .localOnly
        second.bytesAcked = 0
        try store.save(second)
        XCTAssertEqual(try store.getByAttachmentId("att-2")?.blobId, "blob-2")
        XCTAssertEqual(try store.listByState(.uploading).map(\.blobId), ["blob-1"])
    }

    func testCorruptStateParentTypeAndAttachmentKindSurfaceTypedFailures() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        try store.save(record(blobId: "bad-state", attachmentId: "att-state"))
        try store.save(record(blobId: "bad-parent", attachmentId: "att-parent"))
        try store.save(record(blobId: "bad-kind", attachmentId: "att-kind"))
        try store.save(record(blobId: "healthy", attachmentId: "att-healthy"))

        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run(
            "UPDATE blob_records SET state = ? WHERE blob_id = ?",
            [.text("future-state"), .text("bad-state")])
        try db.run(
            "UPDATE blob_records SET parent_type = ? WHERE blob_id = ?",
            [.text("future-parent"), .text("bad-parent")])
        try db.run(
            "UPDATE blob_records SET attachment_kind = ? WHERE blob_id = ?",
            [.text("future-kind"), .text("bad-kind")])

        XCTAssertEqual(try db.first("SELECT COUNT(*) AS count FROM blob_records")?.int("count"), 4)
        XCTAssertEqual(try store.get("healthy")?.blobId, "healthy")
        assertCorrupt(try store.get("bad-state"), id: "bad-state", field: "state")
        assertCorrupt(try store.get("bad-parent"), id: "bad-parent", field: "parent_type")
        assertCorrupt(
            try store.getByAttachmentId("att-kind"), id: "bad-kind", field: "attachment_kind")
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.listByState(.uploading))
    }

    func testInvalidConfirmationAndByteCountsSurfaceTypedFailures() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        try store.save(record(blobId: "bad-confirmation", attachmentId: "att-confirmation"))
        try store.save(record(blobId: "bad-offset", attachmentId: "att-offset"))
        try db.run(
            "UPDATE blob_records SET upload_confirmed = 2 WHERE blob_id = ?",
            [.text("bad-confirmation")])
        try db.run(
            "UPDATE blob_records SET bytes_acked = 11 WHERE blob_id = ?",
            [.text("bad-offset")])

        assertCorrupt(
            try store.get("bad-confirmation"), id: "bad-confirmation", field: "upload_confirmed")
        assertCorrupt(try store.get("bad-offset"), id: "bad-offset", field: "bytes_acked")
    }

    func testListsOnlyUnpurgedFullyConfirmedRecordsReadyForByteDeletion() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        var ready = record(blobId: "ready", attachmentId: "att-ready")
        ready.state = .linked
        ready.uploadConfirmed = true
        ready.linkConfirmed = true
        try store.save(ready)

        var alreadyPurged = ready
        alreadyPurged.blobId = "purged"
        alreadyPurged.attachmentId = "att-purged"
        alreadyPurged.purgedAt = "2026-06-11T00:00:00Z"
        try store.save(alreadyPurged)

        var notLinked = ready
        notLinked.blobId = "uploaded"
        notLinked.attachmentId = "att-uploaded"
        notLinked.state = .uploaded
        notLinked.linkConfirmed = false
        try store.save(notLinked)

        XCTAssertEqual(try store.listReadyToPurge().map(\.blobId), ["ready"])
    }

    func testEverySqlFailureThrowsInsteadOfCrashingOrReturningAnEmptyResult() throws {
        let store = SqliteBlobUploadStore(db, .durablePlain)
        db.close()

        XCTAssertThrowsError(try store.save(record()))
        XCTAssertThrowsError(try store.get("blob-1"))
        XCTAssertThrowsError(try store.getByAttachmentId("att-1"))
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.listByState(.uploading))
        XCTAssertThrowsError(try store.listReadyToPurge())
    }

    private func assertCorrupt<T>(
        _ expression: @autoclosure () throws -> T, id: String, field: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case .corruptRecord(let blobId, let detail) = error as? SqliteBlobUploadStoreError
            else {
                return XCTFail("expected a typed corrupt-record error", file: file, line: line)
            }
            XCTAssertEqual(blobId, id, file: file, line: line)
            XCTAssertTrue(detail.contains(field), file: file, line: line)
        }
    }
}
