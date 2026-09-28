// Port of __tests__/sqlite-stores.test.ts — durable-store slice: the spec's core demand is that
// unsynced work SURVIVES RESTART. These tests run the real store logic against real SQL (system
// SQLite, same engine/driver production uses), including genuine close-and-reopen restart cycles
// on a file database.
import XCTest

@testable import FieldContracts
@testable import FieldData
@testable import FieldDomain

private func makeDriver() throws -> SystemSqliteDriver {
    try SystemSqliteDriver(path: NSTemporaryDirectory() + "fieldkit-stores-\(UUID().uuidString).db")
}

private func assignmentsFixture() -> [HubAssignment] {
    [
        HubAssignment(serviceRequestId: "sr-1", snapshotHash: "h1", snapshot: ["srId": "sr-1", "site": "pad-3"]),
        HubAssignment(serviceRequestId: "sr-2", snapshotHash: "h2", snapshot: nil),
    ]
}

private func makeInput(deviceInstanceId: String = "devA", localSeq: Int = 0) -> FieldTicketInput {
    FieldTicketInput(
        serviceRequestId: "sr-1", snapshotHash: "h1", ticketNo: "T-77", quantityBbl: 80,
        disposalTicketNo: "D-9", deviceInstanceId: deviceInstanceId, localSeq: localSeq, opUuid: "op-1")
}

private struct FakeSubmitter: FieldTicketSubmitter {
    let handler: (HubFieldTicketSubmission) async throws -> HubSubmitOutcome
    func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        try await handler(submission)
    }
}

final class SqliteAssignmentStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testStoresAssignmentsAndReadsThemBackVerbatim() throws {
        let store = SqliteAssignmentStore(db, .durablePlain)
        store.putAssignments(assignmentsFixture())
        let listed = store.listAssignments()
        XCTAssertEqual(listed.map(\.serviceRequestId), ["sr-1", "sr-2"])
        XCTAssertEqual(listed[0].snapshotHash, "h1")
        XCTAssertEqual(listed[0].snapshot as? NSDictionary, ["srId": "sr-1", "site": "pad-3"] as NSDictionary)
        XCTAssertNil(listed[1].snapshot)
        XCTAssertEqual(store.getSnapshotHash("sr-1"), "h1")
        XCTAssertNil(store.getSnapshotHash("sr-unknown"))
    }

    func testPersistsRichAssignmentFieldsPlusLatestServerVersion() throws {
        let details = AssignmentDetails(
            requestNo: "2026-000042", status: .inProgress,
            customer: AssignmentNamedRef(id: "cust-1", name: "ACME Oil"),
            lease: AssignmentNamedRef(id: "lease-1", name: "North Lease"),
            wells: [AssignmentWell(id: "well-12", name: "Well 12H", leaseId: "lease-1")],
            material: "Produced water",
            disposalSite: AssignmentNamedRef(id: "disp-1", name: "SWD 8"),
            vehicle: AssignmentNamedRef(id: "truck-7", name: "Truck 7"),
            trailer: AssignmentNamedRef(id: "trl-3", name: "Trailer 3"),
            jobType: AssignmentNamedRef(id: "jt-1", name: "water-haul"),
            coordinates: AssignmentCoordinates(
                primary: AssignmentGpsPoint(lat: 31.5, lon: -102.1),
                wells: [AssignmentWellCoordinate(lat: 31.5, lon: -102.1, wellId: "well-12")]),
            geofenceHints: AssignmentGeofenceHints(radiusM: 250, required: true),
            workflowRequirements: WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir, .jha])
        )
        let rich = HubAssignment(
            serviceRequestId: "sr-rich", snapshotHash: "hash-rich",
            snapshot: ["srId": "sr-rich", "snapshotCustomer": "legacy"],
            latestServerVersion: "hash-rich", details: details)
        let store = SqliteAssignmentStore(db, .durablePlain)
        store.putAssignments([rich])

        let listed = store.listAssignments()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].details, details)
        XCTAssertEqual(listed[0].latestServerVersion, "hash-rich")

        let row = try db.first(
            "SELECT latest_server_version, rich_json FROM assignments WHERE service_request_id = ?",
            [.text("sr-rich")])
        XCTAssertEqual(row?.string("latest_server_version"), "hash-rich")
    }

    func testWholesaleReplacesTheSetOnEachPull() throws {
        let store = SqliteAssignmentStore(db, .durablePlain)
        let assignments = assignmentsFixture()
        store.putAssignments(assignments)
        store.putAssignments([assignments[1]])
        XCTAssertEqual(store.listAssignments().map(\.serviceRequestId), ["sr-2"])
        XCTAssertNil(store.getSnapshotHash("sr-1"))
    }

    func testDeclaresTheDurabilityItWasConstructedWith() {
        XCTAssertEqual(SqliteAssignmentStore(db, .durableEncrypted).durability, .durableEncrypted)
    }

    func testToleratesADuplicatedSrInOneHubPayload() throws {
        let store = SqliteAssignmentStore(db, .durablePlain)
        store.putAssignments([
            HubAssignment(serviceRequestId: "sr-1", snapshotHash: "h-old", snapshot: nil),
            HubAssignment(serviceRequestId: "sr-1", snapshotHash: "h-new", snapshot: nil),
        ])
        XCTAssertEqual(store.listAssignments().count, 1)
        XCTAssertEqual(store.getSnapshotHash("sr-1"), "h-new")
    }
}

final class SqliteOfflinePolicyStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testStartsWithNoRecordedContact() {
        let state = SqliteOfflinePolicyStore(db, .durablePlain).getState()
        XCTAssertNil(state.lastHubContactAtMs)
        XCTAssertNil(state.windowHours)
    }

    func testRecordsHubContactAndWindowRoundTrip() {
        let store = SqliteOfflinePolicyStore(db, .durablePlain)
        store.recordHubContact(1_000)
        store.setWindowHours(4)
        let state = store.getState()
        XCTAssertEqual(state.lastHubContactAtMs, 1_000)
        XCTAssertEqual(state.windowHours, 4)
    }

    func testRecordHubContactIsMonotonicForward() {
        let store = SqliteOfflinePolicyStore(db, .durablePlain)
        store.recordHubContact(5_000)
        store.recordHubContact(2_000)  // stale/clock-skewed earlier value: ignored
        XCTAssertEqual(store.getState().lastHubContactAtMs, 5_000)
        store.recordHubContact(9_000)  // a genuinely later contact advances it
        XCTAssertEqual(store.getState().lastHubContactAtMs, 9_000)
    }

    func testTheDurableTimestampSurvivesCloseAndReopen() throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-offline-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/offline.db"
        let hour: Int64 = 60 * 60 * 1000
        let contactAt = 100 * hour

        var fileDb: SystemSqliteDriver? = try SystemSqliteDriver(path: file)
        try migrate(fileDb!)
        SqliteOfflinePolicyStore(fileDb!, .durablePlain).recordHubContact(contactAt)
        fileDb!.close()
        fileDb = nil

        let reopenedDb = try SystemSqliteDriver(path: file)
        try migrate(reopenedDb)
        let reopened = SqliteOfflinePolicyStore(reopenedDb, .durablePlain)
        XCTAssertEqual(reopened.getState().lastHubContactAtMs, contactAt)
        let policy = evaluateOfflinePolicy(
            OfflinePolicyInput(lastHubContactAtMs: reopened.getState().lastHubContactAtMs, nowMs: contactAt + 30 * hour)
        )
        XCTAssertEqual(policy.state, .offlineOverLimit)
        reopenedDb.close()
    }
}

