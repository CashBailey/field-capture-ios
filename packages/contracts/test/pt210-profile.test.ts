import { describe, it, expect } from "vitest";
import {
  PT210_PROFILE,
  PT210_PROFILE_ID,
  BleTransport,
  NotImplementedError,
} from "../src/printer/index.js";

describe("PT-210 profile", () => {
  it("is 58mm and targets field-ticket/receipt printing", () => {
    expect(PT210_PROFILE.modelName).toBe("PT-210");
    expect(PT210_PROFILE.paperWidthMm).toBe(58);
    expect(PT210_PROFILE.supportsCashDrawer).toBe("irrelevant");
    expect(PT210_PROFILE_ID).toBe("pt210");
  });

  it("records the PT-210 values proven by the iOS BLE spike", () => {
    expect(PT210_PROFILE.commandSet).toBe("escpos");
    expect(PT210_PROFILE.transport).toBe("ble-gatt");
    expect(PT210_PROFILE.printableWidthDots).toBe(384);
    expect(PT210_PROFILE.supportsBitmap).toBe(true);
    expect(PT210_PROFILE.supportsQr).toBe("unknown");
    expect(PT210_PROFILE.supportsCut).toBe(false);
    expect(PT210_PROFILE.requiresVendorApp).toBe(false);
  });
});

describe("BLE transport placeholder", () => {
  it("exposes its kind but throws until the native module proves the path on hardware", async () => {
    const t = new BleTransport();
    expect(t.kind).toBe("ble-gatt");
    expect(t.isConnected()).toBe(false);
    await expect(t.connect("dev-1")).rejects.toBeInstanceOf(NotImplementedError);
    await expect(t.writeBytes(new Uint8Array([0x1b, 0x40]))).rejects.toBeInstanceOf(
      NotImplementedError,
    );
  });
});
