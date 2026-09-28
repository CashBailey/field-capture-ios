import FieldContracts
// Port of __tests__/print-runtime.test.ts — the PrintRuntime-scoped portions only: durable queue,
// print events through the durable outbox, Hub-acknowledgement rules (synced only when the
// terminal event is ACCEPTED), no removal before printed + synced.
//
// ponytail: the TS file also exercises the PT-210 native-binding boundary and the hardware-free
// diagnostic (`createPt210NativeBinding`, `runPt210Diagnostic`, `Pt210PrinterTransport`) — those
// live in `adapters/printer` (FieldAdapters territory, a concurrent agent's target, out of this
// port's scope) and are intentionally NOT ported here; FieldAdaptersTests is where they belong.
// This file uses a minimal in-memory `PrinterTransport` fake instead of `Pt210PrinterTransport` to
// exercise PrintRuntime's own behavior in isolation.
import XCTest

@testable import FieldData
@testable import FieldRuntime

private let PAYLOAD = Data([0x1b, 0x40, 0x47, 0x0a])

private struct FakeWriteIdentity: WriteIdentity {
    let deviceInstanceId: String
    let allocateLocalSeqImpl: () -> Int
    let generateUuidImpl: () -> String
    func allocateLocalSeq() -> Int { allocateLocalSeqImpl() }
    func generateUuid() -> String { generateUuidImpl() }
}

/// Mirrors the TS test's `fakeBinding()`: records writes/connects, no real hardware.
private final class FakePrinterTransport: PrinterTransport, @unchecked Sendable {
    let kind: PrinterTransportKind = .bleGatt
    private(set) var written: [Data] = []
    private(set) var connects: [String] = []
    private var connected = false
    var writeFailure: Error?

    func connect(_ deviceId: String) async throws {
        connects.append(deviceId)
        connected = true
    }

    func disconnect() async throws {
        connected = false
    }

    func isConnected() -> Bool { connected }

    func writeBytes(_ bytes: Data) async throws {
        if let writeFailure { throw writeFailure }
        written.append(bytes)
    }
}

/// Always-throws transport: mirrors "native module absent" (`Pt210PrinterTransport(undefined)`)
/// without depending on the FieldAdapters-specific type.
private final class NotImplementedPrinterTransport: PrinterTransport, @unchecked Sendable {
    let kind: PrinterTransportKind = .bleGatt
    func connect(_ deviceId: String) async throws { throw NotImplementedError("connect") }
    func disconnect() async throws {}
    func isConnected() -> Bool { false }
    func writeBytes(_ bytes: Data) async throws { throw NotImplementedError("writeBytes") }
}

private enum PrintOutboxFailure: Error, Equatable {
    case write
    case read
}

private final class PrintOutboxFailures {
    var enqueueFailureForEvent: PrintEventKind?
    var readFailure = false
}

private func makeRuntime(
    transport: PrinterTransport = FakePrinterTransport(), store: PrintJobStore = InMemoryPrintJobStore(),
    payloads: PrintPayloadStore = VolatilePrintPayloadStore(),
    outboxFailures: PrintOutboxFailures = PrintOutboxFailures()
) -> (
    runtime: PrintRuntime, queue: PrintJobQueue, payloads: PrintPayloadStore,
    outbox: Box<OutboxItem<PrintEvent>>
) {
    let queue = PrintJobQueue(store)
    let outbox = Box<OutboxItem<PrintEvent>>()
    var seq = 0
    var uuid = 0
    let runtime = PrintRuntime(
        PrintRuntimeDeps(
            queue: queue, payloads: payloads, transport: transport,
            enqueueEvent: { envelope in
                if outboxFailures.enqueueFailureForEvent == envelope.payload.event {
                    throw PrintOutboxFailure.write
                }
                outbox.items.append(OutboxItem(envelope: envelope, state: .pending, retryCount: 0))
            },
            eventOutcome: { printJobId, event in
                if outboxFailures.readFailure { throw PrintOutboxFailure.read }
                return printEventOutcomeFromOutbox(outbox.items, printJobId, event)
            },
            identity: FakeWriteIdentity(
                deviceInstanceId: "devA",
                allocateLocalSeqImpl: {
                    defer { seq += 1 }
                    return seq
                },
                generateUuidImpl: {
                    defer { uuid += 1 }
                    return "uuid-\(uuid)"
                }),
            now: { TEST_NOW_2026_06_10_12_00_00Z }))
    return (runtime, queue, payloads, outbox)
}

final class PrintRuntimeTests: XCTestCase {
    // MARK: queue durability

    func testAnEnqueuedJobSurvivesRestartReOpenTheSameRows() throws {
        let store = InMemoryPrintJobStore()
        let first = makeRuntime(store: store)
        let job = try first.runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        // "Restart": a brand-new queue over the same underlying store.
        let reopened = PrintJobQueue(store)
        let reopenedJob = try reopened.get(job.printJobId)
        XCTAssertEqual(reopenedJob?.status, .queued)
        XCTAssertEqual(reopenedJob?.payloadHash, sha256Hex(PAYLOAD))
        XCTAssertEqual(reopenedJob?.payloadSizeBytes, PAYLOAD.count)
    }