final class SqliteReceiptDraftStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func receipt() -> ReceiptDraft {
        ReceiptDraft(
            id: "rcpt-1", serviceRequestId: "sr-1", receiptType: .disposal, vendor: "SWD 8",
            receiptNo: "R-100", amount: 42.5, notes: "half load", ticketDraftId: "draft-9",
            createdAt: "2026-06-15T10:00:00.000Z", updatedAt: "2026-06-15T10:00:00.000Z")
    }

    func testRoundTripsAReceiptDraftIncludingTheOptionalTicketLink() throws {
        let store = SqliteReceiptDraftStore(db, .durablePlain)
        let r = receipt()
        try store.save(r)
        XCTAssertEqual(try store.get("rcpt-1"), r)
        XCTAssertEqual(try store.list(), [r])
    }

    func testOmitsTicketDraftIdWhenThereIsNoLinkedTicket() throws {
        let store = SqliteReceiptDraftStore(db, .durablePlain)
        var noLink = receipt()
        noLink.id = "rcpt-2"
        noLink.ticketDraftId = nil
        try store.save(noLink)
        XCTAssertEqual(try store.get("rcpt-2"), noLink)
        XCTAssertNil(try store.get("rcpt-2")?.ticketDraftId)
    }

    func testUpsertsOnIdAndDeletes() throws {
        let store = SqliteReceiptDraftStore(db, .durablePlain)
        let r = receipt()
        try store.save(r)
        var updated = r
        updated.amount = 99
        try store.save(updated)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.get("rcpt-1")?.amount, 99)
        try store.delete("rcpt-1")
        XCTAssertNil(try store.get("rcpt-1"))
    }

    func testSurvivesCloseAndReopen() throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-receipt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/receipts.db"

        let fileDb = try SystemSqliteDriver(path: file)
        try migrate(fileDb)
        try SqliteReceiptDraftStore(fileDb, .durablePlain).save(receipt())
        fileDb.close()

        let reopenedDb = try SystemSqliteDriver(path: file)
        try migrate(reopenedDb)
        XCTAssertEqual(try SqliteReceiptDraftStore(reopenedDb, .durablePlain).get("rcpt-1"), receipt())
        reopenedDb.close()
    }
}

final class SqliteSyncChangeLedgerTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func change() -> SyncChangeRow {
        SyncChangeRow(
            authorityEpoch: 1, commitSeq: 1, opId: "op-1", entityType: "sync_operation", entityId: "sr-1",
            changeType: "field.note", payload: .object(["note": .string("hi")]),
            createdAt: "2026-06-15T02:56:55.549668")
    }

    func testRecordsAChangeAndRoundTripsIt() throws {
        let ledger = SqliteSyncChangeLedger(db, .durablePlain)
        XCTAssertTrue(try ledger.record(change()))
        XCTAssertTrue(ledger.has(1, 1))
        XCTAssertEqual(ledger.count(), 1)
        XCTAssertEqual(ledger.list(), [change()])
    }

    func testIsIdempotentOnAuthorityEpochCommitSeq() throws {
        let ledger = SqliteSyncChangeLedger(db, .durablePlain)
        XCTAssertTrue(try ledger.record(change()))
        var replay = change()
        replay.payload = .object(["note": .string("replay")])
        XCTAssertFalse(try ledger.record(replay))
        XCTAssertEqual(ledger.count(), 1)
        XCTAssertEqual(ledger.list()[0].payload, .object(["note": .string("hi")]))  // first write wins
    }

    func testRecordedChangesSurviveCloseAndReopen() throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-changes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/changes.db"

        let fileDb = try SystemSqliteDriver(path: file)
        try migrate(fileDb)
        _ = try SqliteSyncChangeLedger(fileDb, .durablePlain).record(change())
        fileDb.close()

        let reopenedDb = try SystemSqliteDriver(path: file)
        try migrate(reopenedDb)
        XCTAssertTrue(SqliteSyncChangeLedger(reopenedDb, .durablePlain).has(1, 1))
        reopenedDb.close()
    }

    func testRecordPropagatesDatabaseFailure() {
        let ledger = SqliteSyncChangeLedger(db, .durablePlain)
        db.close()

        XCTAssertThrowsError(try ledger.record(change()))
    }
}

final class SqliteLocationEvidenceStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func withGps() -> LocationEvidence {
        LocationEvidence(
            id: "loc-1", serviceRequestId: "sr-1", placeKind: .wellSite, evidenceType: "arrival",
            gps: LocationGpsPoint(lat: 31.5, lon: -102.1, accuracyM: 5, timestampMs: 1_750_000_000_000),
            notes: "at the pad", state: .verified, createdAt: "2026-06-15T03:00:00.000Z")
    }

    private func manual() -> LocationEvidence {
        LocationEvidence(
            id: "loc-2", serviceRequestId: "sr-1", placeKind: .other, evidenceType: "unknown-well",
            state: .manualOnly, createdAt: "2026-06-15T03:05:00.000Z")
    }

    func testRoundTripsGpsBearingAndManualEvidence() throws {
        let store = SqliteLocationEvidenceStore(db, .durablePlain)
        try store.record(withGps())
        try store.record(manual())
        XCTAssertEqual(store.get("loc-1"), withGps())
        XCTAssertEqual(store.get("loc-2"), manual())
        XCTAssertNil(store.get("loc-2")?.gps)
        XCTAssertEqual(store.listByServiceRequest("sr-1").map(\.id), ["loc-1", "loc-2"])
    }

    func testIsAppendOnlyADuplicateEvidenceIdCannotOverwrite() throws {
        let store = SqliteLocationEvidenceStore(db, .durablePlain)
        try store.record(withGps())
        var rejected = withGps()
        rejected.state = .rejected
        XCTAssertThrowsError(try store.record(rejected))
        XCTAssertEqual(store.get("loc-1"), withGps())
    }

    func testSurvivesCloseAndReopen() throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-loc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/loc.db"

        let fileDb = try SystemSqliteDriver(path: file)
        try migrate(fileDb)
        try SqliteLocationEvidenceStore(fileDb, .durablePlain).record(withGps())
        fileDb.close()

        let reopenedDb = try SystemSqliteDriver(path: file)
        try migrate(reopenedDb)
        XCTAssertEqual(SqliteLocationEvidenceStore(reopenedDb, .durablePlain).get("loc-1"), withGps())
        reopenedDb.close()
    }
}

final class SqliteDiagnosticLogStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    private func log(
        _ id: String,
        level: DiagnosticLevel = .info,
        context: [String: JSONValue]? = nil,
        createdAt: String
    ) -> DiagnosticLog {
        DiagnosticLog(
            id: id,
            level: level,
            message: "message \(id)",
            context: context,
            createdAt: createdAt)
    }

    func testRecordsLogsAndReturnsMostRecentFirst() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain)
        try store.record(
            DiagnosticLog(id: "log-1", level: .info, message: "boot ok", createdAt: "2026-06-15T03:00:00.000Z"))
        try store.record(
            DiagnosticLog(
                id: "log-2", level: .error, message: "submit failed",
                context: ["httpStatus": .number(409), "code": .string("workflow_blocked")],
                createdAt: "2026-06-15T03:01:00.000Z"))
        XCTAssertEqual(try store.count(), 2)
        let recent = try store.recent(10)
        XCTAssertEqual(recent.map(\.id), ["log-2", "log-1"])
        XCTAssertEqual(recent[0].level, .error)
        XCTAssertEqual(recent[0].context, ["httpStatus": .number(409), "code": .string("workflow_blocked")])
    }

    func testRecordAtomicallyRetainsOnlyTheConfiguredMostRecentRows() throws {
        XCTAssertEqual(SqliteDiagnosticLogStore.defaultRetentionLimit, 500)
        let store = SqliteDiagnosticLogStore(db, .durablePlain, retentionLimit: 3)

        for index in 1...5 {
            try store.record(
                log(
                    "log-\(index)",
                    createdAt: "2026-06-15T03:0\(index):00.000Z"))
        }

        XCTAssertEqual(try store.count(), 3)
        XCTAssertEqual(try store.recent(10).map(\.id), ["log-5", "log-4", "log-3"])
    }

    func testContextEncodingFailureIsTypedAndDoesNotInsertTheRow() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain)

        XCTAssertThrowsError(
            try store.record(
                log(
                    "log-1",
                    context: ["invalidNumber": .number(.infinity)],
                    createdAt: "2026-06-15T03:01:00.000Z"))
        ) { error in
            guard case .encodingFailed(let id, _) = error as? SqliteDiagnosticLogStoreError
            else { return XCTFail("expected typed diagnostic encoding failure") }
            XCTAssertEqual(id, "log-1")
        }
        XCTAssertEqual(try store.count(), 0)
    }

    func testRetentionFailureRollsBackTheNewEntry() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain, retentionLimit: 2)
        try store.record(log("log-1", createdAt: "2026-06-15T03:01:00.000Z"))
        try store.record(log("log-2", createdAt: "2026-06-15T03:02:00.000Z"))
        try db.exec(
            """
            CREATE TRIGGER reject_diagnostic_retention
            BEFORE DELETE ON diagnostic_logs
            BEGIN
              SELECT RAISE(ABORT, 'injected retention failure');
            END;
            """)

        XCTAssertThrowsError(
            try store.record(log("log-3", createdAt: "2026-06-15T03:03:00.000Z")))
        XCTAssertEqual(try store.count(), 2)
        XCTAssertEqual(try store.recent(10).map(\.id), ["log-2", "log-1"])
    }

    func testCorruptLevelIsSurfacedInsteadOfBecomingInfo() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain)
        try store.record(log("log-1", createdAt: "2026-06-15T03:01:00.000Z"))
        try db.exec("PRAGMA ignore_check_constraints = ON")
        try db.run("UPDATE diagnostic_logs SET level = 'future-level' WHERE id = 'log-1'")
        try db.exec("PRAGMA ignore_check_constraints = OFF")

        XCTAssertThrowsError(try store.recent(10)) { error in
            guard case .corruptRecord(let id, let detail) = error as? SqliteDiagnosticLogStoreError
            else { return XCTFail("expected typed diagnostic corruption") }
            XCTAssertEqual(id, "log-1")
            XCTAssertTrue(detail.contains("level"))
        }
    }

    func testMalformedContextIsSurfacedInsteadOfDropped() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain)
        try store.record(
            log(
                "log-1",
                context: ["status": .number(500)],
                createdAt: "2026-06-15T03:01:00.000Z"))
        try db.run("UPDATE diagnostic_logs SET context_json = '{broken' WHERE id = 'log-1'")

        XCTAssertThrowsError(try store.recent(10)) { error in
            guard case .corruptRecord(let id, let detail) = error as? SqliteDiagnosticLogStoreError
            else { return XCTFail("expected typed diagnostic corruption") }
            XCTAssertEqual(id, "log-1")
            XCTAssertTrue(detail.contains("context_json"))
        }
    }

    func testDatabaseFailuresThrowInsteadOfCrashingOrReturningEmptyData() throws {
        let store = SqliteDiagnosticLogStore(db, .durablePlain)
        db.close()

        XCTAssertThrowsError(
            try store.record(log("log-1", createdAt: "2026-06-15T03:01:00.000Z")))
        XCTAssertThrowsError(try store.recent(10))
        XCTAssertThrowsError(try store.count())
    }
}

final class SqliteTicketEvidenceStoreTests: XCTestCase {
    var db: SystemSqliteDriver!

    override func setUpWithError() throws {
        db = try makeDriver()
        try migrate(db)
    }

