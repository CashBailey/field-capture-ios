import { describe, it, expect } from "vitest";
import {
  buildIdempotencyKey,
  parseIdempotencyKey,
  IdempotencyKeyError,
  compareChangeTokens,
} from "../src/sync/index.js";

describe("idempotency key (gtr:<device>:<seq>:<uuid>)", () => {
  it("round-trips", () => {
    const key = buildIdempotencyKey("device-abc", 42, "op-uuid-1");
    expect(key).toBe("gtr:device-abc:42:op-uuid-1");
    expect(parseIdempotencyKey(key)).toEqual({
      deviceInstanceId: "device-abc",
      localSeq: 42,
      opUuid: "op-uuid-1",
    });
  });

  it("rejects ':' in segments and bad local_seq", () => {
    expect(() => buildIdempotencyKey("dev:ice", 1, "op")).toThrow(IdempotencyKeyError);
    expect(() => buildIdempotencyKey("dev", 1, "op:1")).toThrow(IdempotencyKeyError);
    expect(() => buildIdempotencyKey("dev", -1, "op")).toThrow(IdempotencyKeyError);
    expect(() => buildIdempotencyKey("dev", 1.5, "op")).toThrow(IdempotencyKeyError);
  });

  it("rejects malformed keys on parse", () => {
    expect(() => parseIdempotencyKey("nope")).toThrow(IdempotencyKeyError);
    expect(() => parseIdempotencyKey("xyz:dev:1:op")).toThrow(IdempotencyKeyError);
    expect(() => parseIdempotencyKey("gtr:dev:notnum:op")).toThrow(IdempotencyKeyError);
    expect(() => parseIdempotencyKey("gtr::1:op")).toThrow(IdempotencyKeyError);
  });
});

describe("change token ordering", () => {
  it("orders by epoch first, then commitSeq", () => {
    expect(compareChangeTokens({ authorityEpoch: 1, commitSeq: 9 }, { authorityEpoch: 2, commitSeq: 0 })).toBeLessThan(0);
    expect(compareChangeTokens({ authorityEpoch: 2, commitSeq: 1 }, { authorityEpoch: 2, commitSeq: 5 })).toBeLessThan(0);
    expect(compareChangeTokens({ authorityEpoch: 2, commitSeq: 5 }, { authorityEpoch: 2, commitSeq: 5 })).toBe(0);
  });
});
