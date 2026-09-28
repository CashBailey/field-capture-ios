// Port of src/runtime/printRuntime.ts — Print runtime (ADR 003): drives the contracts
// `PrintJobQueue` from enqueue → render → transport → printed, and folds Hub's acknowledgement of
// the print EVENTS back into the queue.
//
// Sync-acknowledgement rules:
//  - Every status milestone (queued / printed / failed / canceled) emits an append-only
//    `PrintEvent` operation into the durable sync outbox — print jobs are output artifacts, logged
//    then synced, never truth.
//  - A job becomes Hub-durable (`markSynced` → purgeable) ONLY when the outbox shows its
//    terminal-status event ACCEPTED by Hub. Printed-but-unsynced jobs stay protected; the queue
//    itself refuses to remove anything else.
//  - A missing native printer module is an EXPLICIT failure (`printer-not-implemented`), never a
//    silent success: the job stays failed-retryable in the durable queue until real hardware (or a
//    cancel) resolves it.
//
// Printer state never touches field/safety state: this runtime owns print_jobs/print_payloads rows
// and print events only — tickets, forms, and blobs are not reachable from here.
import Foundation
import FieldContracts

/// In-memory payload store — test seam; a SQLite-backed adapter is wired in production.
public final class VolatilePrintPayloadStore: PrintPayloadStore {
    private let lock = NSLock()
    private var byId: [String: Data] = [:]

    public init() {}

    public func put(_ printJobId: String, _ bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        byId[printJobId] = bytes
    }

    public func get(_ printJobId: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return byId[printJobId]
    }

    public func delete(_ printJobId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        byId.removeValue(forKey: printJobId)
    }
}

public struct PrintRuntimeDeps {
    public var queue: PrintJobQueue
    public var payloads: PrintPayloadStore
    public var transport: PrinterTransport
    /// Bluetooth device id to connect to (from discovery/pairing).
    public var deviceId: String?
    /// Enqueue a print-event operation into the durable sync outbox (`SyncEngine.enqueue`). A
    /// failed durable write must propagate so the job can retry the missing event.
    public var enqueueEvent: (OperationEnvelope<PrintEvent>) throws -> Void
    /// Outbox state of the event op for (printJobId, event) — scanned from the sync outbox. A read
    /// failure is not the same as a missing event and must propagate.
    public var eventOutcome: (_ printJobId: String, _ event: PrintEventKind) throws -> OutboxItemState?
    public var identity: WriteIdentity
    public var now: (() -> Date)?
    public var onError: ((String, Error) -> Void)?

    public init(
        queue: PrintJobQueue, payloads: PrintPayloadStore, transport: PrinterTransport,
        deviceId: String? = nil, enqueueEvent: @escaping (OperationEnvelope<PrintEvent>) throws -> Void,
        eventOutcome: @escaping (_ printJobId: String, _ event: PrintEventKind) throws -> OutboxItemState?,
        identity: WriteIdentity, now: (() -> Date)? = nil, onError: ((String, Error) -> Void)? = nil
    ) {
        self.queue = queue
        self.payloads = payloads
        self.transport = transport
        self.deviceId = deviceId
        self.enqueueEvent = enqueueEvent
        self.eventOutcome = eventOutcome
        self.identity = identity
        self.now = now
        self.onError = onError
    }
}

public struct PrintSweepReport: Equatable, Sendable {
    public var printed = 0
    public var failed = 0
    /// Jobs marked Hub-durable this pass (terminal event accepted).
    public var synced = 0
}

public struct EnqueueTicketPrintInput {
    public var srId: String
    public var fieldTicketId: String
    public var payload: Data
    public var workerRef: String?
    public var printerProfileId: String?

    public init(
        srId: String, fieldTicketId: String, payload: Data, workerRef: String? = nil, printerProfileId: String? = nil
    ) {
        self.srId = srId
        self.fieldTicketId = fieldTicketId
        self.payload = payload
        self.workerRef = workerRef
        self.printerProfileId = printerProfileId
    }
}

public final class PrintRuntime {
    private let deps: PrintRuntimeDeps
    private let now: () -> Date

    public init(_ deps: PrintRuntimeDeps) {
        self.deps = deps
        self.now = deps.now ?? { Date() }
    }

    private func emitEvent(_ printJobId: String, _ event: PrintEventKind) throws {
        let opId = deps.identity.generateUuid()
        let localSeq = deps.identity.allocateLocalSeq()
        let idempotencyKey = try buildIdempotencyKey(deps.identity.deviceInstanceId, localSeq, opId)
        try deps.enqueueEvent(
            OperationEnvelope<PrintEvent>(
                opId: opId, kind: .event, type: "print.event", idempotencyKey: idempotencyKey,
                localSeq: localSeq, dependsOn: [],
                payload: PrintEvent(
                    printJobId: printJobId, event: event, occurredAt: isoStamp(now()), idempotencyKey: idempotencyKey)))
    }

    private func eventForCurrentStatus(_ status: PrintJobStatus) -> PrintEventKind? {
        switch status {
        case .queued: return .queued
        case .printed: return .printed
        case .failed: return .failed
        case .canceled: return .canceled
        case .rendering, .printing, .synced: return nil
        }
    }

