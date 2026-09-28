import type { PrinterProfile, PrinterTransport, PrinterTransportKind } from "./types";
import { NotImplementedError } from "./types";

/** PT-210 profile (printer #1), updated from the verified iOS BLE/CoreBluetooth spike. */
export const PT210_PROFILE: PrinterProfile = {
  modelName: "PT-210",
  paperWidthMm: 58,
  commandSet: "escpos",
  transport: "ble-gatt",
  printableWidthDots: 384,
  supportsBitmap: true,
  supportsQr: "unknown",
  supportsCut: false,
  supportsCashDrawer: "irrelevant",
  requiresVendorApp: false,
  targetUse: "field ticket / receipt style printing",
};

/** Stable identifier used by PrintJob.printerProfileId. */
export const PT210_PROFILE_ID = "pt210";

/**
 * BLE transport placeholder. It exists so the abstraction is complete and unit-testable, but
 * it throws NotImplementedError — the real iOS CoreBluetooth path lives in the native module
 * (FieldPrinter.swift), wired through Pt210PrinterTransport in apps/mobile.
 */
export class BleTransport implements PrinterTransport {
  readonly kind: PrinterTransportKind = "ble-gatt";
  private connected = false;
  async connect(_deviceId: string): Promise<void> {
    throw new NotImplementedError(`${this.kind} transport connect`);
  }
  async disconnect(): Promise<void> {
    this.connected = false;
  }
  isConnected(): boolean {
    return this.connected;
  }
  async writeBytes(_bytes: Uint8Array): Promise<void> {
    throw new NotImplementedError(`${this.kind} transport writeBytes`);
  }
}
