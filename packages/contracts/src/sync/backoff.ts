/**
 * Retry backoff policy (ADR 004: retry/backoff with the SAME idempotency key). Pure math only —
 * NO timers, NO clock, NO randomness source of its own: callers pass `nowMs` and `random` in, so
 * the schedule is fully deterministic under test.
 *
 * Classification (what may auto-retry at all) is decided where the Hub answer is mapped
 * (transient = network / 5xx / 429); this module only answers "when is the next attempt due".
 * Full jitter is used so a fleet of phones recovering from the same Hub outage does not
 * thundering-herd the moment it comes back.
 */

export class BackoffError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BackoffError";
  }
}

export interface RetryPolicy {
  /** Upper bound of the FIRST retry's delay window, in ms. */
  baseDelayMs: number;
  /** Hard cap on any delay window, in ms. */
  maxDelayMs: number;
  /** Exponential growth factor per attempt (default 2). */
  multiplier?: number;
}

/** 5s base doubling to a 5-minute cap: 5s, 10s, 20s, ..., 300s (each with full jitter). */
export const DEFAULT_RETRY_POLICY: RetryPolicy = {
  baseDelayMs: 5_000,
  maxDelayMs: 300_000,
};

function assertPolicy(policy: RetryPolicy): number {
  const multiplier = policy.multiplier ?? 2;
  if (!(policy.baseDelayMs > 0) || !Number.isFinite(policy.baseDelayMs)) {
    throw new BackoffError("baseDelayMs must be a positive finite number");
  }
  if (!(policy.maxDelayMs >= policy.baseDelayMs) || !Number.isFinite(policy.maxDelayMs)) {
    throw new BackoffError("maxDelayMs must be finite and >= baseDelayMs");
  }
  if (!(multiplier >= 1) || !Number.isFinite(multiplier)) {
    throw new BackoffError("multiplier must be finite and >= 1");
  }
  return multiplier;
}

/**
 * The delay window's upper bound for a given retry: min(maxDelayMs, baseDelayMs * multiplier^n)
 * where n = retryCount (0 = the first retry). Deterministic — no jitter.
 */
export function backoffWindowMs(retryCount: number, policy: RetryPolicy = DEFAULT_RETRY_POLICY): number {
  const multiplier = assertPolicy(policy);
  if (!Number.isInteger(retryCount) || retryCount < 0) {
    throw new BackoffError("retryCount must be a non-negative integer");
  }
  // Math.pow overflows to Infinity for large counts; min() against the cap keeps it finite.
  return Math.min(policy.maxDelayMs, policy.baseDelayMs * Math.pow(multiplier, retryCount));
}

/**
 * Full-jitter delay: uniform in [0, window]. `random` must return a number in [0, 1)
 * (pass Math.random in production; a stub in tests).
 */
export function computeBackoffDelayMs(
  retryCount: number,
  random: () => number,
  policy: RetryPolicy = DEFAULT_RETRY_POLICY,
): number {
  const window = backoffWindowMs(retryCount, policy);
  const r = random();
  if (!(r >= 0 && r < 1)) {
    throw new BackoffError(`random() must return a value in [0, 1), got ${r}`);
  }
  return Math.round(r * window);
}

/** Epoch-ms timestamp before which the next attempt must NOT be dispatched. */
export function computeNextAttemptAtMs(
  nowMs: number,
  retryCount: number,
  random: () => number,
  policy: RetryPolicy = DEFAULT_RETRY_POLICY,
): number {
  if (!Number.isFinite(nowMs)) {
    throw new BackoffError("nowMs must be a finite epoch-ms timestamp");
  }
  return nowMs + computeBackoffDelayMs(retryCount, random, policy);
}