    func testQueuedPayloadSurvivesRestartAndCanStillPrint() async throws {
        let directory = NSTemporaryDirectory() + "fieldkit-print-runtime-restart-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/print.db"

        let firstDatabase = try SystemSqliteDriver(path: path)
        try migrate(firstDatabase)
        let firstRuntime = makeRuntime(
            store: SqlitePrintJobStore(firstDatabase),
            payloads: SqlitePrintPayloadStore(firstDatabase))
        let job = try firstRuntime.runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        firstDatabase.close()

        let reopenedDatabase = try SystemSqliteDriver(path: path)
        defer { reopenedDatabase.close() }
        try migrate(reopenedDatabase)
        let transport = FakePrinterTransport()
        let restartedRuntime = makeRuntime(
            transport: transport,
            store: SqlitePrintJobStore(reopenedDatabase),
            payloads: SqlitePrintPayloadStore(reopenedDatabase))

        let report = try await restartedRuntime.runtime.processOnce()

        XCTAssertEqual(report.printed, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(transport.written, [PAYLOAD])
        XCTAssertEqual(try restartedRuntime.queue.get(job.printJobId)?.status, .printed)
    }

    func testEmitsTheQueuedPrintEventWithRealWriteIdentity() throws {
        let (runtime, _, _, outbox) = makeRuntime()
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        XCTAssertEqual(outbox.items.count, 1)
        XCTAssertEqual(outbox.items[0].envelope.kind, .event)
        XCTAssertEqual(outbox.items[0].envelope.type, "print.event")
        XCTAssertEqual(outbox.items[0].envelope.payload.printJobId, job.printJobId)
        XCTAssertEqual(outbox.items[0].envelope.payload.event, .queued)
        XCTAssertNoThrow(try assertEnvelopeConsistent(outbox.items[0].envelope))
    }

    func testQueuedEventWriteFailurePropagatesAndTheStoredJobRetriesTheMissingEvent() async throws {
        let failures = PrintOutboxFailures()
        failures.enqueueFailureForEvent = .queued
        let f = makeRuntime(outboxFailures: failures)

        XCTAssertThrowsError(
            try f.runtime.enqueueTicketPrint(
                EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        ) { error in
            XCTAssertEqual(error as? PrintOutboxFailure, .write)
        }
        let job = try XCTUnwrap(f.queue.list().first)
        XCTAssertEqual(job.status, .queued)
        XCTAssertNotNil(try f.payloads.get(job.printJobId))
        XCTAssertTrue(f.outbox.items.isEmpty)

        failures.enqueueFailureForEvent = nil
        let report = try await f.runtime.processOnce()
        XCTAssertEqual(report.printed, 1)
        XCTAssertTrue(f.outbox.items.contains { $0.envelope.payload.event == .queued })
        XCTAssertTrue(f.outbox.items.contains { $0.envelope.payload.event == .printed })
    }

    func testPrintedEventWriteFailurePropagatesWithoutPrintingTwiceAndRetriesTheEvent() async throws {
        let failures = PrintOutboxFailures()
        let transport = FakePrinterTransport()
        let f = makeRuntime(transport: transport, outboxFailures: failures)
        let job = try f.runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        failures.enqueueFailureForEvent = .printed

        do {
            _ = try await f.runtime.processOnce()
            XCTFail("expected printed-event outbox write to throw")
        } catch {
            XCTAssertEqual(error as? PrintOutboxFailure, .write)
        }
        XCTAssertEqual(transport.written, [PAYLOAD])
        XCTAssertEqual(try f.queue.get(job.printJobId)?.status, .printed)
        XCTAssertFalse(f.outbox.items.contains { $0.envelope.payload.event == .printed })

        failures.enqueueFailureForEvent = nil
        let retry = try await f.runtime.processOnce()
        XCTAssertEqual(retry.printed, 0)
        XCTAssertEqual(transport.written, [PAYLOAD])
        XCTAssertEqual(f.outbox.items.filter { $0.envelope.payload.event == .printed }.count, 1)
    }

    // MARK: placeholder behavior (native module absent)

    func testProcessingFailsExplicitlyJobStaysFailedRetryableNeverSilentlyPrinted() async throws {
        let (runtime, queue, _, outbox) = makeRuntime(transport: NotImplementedPrinterTransport())
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))

        let report = try await runtime.processOnce()

        XCTAssertEqual(report.printed, 0)
        XCTAssertEqual(report.failed, 1)
        let stored = try queue.get(job.printJobId)
        XCTAssertEqual(stored?.status, .failed)
        XCTAssertEqual(stored?.errorCode, "printer-not-implemented")
        XCTAssertEqual(stored?.retryCount, 1)
        XCTAssertTrue(outbox.items.contains { $0.envelope.payload.event == .failed })
    }

    // MARK: print -> sync acknowledgement rules

