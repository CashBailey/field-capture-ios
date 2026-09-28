/**
 * Printer abstraction contracts (ADR 003, docs/printer-pt210.md).
 *
 * Rules encoded here:
 * - All printing flows through PrinterService / PrinterTransport. No screen-to-printer code.
 * - PT-210 is target printer #1, connected over iOS BLE GATT (CoreBluetooth).
 * - Transport/command-set fields are `"unknown"` sentinels until a real device fills them in
 *   via PrinterDiagnosticReport.
 * - Printing is NOT source of truth. Every print job/event is logged locally and syncable.
 * - UID / card / NFC concerns are NOT part of the printer module.
 */

/** Thrown by transport placeholders until the native module proves the path on hardware. */
export class NotImplementedError extends Error {
  constructor(what: string) {
    super(
      `${what} is not implemented yet — gated on the PT-210 hardware spike (ADR 003).`,
    );
    this.name = "NotImplementedError";
  }
}

/** Tri-state for capabilities/transport that the spike has not yet verified. */
export type Unknownable<T> = T | "unknown";

export type PrinterTransportKind = "ble-gatt";

export type PrinterCommandSet = "escpos" | "proprietary";

/** Capability descriptor per printer model. `"unknown"` until verified by the spike. */
export interface PrinterProfile {
  modelName: string;
  /** Paper width in millimetres (PT-210 = 58). */
  paperWidthMm: number;
  /** Likely ESC/POS for PT-210 but MUST be verified. */
  commandSet: Unknownable<PrinterCommandSet>;
  /** iOS BLE GATT (CoreBluetooth) for the PT-210. */
  transport: Unknownable<PrinterTransportKind>;
  /** Printable width in dots; set from self-test or manual verification. */
  printableWidthDots: Unknownable<number>;
  supportsBitmap: Unknownable<boolean>;
  supportsQr: Unknownable<boolean>;
  /** Probably false for a handheld 58mm printer; verify before changing. */
  supportsCut: Unknownable<boolean>;
  /** Irrelevant for a handheld receipt printer. */
  supportsCashDrawer: "irrelevant";
  /** Whether the unit requires a vendor app (would fail the forbidden-workflow rule). */
  requiresVendorApp: Unknownable<boolean>;
  targetUse: string;
}

/** Moves raw bytes to a device. Implemented by the native module, one class per transport. */
export interface PrinterTransport {
  readonly kind: PrinterTransportKind;
  connect(deviceId: string): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): boolean;
  /** Write a raw byte stream (e.g. an ESC/POS payload) to the connected device. */
  writeBytes(bytes: Uint8Array): Promise<void>;
}

/** Builds raw ESC/POS byte streams. Only the subset the verified profile supports. */
export interface EscPosEncoder {
  reset(): this;
  text(value: string): this;
  bold(on: boolean): this;
  align(mode: "left" | "center" | "right"): this;
  separator(): this;
  feed(lines: number): this;
  /** Only valid when the profile's supportsBitmap is verified true. */
  bitmap(mono: MonoBitmap): this;
  /** Only valid when the profile's supportsQr is verified true. */
  qr(data: string): this;
  encode(): Uint8Array;
}

/** 1-bit-per-pixel bitmap (signatures, ticket renders). width should match printableWidthDots. */
export interface MonoBitmap {
  widthPx: number;
  heightPx: number;
  /** Row-major 1bpp packed bytes. */
  data: Uint8Array;
}

export type PrintJobStatus =
  | "queued"
  | "rendering"
  | "printing"
  | "printed"
  | "synced"
  | "failed"
  | "canceled";

/**
 * Print job model (ADR 003 / Slice 4). A print job is an output artifact, not truth.
 * It must be logged on creation and on every status change, then synced to Hub.
 */
export interface PrintJob {
  printJobId: string;
  srId: string;
  fieldTicketId: string;
  /** One of these identifies the actor. */
  employeeId?: string;
  workerRef?: string;
  printerProfileId: string;
  createdAt: string;
  printedAt: string | null;
  syncedAt: string | null;
  status: PrintJobStatus;
  retryCount: number;
  errorCode: string | null;
  diagnosticMessage: string | null;
  /** Hash of the finalized payload — durable record stored only after payload is finalized. */
  payloadHash: string;
  payloadSizeBytes: number;
}

/** Outcome of one print attempt. */
export interface PrintResult {
  printJobId: string;
  ok: boolean;
  status: PrintJobStatus;
  errorCode?: string;
  diagnosticMessage?: string;
}

/** Structured output of the hardware spike + runtime self-tests. */
export interface PrinterDiagnosticReport {
  modelName: string;
  ranAt: string;
  /** Platform the diagnostic ran on (iOS-only app). */
  platform: "ios";
  connectedTransport: Unknownable<PrinterTransportKind> | "none";
  commandSet: Unknownable<PrinterCommandSet>;
  printableWidthDots: Unknownable<number>;
  requiresVendorApp: Unknownable<boolean>;
  checks: {
    discovery: SpikeCheck;
    connect: SpikeCheck;
    plainText: SpikeCheck;
    boldLarge: SpikeCheck;
    alignment: SpikeCheck;
    separators: SpikeCheck;
    fieldTicketMock: SpikeCheck;
    jhaJsaReceipt: SpikeCheck;
    signatureBitmap: SpikeCheck;
    qrBarcode: SpikeCheck;
    statusReady: SpikeCheck;
    reconnectAfterRestart: SpikeCheck;
    reconnectAfterSleep: SpikeCheck;
    reconnectAfterDisconnect: SpikeCheck;
    disconnect: SpikeCheck;
    offlineQueuedJob: SpikeCheck;
  };
  /** Conclusion that feeds the ADR 001 gate. */
  gateOutcome:
    | "confirmed-ble-ios"
    | "replace-printer-vendor-app"
    | "replace-printer-proprietary"
    | "pending";
  notes?: string;
}

export type SpikeCheck = "pass" | "fail" | "untested";

/** Top-level API used by features. Owns the queue, selects profile + transport. */
export interface PrinterService {
  diagnose(profile: PrinterProfile): Promise<PrinterDiagnosticReport>;
  print(job: PrintJob, payload: Uint8Array): Promise<PrintResult>;
}
