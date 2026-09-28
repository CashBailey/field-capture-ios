// Port of sync/backoff.ts — Retry backoff policy (ADR 004: retry/backoff with the SAME idempotency
// key). Pure math only — NO timers, NO clock, NO randomness source of its own: callers pass `nowMs`
// and `random` in, so the schedule is fully deterministic under test.
//
// Classification (what may auto-retry at all) is decided where the Hub answer is mapped
// (transient = network / 5xx / 429); this module only answers "when is the next attempt due".
// Full jitter is used so a fleet of phones recovering from the same Hub outage does not
// thundering-herd the moment it comes back.
import Foundation

public struct BackoffError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public struct RetryPolicy: Equatable, Sendable {
    /// Upper bound of the FIRST retry's delay window, in ms.
    public var baseDelayMs: Int
    /// Hard cap on any delay window, in ms.
    public var maxDelayMs: Int
    /// Exponential growth factor per attempt (default 2).
    public var multiplier: Double?

    public init(baseDelayMs: Int, maxDelayMs: Int, multiplier: Double? = nil) {
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
        self.multiplier = multiplier
    }
}

/// 5s base doubling to a 5-minute cap: 5s, 10s, 20s, ..., 300s (each with full jitter).
public let DEFAULT_RETRY_POLICY = RetryPolicy(baseDelayMs: 5_000, maxDelayMs: 300_000)

/// ponytail: TS also asserts `Number.isFinite` on baseDelayMs/maxDelayMs/multiplier (JS numbers can
/// be NaN/Infinity). baseDelayMs/maxDelayMs are Swift `Int` (always finite); `multiplier` stays
/// `Double` since the "custom multiplier" test exercises fractional values, so its finiteness check
/// is kept.
private func assertPolicy(_ policy: RetryPolicy) throws -> Double {
    let multiplier = policy.multiplier ?? 2
    guard policy.baseDelayMs > 0 else {
        throw BackoffError("baseDelayMs must be a positive finite number")
    }
    guard policy.maxDelayMs >= policy.baseDelayMs else {
        throw BackoffError("maxDelayMs must be finite and >= baseDelayMs")
    }
    guard multiplier >= 1, multiplier.isFinite else {
        throw BackoffError("multiplier must be finite and >= 1")
    }
    return multiplier
}

/**
 * The delay window's upper bound for a given retry: min(maxDelayMs, baseDelayMs * multiplier^n)
 * where n = retryCount (0 = the first retry). Deterministic — no jitter.
 */
public func backoffWindowMs(_ retryCount: Int, _ policy: RetryPolicy = DEFAULT_RETRY_POLICY) throws -> Int {
    let multiplier = try assertPolicy(policy)
    guard retryCount >= 0 else {
        throw BackoffError("retryCount must be a non-negative integer")
    }
    // pow() overflows to +infinity for large counts; min() against the cap keeps it finite.
    let raw = Double(policy.baseDelayMs) * pow(multiplier, Double(retryCount))
    return Int(min(Double(policy.maxDelayMs), raw))
}

/**
 * Full-jitter delay: uniform in [0, window]. `random` must return a number in [0, 1)
 * (pass a real random source in production; a stub in tests).
 */
public func computeBackoffDelayMs(
    _ retryCount: Int,
    _ random: () -> Double,
    _ policy: RetryPolicy = DEFAULT_RETRY_POLICY
) throws -> Int {
    let window = try backoffWindowMs(retryCount, policy)
    let r = random()
    guard r >= 0 && r < 1 else {
        throw BackoffError("random() must return a value in [0, 1), got \(r)")
    }
    return Int((r * Double(window)).rounded())
}

/// Epoch-ms timestamp before which the next attempt must NOT be dispatched.
public func computeNextAttemptAtMs(
    _ nowMs: Int64,
    _ retryCount: Int,
    _ random: () -> Double,
    _ policy: RetryPolicy = DEFAULT_RETRY_POLICY
) throws -> Int64 {
    nowMs + Int64(try computeBackoffDelayMs(retryCount, random, policy))
}