    func testOutboxReadFailurePropagatesWithoutMarkingTheJobSynced() async throws {
        let failures = PrintOutboxFailures()
        let f = makeRuntime(outboxFailures: failures)
        let job = try f.runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        _ = try await f.runtime.processOnce()
        guard let index = f.outbox.items.firstIndex(where: { $0.envelope.payload.event == .printed }) else {
            return XCTFail("expected a printed event")
        }
        f.outbox.items[index].state = .accepted
        failures.readFailure = true

        XCTAssertThrowsError(try f.runtime.reconcileSync()) { error in
            XCTAssertEqual(error as? PrintOutboxFailure, .read)
        }
        XCTAssertEqual(try f.queue.get(job.printJobId)?.status, .printed)
        XCTAssertNil(try f.queue.get(job.printJobId)?.syncedAt)
    }

    func testARealFakeBoundPrintLandsPrintedAndEmitsThePrintedEvent() async throws {
        let transport = FakePrinterTransport()
        let (runtime, queue, _, _) = makeRuntime(transport: transport)
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))

        let report = try await runtime.processOnce()

        XCTAssertEqual(report.printed, 1)
        XCTAssertEqual(transport.written, [PAYLOAD])
        let stored = try queue.get(job.printJobId)
        XCTAssertEqual(stored?.status, .printed)
        XCTAssertNil(stored?.syncedAt)
    }

    func testWriteFailureKeepsTheDurableJobProtectedAndRetryable() async throws {
        let transport = FakePrinterTransport()
        struct WriteTimeout: Error {}
        transport.writeFailure = WriteTimeout()
        let (runtime, queue, _, _) = makeRuntime(transport: transport)
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))

        let report = try await runtime.processOnce()
        XCTAssertEqual(report.printed, 0)
        XCTAssertEqual(report.failed, 1)

        let stored = try queue.get(job.printJobId)
        XCTAssertEqual(stored?.status, .failed)
        XCTAssertEqual(stored?.errorCode, "transport-error")
        XCTAssertEqual(stored?.retryCount, 1)
        XCTAssertEqual(try runtime.purgeSynced(), [])
        XCTAssertNotNil(try queue.get(job.printJobId))
    }

    func testInterruptedPrintingBecomesAnExplicitUnknownOutcomeWithoutPrintingAgain() async throws {
        let transport = FakePrinterTransport()
        let (runtime, queue, _, outbox) = makeRuntime(transport: transport)
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        _ = try queue.markPrinting(job.printJobId)

        let report = try await runtime.processOnce()

        XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(transport.written.isEmpty)
        let stored = try XCTUnwrap(queue.get(job.printJobId))
        XCTAssertEqual(stored.status, .failed)
        XCTAssertEqual(stored.errorCode, "print-outcome-unknown")
        XCTAssertTrue(outbox.items.contains { $0.envelope.payload.event == .failed })
    }

    func testNoRemovalBeforePrintedAndSyncedPurgeRefusesAtEveryPreDurableStage() async throws {
        let transport = FakePrinterTransport()
        let (runtime, queue, _, outbox) = makeRuntime(transport: transport)
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))

        // queued: protected.
        XCTAssertEqual(try runtime.purgeSynced(), [])
        XCTAssertThrowsError(try queue.remove(job.printJobId))

        // printed but the printed-event NOT yet accepted by Hub: still protected.
        _ = try await runtime.processOnce()
        XCTAssertEqual(try runtime.reconcileSync(), 0)  // event still pending in the outbox
        XCTAssertEqual(try runtime.purgeSynced(), [])
        XCTAssertEqual(try queue.get(job.printJobId)?.status, .printed)

        // Hub accepts the printed event -> synced -> now (and only now) removable.
        guard let idx = outbox.items.firstIndex(where: { $0.envelope.payload.event == .printed }) else {
            return XCTFail("expected a printed event")
        }
        outbox.items[idx].state = .accepted
        XCTAssertEqual(try runtime.reconcileSync(), 1)
        XCTAssertEqual(try queue.get(job.printJobId)?.status, .synced)
        XCTAssertEqual(try runtime.purgeSynced(), [job.printJobId])
        XCTAssertNil(try queue.get(job.printJobId))
    }

    func testACanceledJobStillSyncsItsCancellationBeforeBecomingRemovable() throws {
        let (runtime, _, _, outbox) = makeRuntime()
        let job = try runtime.enqueueTicketPrint(
            EnqueueTicketPrintInput(srId: "sr-9", fieldTicketId: "ft-1", payload: PAYLOAD))
        _ = try runtime.cancel(job.printJobId)

        XCTAssertEqual(try runtime.purgeSynced(), [])  // canceled-unsynced is protected
        guard let idx = outbox.items.firstIndex(where: { $0.envelope.payload.event == .canceled }) else {
            return XCTFail("expected a canceled event")
        }
        outbox.items[idx].state = .accepted
        XCTAssertEqual(try runtime.reconcileSync(), 1)
        XCTAssertEqual(try runtime.purgeSynced(), [job.printJobId])
    }
}
