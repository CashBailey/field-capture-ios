// Port of test/print-job-queue.test.ts
import XCTest

@testable import FieldContracts

final class PrintJobQueueTests: XCTestCase {
    private func makeJob(
        _ id: String,
        payloadHash: String = "deadbeef",
        payloadSizeBytes: Int = 1234
    ) -> PrintJob {
        PrintJob(
            printJobId: id, srId: "sr-1", fieldTicketId: "ft-1", employeeId: "emp-1",
            printerProfileId: "pt210", createdAt: "2026-06-07T12:00:00.000Z", status: .queued,
            retryCount: 0, payloadHash: payloadHash, payloadSizeBytes: payloadSizeBytes
        )
    }

    private func newQueue() -> PrintJobQueue {
        PrintJobQueue(InMemoryPrintJobStore())
    }

    func testEnqueuesAFinalizedPayloadAsQueued() throws {
        let q = newQueue()
        let j = try q.enqueue(makeJob("a"))
        XCTAssertEqual(j.status, .queued)
        XCTAssertEqual(try q.get("a")?.status, .queued)
    }

    func testRefusesToEnqueueBeforeThePayloadIsFinalized() {
        let q = newQueue()
        XCTAssertThrowsError(try q.enqueue(makeJob("a", payloadHash: ""))) { error in
            XCTAssertTrue(error is PrintJobError)
        }
        XCTAssertThrowsError(try q.enqueue(makeJob("b", payloadSizeBytes: 0))) { error in
            XCTAssertTrue(error is PrintJobError)
        }
    }

    func testRejectsDuplicatePrintJobId() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        XCTAssertThrowsError(try q.enqueue(makeJob("a"))) { error in
            XCTAssertTrue("\(error)".contains("duplicate"))
        }
    }

    // ---- The headline guarantee: NO job is silently discarded before printed AND synced ----

    func testPurgeRemovesNothingWhileJobsAreUnprintedUnsynced() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.enqueue(makeJob("b"))
        _ = try q.enqueue(makeJob("c"))
        let removed = try q.purge()
        XCTAssertEqual(removed.count, 0)
        XCTAssertEqual(try q.list().count, 3)
    }

    func testPurgeRetainsAPrintedButUnsyncedJob() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.markRendering("a")
        _ = try q.markPrinting("a")
        _ = try q.markPrinted("a", "2026-06-07T12:01:00.000Z")
        XCTAssertTrue(isProtected(try XCTUnwrap(q.get("a"))))
        XCTAssertEqual(try q.purge().count, 0)
        XCTAssertNotNil(try q.get("a"))
    }

    func testPurgeRetainsAFailedUnsyncedJobSoItCanBeRetried() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.markFailed("a", "E_TRANSPORT", "no device")
        XCTAssertEqual(try q.get("a")?.retryCount, 1)
        XCTAssertEqual(try q.purge().count, 0)
        XCTAssertNotNil(try q.get("a"))
    }

    func testPurgeRetainsACanceledButUnsyncedJob() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.cancel("a")
        XCTAssertEqual(try q.purge().count, 0)
        XCTAssertNotNil(try q.get("a"))
    }

    func testOnlyRemovesAJobOnceItIsPrintedAndSynced() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.markPrinted("a", "2026-06-07T12:01:00.000Z")
        _ = try q.markSynced("a", "2026-06-07T12:02:00.000Z")
        XCTAssertTrue(isHubDurable(try XCTUnwrap(q.get("a"))))
        let removed = try q.purge()
        XCTAssertEqual(removed.map(\.printJobId), ["a"])
        XCTAssertNil(try q.get("a"))
    }

    func testMarkSyncedIsIllegalBeforeATerminalState() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        XCTAssertThrowsError(try q.markSynced("a", "2026-06-07T12:02:00.000Z")) { error in
            XCTAssertTrue("\(error)".contains("terminal"))
        }
    }

    func testRemoveRefusesToDeleteAProtectedJob() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.markPrinted("a", "2026-06-07T12:01:00.000Z")
        XCTAssertThrowsError(try q.remove("a")) { error in
            XCTAssertTrue("\(error)".contains("would lose work"))
        }
        XCTAssertNotNil(try q.get("a"))
    }

    func testPendingListsExactlyTheJobsStillNeedingWorkOrHubAck() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))  // queued -> protected
        _ = try q.enqueue(makeJob("b"))
        _ = try q.markPrinted("b", "2026-06-07T12:01:00.000Z")  // printed unsynced -> protected
        _ = try q.enqueue(makeJob("c"))
        _ = try q.markPrinted("c", "2026-06-07T12:01:00.000Z")
        _ = try q.markSynced("c", "2026-06-07T12:02:00.000Z")  // durable -> not pending
        XCTAssertEqual(try q.pending().map(\.printJobId).sorted(), ["a", "b"])
    }

    func testAPartialPredicateStillCannotRemoveProtectedJobs() throws {
        let q = newQueue()
        _ = try q.enqueue(makeJob("a"))
        _ = try q.markPrinted("a", "t")
        _ = try q.markSynced("a", "t2")
        _ = try q.enqueue(makeJob("b"))  // unsynced
        // Try to purge everything; only the durable one goes.
        let removed = try q.purge { _ in true }
        XCTAssertEqual(removed.map(\.printJobId), ["a"])
        XCTAssertNotNil(try q.get("b"))
    }
}
