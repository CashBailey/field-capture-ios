// Port of printer/print-job-queue.ts
import Foundation

/**
 * Durable store abstraction. The real app backs this with SQLite; tests use an in-memory
 * implementation. The queue's safety invariants do not depend on the backing store.
 */
public protocol PrintJobStore: AnyObject, Sendable {
    func upsert(_ job: PrintJob) throws
    func get(_ id: String) throws -> PrintJob?
    func all() throws -> [PrintJob]
    func delete(_ id: String) throws
}

public final class InMemoryPrintJobStore: PrintJobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: PrintJob] = [:]

    public init() {}

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func upsert(_ job: PrintJob) throws {
        withLock { map[job.printJobId] = job }
    }

    public func get(_ id: String) throws -> PrintJob? {
        withLock { map[id] }
    }

    public func all() throws -> [PrintJob] {
        withLock { Array(map.values) }
    }

    public func delete(_ id: String) throws {
        withLock { map.removeValue(forKey: id) }
    }
}

public struct PrintJobError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/**
 * A print job is HUB-DURABLE (and therefore purgeable) only once it has been synced to Field
 * Hub — i.e. `syncedAt` is set. This single rule enforces ADR 002's "never silently evict":
 * unprinted, printed-but-unsynced, failed-unsynced, and canceled-unsynced jobs are all
 * protected, because none of them have `syncedAt`.
 */
public func isHubDurable(_ job: PrintJob) -> Bool {
    job.syncedAt != nil
}

/// Protected = must never be removed by purge/eviction.
public func isProtected(_ job: PrintJob) -> Bool {
    !isHubDurable(job)
}

private let TERMINAL: Set<PrintJobStatus> = [.printed, .failed, .canceled]

/**
 * Manages the on-device print-job queue with durable, never-silently-lose semantics.
 *
 * Lifecycle: queued -> rendering -> printing -> printed -> synced
 *                                          \-> failed (retryable)
 *            queued/rendering -> canceled (explicit)
 * Any terminal state may later be marked synced once Hub acknowledges the print event.
 */
public final class PrintJobQueue: @unchecked Sendable {
    private let store: PrintJobStore

    public init(_ store: PrintJobStore) {
        self.store = store
    }

    /**
     * Durably enqueue a job. The payload must already be finalized (hash + size present), per
     * ADR 002: "store the print job durably only after its data payload is finalized."
     */
    @discardableResult
    public func enqueue(_ job: PrintJob) throws -> PrintJob {
        guard try store.get(job.printJobId) == nil else {
            throw PrintJobError("duplicate printJobId \(job.printJobId)")
        }
        guard !job.payloadHash.isEmpty, job.payloadSizeBytes > 0 else {
            throw PrintJobError("cannot enqueue a job before its payload is finalized")
        }
        var queued = job
        queued.status = .queued
        queued.printedAt = nil
        queued.syncedAt = nil
        try store.upsert(queued)
        return queued
    }

    public func get(_ id: String) throws -> PrintJob? {
        try store.get(id)
    }

    public func list() throws -> [PrintJob] {
        try store.all()
    }

    /// Jobs that still need work or Hub acknowledgement. These must survive restarts/eviction.
    public func pending() throws -> [PrintJob] {
        try store.all().filter(isProtected)
    }

    @discardableResult
    private func transition(_ id: String, _ patch: (inout PrintJob) throws -> Void) throws -> PrintJob {
        guard var cur = try store.get(id) else {
            throw PrintJobError("unknown printJobId \(id)")
        }
        try patch(&cur)
        try store.upsert(cur)
        return cur
    }

    @discardableResult
    public func markRendering(_ id: String) throws -> PrintJob {
        try transition(id) { $0.status = .rendering }
    }

    @discardableResult
    public func markPrinting(_ id: String) throws -> PrintJob {
        try transition(id) { $0.status = .printing }
    }

    @discardableResult
    public func markPrinted(_ id: String, _ printedAt: String) throws -> PrintJob {
        try transition(id) {
            $0.status = .printed
            $0.printedAt = printedAt
            $0.errorCode = nil
            $0.diagnosticMessage = nil
        }
    }

    @discardableResult
    public func markFailed(_ id: String, _ errorCode: String, _ diagnosticMessage: String) throws -> PrintJob {
        try transition(id) {
            $0.status = .failed
            $0.errorCode = errorCode
            $0.diagnosticMessage = diagnosticMessage
            $0.retryCount += 1
        }
    }

    /// Explicit user/dispatch action only. The cancellation itself still has to sync to Hub.
    @discardableResult
    public func cancel(_ id: String) throws -> PrintJob {
        try transition(id) { $0.status = .canceled }
    }

    /// Record Hub acknowledgement of the print event. Allowed only from a terminal state.
    @discardableResult
    public func markSynced(_ id: String, _ syncedAt: String) throws -> PrintJob {
        try transition(id) {
            guard TERMINAL.contains($0.status) else {
                throw PrintJobError(
                    "cannot mark synced from status \"\($0.status.rawValue)\" — job must reach a terminal state first"
                )
            }
            $0.status = .synced
            $0.syncedAt = syncedAt
        }
    }

    /**
     * Remove jobs from durable storage. SAFETY-CRITICAL: only Hub-durable (synced) jobs may be
     * removed. Any attempt to remove a protected job is rejected — there is no code path that
     * silently drops an unprinted or unsynced job.
     */
    @discardableResult
    public func purge(_ predicate: (PrintJob) -> Bool = { _ in true }) throws -> [PrintJob] {
        var removed: [PrintJob] = []
        for job in try store.all() {
            guard predicate(job) else { continue }
            guard !isProtected(job) else { continue }  // never silently evict
            try store.delete(job.printJobId)
            removed.append(job)
        }
        return removed
    }

    /**
     * Hard-delete a single job by id. Throws if the job is protected — callers cannot bypass the
     * never-silently-lose rule even for a targeted delete.
     */
    public func remove(_ id: String) throws {
        guard let cur = try store.get(id) else {
            throw PrintJobError("unknown printJobId \(id)")
        }
        guard !isProtected(cur) else {
            throw PrintJobError(
                "refusing to remove unsynced print job \(id) (status \"\(cur.status.rawValue)\") — would lose work")
        }
        try store.delete(id)
    }
}