    func testRoundTripsFullEvidenceIncludingRejectionRetryFields() async throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { _ in
                    .rejected(
                        kind: .needsReview, httpStatus: 412, rejectionCode: "stale_version", detail: "snapshot drifted")
                },
                evidenceStore: store, now: { Date(timeIntervalSince1970: 1_781_452_800) }  // 2026-06-10T16:00:00Z
            ), makeInput())

        let evidence = store.get("gtr:devA:0:op-1")
        XCTAssertEqual(evidence?.state, .needsReview)
        XCTAssertEqual(evidence?.attempts, 0)
        XCTAssertEqual(evidence?.lastRejectionCode, "stale_version")
        XCTAssertEqual(evidence?.lastDetail, "snapshot drifted")
        XCTAssertEqual(evidence?.lastHttpStatus, 412)
        XCTAssertEqual(evidence?.envelope.payload.serviceRequestId, "sr-1")
        XCTAssertEqual(evidence?.envelope.payload.snapshotHash, "h1")
        XCTAssertEqual(evidence?.envelope.payload.ticketNo, "T-77")
        XCTAssertEqual(evidence?.envelope.payload.quantityBbl, 80)
        XCTAssertEqual(evidence?.envelope.payload.disposalTicketNo, "D-9")
        XCTAssertNil(evidence?.envelope.payload.detail)
        XCTAssertEqual(store.listByState(.needsReview).count, 1)
        XCTAssertEqual(store.listByState(.pending).count, 0)
    }

    func testPersistsAnExplicitOutboxRowShapeSeparateFromUiState() async throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { _ in .transient(reason: .network, httpStatus: nil, detail: "offline") },
                evidenceStore: store, now: { Date(timeIntervalSince1970: 1_781_453_040) }
            ), makeInput())

        let row = try db.first(
            "SELECT id, type, idempotency_key, outbox_status, attempts, last_detail FROM ticket_evidence WHERE idempotency_key = ?",
            [.text("gtr:devA:0:op-1")])
        XCTAssertEqual(row?.string("id"), "gtr:devA:0:op-1")
        XCTAssertEqual(row?.string("type"), "ticket.submit")
        XCTAssertEqual(row?.string("outbox_status"), "retry")
        XCTAssertEqual(row?.int("attempts"), 1)
        XCTAssertEqual(row?.string("last_detail"), "offline")

        let items = store.listOutboxItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "gtr:devA:0:op-1")
        XCTAssertEqual(items[0].status, .retry)
        XCTAssertEqual(items[0].attempts, 1)
        XCTAssertEqual(items[0].lastError, "offline")
    }

    func testProjectsABlockedRowAsBlockedNotFailedOrRetry() async throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { _ in
                    .rejected(
                        kind: .blocked, httpStatus: 403, rejectionCode: "not_clocked_in",
                        detail: "no open TimeClock punch")
                },
                evidenceStore: store, now: { Date(timeIntervalSince1970: 1_781_453_100) }
            ), makeInput())

        let row = try db.first(
            "SELECT outbox_status, last_rejection_code FROM ticket_evidence WHERE idempotency_key = ?",
            [.text("gtr:devA:0:op-1")])
        XCTAssertEqual(row?.string("outbox_status"), "blocked")
        XCTAssertEqual(row?.string("last_rejection_code"), "not_clocked_in")

        let items = store.listOutboxItems()
        XCTAssertEqual(items[0].status, .blocked)
        XCTAssertEqual(items[0].lastError, "no open TimeClock punch")
        XCTAssertEqual(items[0].lastHttpStatus, 403)
        XCTAssertEqual(items[0].lastRejectionCode, "not_clocked_in")
    }

    func testOmitsOptionalFieldsCleanlyWhenNeverSet() {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        let envelope = OperationEnvelope<HubFieldTicketSubmission>(
            opId: "op-2", kind: .command, type: "ticket.submit", idempotencyKey: "gtr:devA:1:op-2", localSeq: 1,
            dependsOn: [],
            payload: HubFieldTicketSubmission(
                idempotencyKey: "gtr:devA:1:op-2", serviceRequestId: "sr-2", snapshotHash: "h2", ticketNo: "T-78",
                quantityBbl: 10, disposalTicketNo: "D-10"))
        store.save(
            TicketEvidence(
                envelope: envelope, state: .pending, attempts: 0, createdAt: "2026-06-10T16:01:00.000Z",
                updatedAt: "2026-06-10T16:01:00.000Z"))
        let evidence = store.get("gtr:devA:1:op-2")
        XCTAssertNotNil(evidence)
        XCTAssertNil(evidence?.lastRejectionCode)
        XCTAssertNil(evidence?.lastDetail)
        XCTAssertNil(evidence?.nextAttemptAtMs)
    }

    func testQuarantinesACorruptEnvelopeRowInsteadOfTakingTheWholeStoreDown() throws {
        let store = SqliteTicketEvidenceStore(db, .durablePlain)
        let envelope = OperationEnvelope<HubFieldTicketSubmission>(
            opId: "op-ok", kind: .command, type: "ticket.submit", idempotencyKey: "gtr:devA:3:op-ok", localSeq: 3,
            dependsOn: [],
            payload: HubFieldTicketSubmission(
                idempotencyKey: "gtr:devA:3:op-ok", serviceRequestId: "sr-1", snapshotHash: "h1", ticketNo: "T-ok",
                quantityBbl: 1, disposalTicketNo: "D-ok"))
        store.save(
            TicketEvidence(
                envelope: envelope, state: .pending, attempts: 0, createdAt: "2026-06-10T16:02:00.000Z",
                updatedAt: "2026-06-10T16:02:00.000Z"))
        // out-of-band corruption of a second row
        try db.run(
            "INSERT INTO ticket_evidence (idempotency_key, envelope_json, state, attempts, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text("gtr:devA:4:op-bad"), .text("{corrupt!!"), .text("pending"), .int(0),
                .text("2026-06-10T16:03:00.000Z"), .text("2026-06-10T16:03:00.000Z"),
            ])

        XCTAssertEqual(store.list().map { $0.envelope.opId }, ["op-ok"])
        XCTAssertEqual(store.listByState(.pending).count, 1)
        XCTAssertNil(store.get("gtr:devA:4:op-bad"))
        XCTAssertEqual(store.listCorruptKeys(), ["gtr:devA:4:op-bad"])
    }
}

