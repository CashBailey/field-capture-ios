import { describe, it, expect } from "vitest";
import {
  createEscPosEncoder,
  NotImplementedError,
  PT210_PROFILE,
  type PrinterProfile,
} from "../src/printer/index.js";

describe("createEscPosEncoder — unconditional subset", () => {
  it("emits the core ESC/POS byte sequences", () => {
    const bytes = createEscPosEncoder(PT210_PROFILE)
      .reset()
      .align("center")
      .bold(true)
      .text("FIELD")
      .bold(false)
      .feed(2)
      .encode();
    expect([...bytes]).toEqual([
      0x1b, 0x40, // ESC @ reset
      0x1b, 0x61, 0x01, // ESC a 1 center
      0x1b, 0x45, 0x01, // ESC E 1 bold on
      0x47, 0x41, 0x54, 0x4f, 0x52, 0x0a, // "FIELD" + LF
      0x1b, 0x45, 0x00, // bold off
      0x1b, 0x64, 0x02, // ESC d 2 feed
    ]);
  });

  it("separator is a full 32-char dashed line", () => {
    const bytes = createEscPosEncoder(PT210_PROFILE).separator().encode();
    expect(bytes).toHaveLength(33);
    expect(bytes[0]).toBe(0x2d);
    expect(bytes[32]).toBe(0x0a);
  });

  it("non-ASCII characters degrade to '?' instead of printer garbage", () => {
    const bytes = createEscPosEncoder(PT210_PROFILE).text("aé灣b").encode();
    expect([...bytes]).toEqual([0x61, 0x3f, 0x3f, 0x62, 0x0a]);
  });

  it("rejects out-of-range feed", () => {
    expect(() => createEscPosEncoder(PT210_PROFILE).feed(-1)).toThrow(RangeError);
    expect(() => createEscPosEncoder(PT210_PROFILE).feed(256)).toThrow(RangeError);
  });

  it("emits GS v 0 raster bytes for verified PT-210 bitmaps", () => {
    const bytes = createEscPosEncoder(PT210_PROFILE)
      .bitmap({ widthPx: 8, heightPx: 1, data: new Uint8Array([0x81]) })
      .encode();
    expect([...bytes]).toEqual([0x1d, 0x76, 0x30, 0x00, 0x01, 0x00, 0x01, 0x00, 0x81]);
  });

  it("rejects malformed bitmap dimensions and payload sizes", () => {
    expect(() =>
      createEscPosEncoder(PT210_PROFILE).bitmap({
        widthPx: 8,
        heightPx: 2,
        data: new Uint8Array(1),
      }),
    ).toThrow(RangeError);
  });

  it("bitmap still throws NotImplementedError while a profile's capability is unverified", () => {
    const unverified: PrinterProfile = { ...PT210_PROFILE, supportsBitmap: "unknown" };
    const enc = createEscPosEncoder(unverified);
    expect(() => enc.bitmap({ widthPx: 8, heightPx: 1, data: new Uint8Array(1) })).toThrow(
      NotImplementedError,
    );
  });

  it("qr throws while the PT-210 command remains unverified", () => {
    const enc = createEscPosEncoder(PT210_PROFILE);
    expect(() => enc.qr("x")).toThrow(NotImplementedError);
  });

  it("even a verified-true QR profile defers QR commands to the spike", () => {
    const verified: PrinterProfile = { ...PT210_PROFILE, supportsBitmap: true, supportsQr: true };
    const enc = createEscPosEncoder(verified);
    expect(() => enc.qr("x")).toThrow(/pending hardware spike/);
  });
});
