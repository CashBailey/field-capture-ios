import { describe, it, expect } from "vitest";
import { sha256Hex, sha256HexOfString } from "../src/sync/index.js";

describe("sha256 (FIPS 180-4 vectors)", () => {
  it("empty input", () => {
    expect(sha256Hex(new Uint8Array(0))).toBe(
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
  });

  it('"abc"', () => {
    expect(sha256HexOfString("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it('"hello world"', () => {
    expect(sha256HexOfString("hello world")).toBe(
      "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
    );
  });

  it("two-block message (56 bytes forces padding into a second block)", () => {
    expect(sha256HexOfString("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).toBe(
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );
  });

  it("binary input and multi-byte UTF-8 are stable", () => {
    expect(sha256Hex(new Uint8Array([0x00, 0xff, 0x10, 0x80]))).toMatch(/^[0-9a-f]{64}$/);
    expect(sha256HexOfString("nappali — 灣鱷")).toMatch(/^[0-9a-f]{64}$/);
    // Determinism: same input, same digest.
    expect(sha256HexOfString("nappali — 灣鱷")).toBe(sha256HexOfString("nappali — 灣鱷"));
  });
});