final class DeviceIdentityStoreTests: XCTestCase {
    func testCreatesTheDeviceIdOnceAndAllocatesMonotonicLocalSeq() throws {
        let db = try makeDriver()
        try migrate(db)
        let identity = DeviceIdentity(db)
        let id = try identity.ensureDeviceInstanceId { "uuid-1" }
        XCTAssertEqual(id, "uuid-1")
        // second ensure must NOT regenerate
        XCTAssertEqual(try identity.ensureDeviceInstanceId { "uuid-2" }, "uuid-1")
        XCTAssertEqual(try identity.allocateLocalSeq(), 0)
        XCTAssertEqual(try identity.allocateLocalSeq(), 1)
        XCTAssertEqual(try identity.allocateLocalSeq(), 2)
    }

    func testRefusesAGeneratedIdThatWouldCorruptIdempotencyKeys() throws {
        let db = try makeDriver()
        try migrate(db)
        XCTAssertThrowsError(try DeviceIdentity(db).ensureDeviceInstanceId { "bad:uuid" }) { error in
            XCTAssertTrue("\(error)".contains("unusable"))
        }
    }
}

final class SqliteFieldTicketDraftStoreRestartTests: XCTestCase {
    func testPersistsFieldTicketDraftsWithTimestampsUntilExplicitlyDeleted() throws {
        let db = try makeDriver()
        try migrate(db)
        let store = SqliteFieldTicketDraftStore(db, .durablePlain)
        let draft = FieldTicketDraft(
            id: "draft-1", serviceRequestId: "sr-1", ticketNo: "T-77", quantityBbl: 80, disposalTicketNo: "D-9",
            createdAt: "2026-06-10T16:06:00.000Z", updatedAt: "2026-06-10T16:06:00.000Z")
        try store.save(draft)
        XCTAssertEqual(try store.get("draft-1"), draft)
        XCTAssertEqual(try store.list().map(\.id), ["draft-1"])
        try store.delete("draft-1")
        XCTAssertNil(try store.get("draft-1"))
    }

    func testRoundTripsOptionalHaulingFieldsAndCaptureMethodOmittingAbsentOnes() throws {
        let db = try makeDriver()
        try migrate(db)
        let store = SqliteFieldTicketDraftStore(db, .durablePlain)
        let full = FieldTicketDraft(
            id: "draft-2", serviceRequestId: "sr-1", ticketNo: "T-88", quantityBbl: 120, disposalTicketNo: "D-2",
            truck: "Truck 7", trailer: "Trailer 3", driver: "A. Rivera", notes: "gate code 4821",
            captureMethod: .paper, createdAt: "2026-06-15T10:00:00.000Z", updatedAt: "2026-06-15T10:00:00.000Z")
        try store.save(full)
        XCTAssertEqual(try store.get("draft-2"), full)

        try store.save(
            FieldTicketDraft(
                id: "draft-3", serviceRequestId: "sr-1", ticketNo: "T-1", quantityBbl: 10, disposalTicketNo: "D-1",
                createdAt: "2026-06-15T10:00:00.000Z", updatedAt: "2026-06-15T10:00:00.000Z"))
        let minimal = try store.get("draft-3")
        XCTAssertNil(minimal?.truck)
        XCTAssertNil(minimal?.captureMethod)
    }
}

