// Shared test seam: the runners/engines under test fire-and-forget `Task { await runSweep() }`
// from synchronous entry points (`start()`, `resumeAfterAuth()`, `notifyQueued()`), mirroring the
// TS `void this.runSweep()`. The TS tests drain these with a few `setImmediate` round-trips (JS's
// single-threaded microtask queue makes that deterministic); Swift's concurrency runtime has no
// exact equivalent, so this sleeps briefly instead — long enough for the fire-and-forget Task
// (and any chained re-sweep) to run to completion for the fast, I/O-free closures every test here
// injects. Mirrors the `Task.sleep`-based waits already used elsewhere in this test suite (e.g.
// FieldAdaptersTests) rather than inventing a different idiom.
import Foundation
import FieldDomain

func flushAsync(_ rounds: Int = 6) async {
    for _ in 0..<rounds {
        try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
    }
}

/// A plain mutable reference cell — the Swift stand-in for the TS tests' habit of closing over a
/// mutable local (`const calls: T[] = []`) from multiple injected closures.
final class Box<T>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var storage: [T] = []

    var items: [T] {
        get { withLock { storage } }
        set { withLock { storage = newValue } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &storage
        }
    }

    init() {}

    private func withLock<U>(_ operation: () -> U) -> U {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// Fixed clock used across the runtime test fixtures (mirrors the TS tests' `new Date('2026-06-10T12:00:00Z')`).
let TEST_NOW_2026_06_10_12_00_00Z = ISO8601DateFormatter.parseUtc("2026-06-10T12:00:00Z")

extension ISO8601DateFormatter {
    static func parseUtc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }
}

enum QueueSubmitterError: Error {
    case unexpectedExtraSubmit
}

/// Port of the TS `queueSubmitter(outcomes)` test helper — scripts a fixed sequence of Hub
/// outcomes and records every submission it was asked to make.
final class QueueSubmitter: FieldTicketSubmitter {
    private let lock = NSLock()
    private var outcomes: [HubSubmitOutcome]
    let calls = Box<HubFieldTicketSubmission>()

    init(_ outcomes: [HubSubmitOutcome]) {
        self.outcomes = outcomes
    }

    func submitFieldTicket(_ submission: HubFieldTicketSubmission, options: HubRequestOptions?) async throws
        -> HubSubmitOutcome
    {
        calls.items.append(submission)
        return try dequeueOutcome()
    }

    private func dequeueOutcome() throws -> HubSubmitOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !outcomes.isEmpty else { throw QueueSubmitterError.unexpectedExtraSubmit }
        return outcomes.removeFirst()
    }
}