    /// Retry an event whose first durable enqueue failed. This runs before any further device work,
    /// so a stored job can recover on the next sweep without printing twice.
    private func ensureCurrentStatusEvent(_ job: PrintJob) throws {
        guard let event = eventForCurrentStatus(job.status) else { return }
        guard try deps.eventOutcome(job.printJobId, event) == nil else { return }
        try emitEvent(job.printJobId, event)
    }

    /// Durably enqueue a finalized print payload for a ticket. Emits the 'queued' event.
    @discardableResult
    public func enqueueTicketPrint(_ input: EnqueueTicketPrintInput) throws -> PrintJob {
        let printJobId = deps.identity.generateUuid()
        try deps.payloads.put(printJobId, input.payload)
        let job = try deps.queue.enqueue(
            PrintJob(
                printJobId: printJobId, srId: input.srId, fieldTicketId: input.fieldTicketId,
                workerRef: input.workerRef, printerProfileId: input.printerProfileId ?? PT210_PROFILE_ID,
                createdAt: isoStamp(now()), printedAt: nil, syncedAt: nil, status: .queued, retryCount: 0,
                errorCode: nil, diagnosticMessage: nil, payloadHash: sha256Hex(input.payload),
                payloadSizeBytes: input.payload.count))
        try emitEvent(printJobId, .queued)
        return job
    }

    /// Print every queued/failed-retryable job. Printer failures remain per-job and retryable;
    /// outbox I/O failures propagate because they affect the durability boundary for every job.
    public func processOnce() async throws -> PrintSweepReport {
        var report = PrintSweepReport()
        for job in try deps.queue.pending() {
            try ensureCurrentStatusEvent(job)
            if job.status == .rendering || job.status == .printing {
                let detail = "The app stopped before it could confirm whether this ticket printed."
                _ = try deps.queue.markFailed(job.printJobId, "print-outcome-unknown", detail)
                try emitEvent(job.printJobId, .failed)
                report.failed += 1
                continue
            }
            guard job.status == .queued || job.status == .failed else { continue }  // printed/canceled await sync only
            guard let payload = try deps.payloads.get(job.printJobId) else {
                let error = PrintJobError("payload bytes for \(job.printJobId) are missing from the payload store")
                _ = try deps.queue.markFailed(job.printJobId, "payload-missing", error.description)
                try emitEvent(job.printJobId, .failed)
                report.failed += 1
                deps.onError?(job.printJobId, error)
                continue
            }
            _ = try deps.queue.markRendering(job.printJobId)
            _ = try deps.queue.markPrinting(job.printJobId)
            do {
                if !deps.transport.isConnected() {
                    try await deps.transport.connect(deps.deviceId ?? "pt210")
                }
                try await deps.transport.writeBytes(payload)
            } catch {
                let code = error is NotImplementedError ? "printer-not-implemented" : "transport-error"
                _ = try deps.queue.markFailed(job.printJobId, code, String(describing: error))
                try emitEvent(job.printJobId, .failed)
                report.failed += 1
                deps.onError?(job.printJobId, error)
                continue
            }
            _ = try deps.queue.markPrinted(job.printJobId, isoStamp(now()))
            try emitEvent(job.printJobId, .printed)
            report.printed += 1
        }
        return report
    }

    /// Explicit cancel — the cancellation itself still syncs to Hub as an event.
    @discardableResult
    public func cancel(_ printJobId: String) throws -> PrintJob {
        let job = try deps.queue.cancel(printJobId)
        try emitEvent(printJobId, .canceled)
        return job
    }

    /// Fold Hub acknowledgements back into the queue: a terminal job whose terminal-status event
    /// the outbox shows ACCEPTED becomes Hub-durable (markSynced). Nothing else changes.
    @discardableResult
    public func reconcileSync() throws -> Int {
        var synced = 0
        for job in try deps.queue.list() {
            guard job.syncedAt == nil else { continue }
            let terminalEvent: PrintEventKind?
            switch job.status {
            case .printed: terminalEvent = .printed
            case .failed: terminalEvent = .failed
            case .canceled: terminalEvent = .canceled
            default: terminalEvent = nil
            }
            guard let terminalEvent else { continue }
            if try deps.eventOutcome(job.printJobId, terminalEvent) == .accepted {
                _ = try deps.queue.markSynced(job.printJobId, isoStamp(now()))
                synced += 1
            }
        }
        return synced
    }

    /// Remove Hub-durable jobs (the queue structurally refuses everything else) + their bytes.
    @discardableResult
    public func purgeSynced() throws -> [String] {
        var removed: [String] = []
        for job in try deps.queue.list() where isHubDurable(job) {
            // Bytes go first. If deleting the row then fails, the already-synced job remains as a
            // harmless retry marker and the next purge finishes it without orphaning payload data.
            try deps.payloads.delete(job.printJobId)
            try deps.queue.remove(job.printJobId)
            removed.append(job.printJobId)
        }
        return removed
    }
}

/// Scan helper for `eventOutcome` over the durable sync outbox: find the print-event op for
/// (printJobId, event) and return its state.
public func printEventOutcomeFromOutbox(
    _ items: [OutboxItem<PrintEvent>], _ printJobId: String, _ event: PrintEventKind
) -> OutboxItemState? {
    for item in items {
        guard item.envelope.type == "print.event" else { continue }
        if item.envelope.payload.printJobId == printJobId && item.envelope.payload.event == event {
            return item.state
        }
    }
    return nil
}