final class RestartSurvivalTests: XCTestCase {
    func testUnsyncedEvidenceAssignmentsAndWriteIdentitySurviveCloseAndReopen() async throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-db-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/field.db"

        // --- session 1: pull assignments, submit fails transiently, app dies ---
        var db: SystemSqliteDriver? = try SystemSqliteDriver(path: file)
        try migrate(db!)
        SqliteAssignmentStore(db!, .durablePlain).putAssignments(assignmentsFixture())
        let identity1 = DeviceIdentity(db!)
        _ = try identity1.ensureDeviceInstanceId { "dev-uuid" }
        XCTAssertEqual(try identity1.allocateLocalSeq(), 0)
        _ = try await submitFieldTicket(
            SubmitFieldTicketDeps(
                submitter: FakeSubmitter { _ in .transient(reason: .network, httpStatus: nil, detail: "offline") },
                evidenceStore: SqliteTicketEvidenceStore(db!, .durablePlain)),
            makeInput(deviceInstanceId: "dev-uuid", localSeq: 0))
        db!.close()
        db = nil

        // --- session 2: restart ---
        let reopened = try SystemSqliteDriver(path: file)
        try migrate(reopened)  // no-op on an up-to-date schema
        let assignments = SqliteAssignmentStore(reopened, .durablePlain)
        XCTAssertEqual(assignments.getSnapshotHash("sr-1"), "h1")
        let evidence = SqliteTicketEvidenceStore(reopened, .durablePlain)
        let pending = evidence.listByState(.pending)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].attempts, 1)
        XCTAssertEqual(pending[0].lastTransientReason, "network")
        XCTAssertEqual(pending[0].lastDetail, "offline")
        XCTAssertEqual(pending[0].envelope.payload.ticketNo, "T-77")
        XCTAssertEqual(pending[0].envelope.payload.quantityBbl, 80)
        // identity survives: same device id, sequence continues (no reuse)
        let identity2 = DeviceIdentity(reopened)
        XCTAssertEqual(try identity2.ensureDeviceInstanceId { "MUST-NOT-REGENERATE" }, "dev-uuid")
        XCTAssertEqual(try identity2.allocateLocalSeq(), 1)
        reopened.close()
    }

    func testFieldTicketDraftsSurviveCloseAndReopenUntilSubmittedOrDeleted() throws {
        let dir = NSTemporaryDirectory() + "fieldcapture-drafts-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/drafts.db"

        let db1 = try SystemSqliteDriver(path: file)
        try migrate(db1)
        try SqliteFieldTicketDraftStore(db1, .durablePlain).save(
            FieldTicketDraft(
                id: "draft-restart-1", serviceRequestId: "sr-1", ticketNo: "T-88", quantityBbl: 90,
                disposalTicketNo: "D-11", createdAt: "2026-06-10T16:07:00.000Z", updatedAt: "2026-06-10T16:08:00.000Z"))
        db1.close()

        let db2 = try SystemSqliteDriver(path: file)
        try migrate(db2)
        let drafts = SqliteFieldTicketDraftStore(db2, .durablePlain)
        XCTAssertEqual(
            try drafts.list(),
            [
                FieldTicketDraft(
                    id: "draft-restart-1", serviceRequestId: "sr-1", ticketNo: "T-88", quantityBbl: 90,
                    disposalTicketNo: "D-11", createdAt: "2026-06-10T16:07:00.000Z",
                    updatedAt: "2026-06-10T16:08:00.000Z")
            ])
        db2.close()
    }
}
