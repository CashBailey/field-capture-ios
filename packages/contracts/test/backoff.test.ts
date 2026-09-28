import { describe, it, expect } from "vitest";
import {
  BackoffError,
  DEFAULT_RETRY_POLICY,
  backoffWindowMs,
  computeBackoffDelayMs,
  computeNextAttemptAtMs,
  type RetryPolicy,
} from "../src/sync/index.js";

const POLICY: RetryPolicy = { baseDelayMs: 1_000, maxDelayMs: 8_000 };

describe("backoff window (exponential, capped)", () => {
  it("doubles per retry and caps at maxDelayMs", () => {
    expect(backoffWindowMs(0, POLICY)).toBe(1_000);
    expect(backoffWindowMs(1, POLICY)).toBe(2_000);
    expect(backoffWindowMs(2, POLICY)).toBe(4_000);
    expect(backoffWindowMs(3, POLICY)).toBe(8_000);
    expect(backoffWindowMs(4, POLICY)).toBe(8_000); // capped
    expect(backoffWindowMs(1_000, POLICY)).toBe(8_000); // huge counts stay finite at the cap
  });

  it("honors a custom multiplier", () => {
    expect(backoffWindowMs(2, { baseDelayMs: 100, maxDelayMs: 100_000, multiplier: 3 })).toBe(900);
  });

  it("default policy: 5s base, 5-minute cap", () => {
    expect(backoffWindowMs(0)).toBe(5_000);
    expect(backoffWindowMs(10)).toBe(300_000);
    expect(DEFAULT_RETRY_POLICY.maxDelayMs).toBe(300_000);
  });

  it("rejects bad inputs loudly", () => {
    expect(() => backoffWindowMs(-1, POLICY)).toThrow(BackoffError);
    expect(() => backoffWindowMs(0.5, POLICY)).toThrow(BackoffError);
    expect(() => backoffWindowMs(0, { baseDelayMs: 0, maxDelayMs: 10 })).toThrow(BackoffError);
    expect(() => backoffWindowMs(0, { baseDelayMs: 100, maxDelayMs: 50 })).toThrow(BackoffError);
    expect(() => backoffWindowMs(0, { ...POLICY, multiplier: 0.5 })).toThrow(BackoffError);
  });
});

describe("full jitter (deterministic via injected random)", () => {
  it("spreads uniformly across [0, window]", () => {
    expect(computeBackoffDelayMs(3, () => 0, POLICY)).toBe(0);
    expect(computeBackoffDelayMs(3, () => 0.5, POLICY)).toBe(4_000);
    expect(computeBackoffDelayMs(3, () => 0.999, POLICY)).toBe(7_992);
  });

  it("rejects a broken random source instead of scheduling garbage", () => {
    expect(() => computeBackoffDelayMs(0, () => 1.5, POLICY)).toThrow(BackoffError);
    expect(() => computeBackoffDelayMs(0, () => -0.1, POLICY)).toThrow(BackoffError);
    expect(() => computeBackoffDelayMs(0, () => NaN, POLICY)).toThrow(BackoffError);
  });

  it("computeNextAttemptAtMs = now + jittered delay", () => {
    const now = 1_750_000_000_000;
    expect(computeNextAttemptAtMs(now, 1, () => 0.5, POLICY)).toBe(now + 1_000);
    expect(() => computeNextAttemptAtMs(NaN, 0, () => 0.5, POLICY)).toThrow(BackoffError);
  });
});
