import { describe, it, expect } from "vitest";
import {
  UploadProtocolError,
  planNextChunk,
  reconcileOffset,
  verifyUploadHash,
} from "../src/sync/index.js";

describe("planNextChunk (resumable upload chunking)", () => {
  it("plans sequential chunks until the file is exhausted", () => {
    expect(planNextChunk(0, 10, 4)).toEqual({ offset: 0, length: 4 });
    expect(planNextChunk(4, 10, 4)).toEqual({ offset: 4, length: 4 });
    expect(planNextChunk(8, 10, 4)).toEqual({ offset: 8, length: 2 }); // final partial chunk
  });

  it("returns 'complete' once every byte is acknowledged", () => {
    expect(planNextChunk(10, 10, 4)).toBe("complete");
  });

  it("a zero-byte blob is complete immediately", () => {
    expect(planNextChunk(0, 0, 4)).toBe("complete");
  });

  it("rejects bad inputs loudly", () => {
    expect(() => planNextChunk(-1, 10, 4)).toThrow(UploadProtocolError);
    expect(() => planNextChunk(0, -1, 4)).toThrow(UploadProtocolError);
    expect(() => planNextChunk(0, 10, 0)).toThrow(UploadProtocolError);
    expect(() => planNextChunk(0.5, 10, 4)).toThrow(UploadProtocolError);
    // acked beyond the file means local bookkeeping is corrupt — never "round down" silently
    expect(() => planNextChunk(11, 10, 4)).toThrow(UploadProtocolError);
  });
});

describe("reconcileOffset (server offset is the truth on resume)", () => {
  it("adopts the server offset when it is ahead of local bookkeeping", () => {
    // We sent bytes the app never recorded (crash after a PATCH landed): server wins.
    expect(reconcileOffset(4, 8, 10)).toBe(8);
  });

  it("adopts the server offset when it is behind local bookkeeping", () => {
    // The session lost bytes server-side; re-send from the server's offset.
    expect(reconcileOffset(8, 4, 10)).toBe(4);
  });

  it("accepts a server offset equal to the full length (upload already complete)", () => {
    expect(reconcileOffset(4, 10, 10)).toBe(10);
  });

  it("throws when the server claims more bytes than the blob has", () => {
    expect(() => reconcileOffset(4, 11, 10)).toThrow(UploadProtocolError);
  });

  it("rejects malformed offsets loudly", () => {
    expect(() => reconcileOffset(-1, 4, 10)).toThrow(UploadProtocolError);
    expect(() => reconcileOffset(0, -4, 10)).toThrow(UploadProtocolError);
    expect(() => reconcileOffset(0, 4.5, 10)).toThrow(UploadProtocolError);
  });
});

describe("verifyUploadHash (whole-file integrity gate)", () => {
  it("passes when the server-computed hash matches (case-insensitive hex)", () => {
    expect(verifyUploadHash("AB12", "ab12")).toBe(true);
    expect(verifyUploadHash("ab12", "ab12")).toBe(true);
  });

  it("fails on a mismatch — the upload must NOT be confirmed", () => {
    expect(verifyUploadHash("ab12", "ab13")).toBe(false);
  });

  it("an absent or empty server hash never verifies", () => {
    expect(verifyUploadHash("ab12", undefined)).toBe(false);
    expect(verifyUploadHash("ab12", "")).toBe(false);
  });

  it("rejects an empty local hash loudly — the caller lost its own integrity anchor", () => {
    expect(() => verifyUploadHash("", "ab12")).toThrow(UploadProtocolError);
  });
});
