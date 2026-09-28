/**
 * PT-210 printer native-module bridge (ADR 003).
 *
 * The REAL native module is the iOS CoreBluetooth implementation (`FieldPrinter.swift`) behind
 * the React Native module name `FieldPrinter`. This file owns the JS seam it must satisfy
 * (`Pt210NativeBinding`), a transport adapter over that seam, and the on-device diagnostic that
 * produces the `PrinterDiagnosticReport` feeding the ADR 001 framework gate.
 *
 * Placeholder behaviour is EXPLICIT: with no binding present, connect/write reject with the
 * contracts `NotImplementedError` (never a silent no-op pretending to print), the diagnostic
 * reports every check `untested` with gateOutcome `pending`, and the print runtime records an
 * explicit `printer-not-implemented` failure on the durable queue.
 *
 * Hardware-only checks (paper output legibility, reconnect after phone restart/sleep) cannot be
 * automated — see docs/printer-pt210.md "Manual hardware diagnostic runbook".
 */
import { printer } from '@fieldcapture/contracts';
import { NativeModules } from 'react-native';

const PT210_NATIVE_MODULE_NAME = 'FieldPrinter';
const DEFAULT_TIMEOUT_MS = 10_000;

export interface Pt210DiscoveredDevice {
  deviceId: string;
  name: string;
  paired?: boolean;
  transport?: printer.PrinterTransportKind;
  rssi?: number;
}

export interface Pt210CallOptions {
  timeoutMs?: number;
}

export interface Pt210DiscoverOptions extends Pt210CallOptions {
  includeUnpaired?: boolean;
}

export type Pt210ConnectionState =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'writing'
  | 'error';

export interface Pt210Status {
  state: Pt210ConnectionState;
  connected: boolean;
  ready: boolean;
  deviceId?: string;
  deviceName?: string;
  transport?: printer.PrinterTransportKind;
  errorCode?: string;
  message?: string;
}

export type Pt210ErrorCode =
  | 'printer-not-implemented'
  | 'transport-error'
  | 'permission-denied'
  | 'bluetooth-unavailable'
  | 'bluetooth-disabled'
  | 'discovery-failed'
  | 'connect-failed'
  | 'write-failed'
  | 'not-connected'
  | 'no-prior-device'
  | 'bad-device-id'
  | 'no-writable-characteristic'
  | 'timeout'
  | 'native-module-invalid';

export interface Pt210NormalizedError {
  code: Pt210ErrorCode;
  message: string;
  nativeCode?: string;
}

interface Pt210NativeErrorInput {
  code: Exclude<Pt210ErrorCode, 'printer-not-implemented'>;
  message: string;
  nativeCode?: string;
}

export class Pt210NativeError extends Error {
  readonly code: Exclude<Pt210ErrorCode, 'printer-not-implemented'>;
  readonly nativeCode?: string;

  constructor(input: Pt210NativeErrorInput) {
    super(input.message);
    this.name = 'Pt210NativeError';
    this.code = input.code;
    if (input.nativeCode !== undefined) this.nativeCode = input.nativeCode;
  }
}

/** The surface the native printer module must implement (iOS CoreBluetooth). */
export interface Pt210NativeBinding {
  discover(options?: Pt210DiscoverOptions): Promise<Pt210DiscoveredDevice[]>;
  connect(deviceId: string, options?: Pt210CallOptions): Promise<Pt210Status>;
  disconnect(options?: Pt210CallOptions): Promise<Pt210Status>;
  isConnected(): boolean;
  status(options?: Pt210CallOptions): Promise<Pt210Status>;
  reconnect(options?: Pt210CallOptions): Promise<Pt210Status>;
  writeBytes(bytes: Uint8Array, options?: Pt210CallOptions): Promise<Pt210Status>;
}

interface Pt210NativeModule {
  discover(timeoutMs: number, includeUnpaired: boolean): Promise<Pt210DiscoveredDevice[]>;
  connect(deviceId: string, timeoutMs: number): Promise<Pt210Status>;
  disconnect(timeoutMs: number): Promise<Pt210Status>;
  status(timeoutMs: number): Promise<Pt210Status>;
  reconnect(timeoutMs: number): Promise<Pt210Status>;
  writeBytes(bytes: number[], timeoutMs: number): Promise<Pt210Status>;
}

const NATIVE_ERROR_CODES: Record<string, Exclude<Pt210ErrorCode, 'printer-not-implemented'>> = {
  ERR_PT210_PERMISSION_DENIED: 'permission-denied',
  ERR_PT210_BLUETOOTH_UNAVAILABLE: 'bluetooth-unavailable',
  ERR_PT210_BLUETOOTH_DISABLED: 'bluetooth-disabled',
  ERR_PT210_DISCOVERY_FAILED: 'discovery-failed',
  ERR_PT210_CONNECT_FAILED: 'connect-failed',
  ERR_PT210_WRITE_FAILED: 'write-failed',
  ERR_PT210_NOT_CONNECTED: 'not-connected',
  ERR_PT210_NO_DEVICE: 'no-prior-device',
  ERR_PT210_BAD_DEVICE_ID: 'bad-device-id',
  ERR_PT210_NO_WRITABLE_CHARACTERISTIC: 'no-writable-characteristic',
  ERR_PT210_TIMEOUT: 'timeout',
  ERR_PT210_NATIVE_CONTRACT: 'native-module-invalid',
  ERR_PT210_CONTEXT: 'native-module-invalid',
};

const PT210_STATES = new Set<Pt210ConnectionState>([
  'disconnected',
  'connecting',
  'connected',
  'reconnecting',
  'writing',
  'error',
]);
const PT210_TRANSPORTS = new Set<printer.PrinterTransportKind>(['ble-gatt']);

function timeout(options?: Pt210CallOptions): number {
  return Math.max(1, options?.timeoutMs ?? DEFAULT_TIMEOUT_MS);
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function optionalTransport(value: unknown): printer.PrinterTransportKind | undefined {
  return PT210_TRANSPORTS.has(value as printer.PrinterTransportKind)
    ? (value as printer.PrinterTransportKind)
    : undefined;
}

function nativeCodeFrom(error: unknown): string | undefined {
  if (typeof error === 'object' && error !== null && 'code' in error) {
    const code = (error as { code?: unknown }).code;
    if (typeof code === 'string') return code;
  }
  const match = String(error).match(/ERR_PT210_[A-Z_]+/);
  return match?.[0];
}

function messageFrom(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function toPt210NativeError(error: unknown): Error {
  if (error instanceof printer.NotImplementedError || error instanceof Pt210NativeError) {
    return error;
  }
  const nativeCode = nativeCodeFrom(error);
  const code = nativeCode !== undefined ? NATIVE_ERROR_CODES[nativeCode] : undefined;
  return new Pt210NativeError({
    code: code ?? 'transport-error',
    message: messageFrom(error),
    ...(nativeCode !== undefined ? { nativeCode } : {}),
  });
}

function timeoutError(label: string, timeoutMs: number): Pt210NativeError {
  return new Pt210NativeError({
    code: 'timeout',
    nativeCode: 'ERR_PT210_TIMEOUT',
    message: `${label} timed out after ${timeoutMs}ms`,
  });
}

function withTimeout<T>(label: string, timeoutMs: number, run: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const guarded = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(timeoutError(label, timeoutMs)), timeoutMs);
  });
  return Promise.race([run, guarded]).finally(() => {
    if (timer !== undefined) clearTimeout(timer);
  });
}

function normalizeStatus(status: Pt210Status): Pt210Status {
  if (typeof status !== 'object' || status === null) {
    throw new Pt210NativeError({
      code: 'native-module-invalid',
      nativeCode: 'ERR_PT210_NATIVE_CONTRACT',
      message: 'FieldPrinter returned an invalid status payload',
    });
  }
  const raw = status as Partial<Pt210Status>;
  const connected = Boolean(raw.connected);
  const ready = raw.ready === undefined ? connected : Boolean(raw.ready);
  const rawState = raw.state;
  const state = PT210_STATES.has(rawState as Pt210ConnectionState)
    ? (rawState as Pt210ConnectionState)
    : connected
      ? 'connected'
      : 'disconnected';
  return {
    state,
    connected,
    ready,
    ...(optionalTransport(raw.transport) !== undefined
      ? { transport: optionalTransport(raw.transport) }
      : {}),
    ...(optionalString(raw.deviceId) !== undefined
      ? { deviceId: optionalString(raw.deviceId) }
      : {}),
    ...(optionalString(raw.deviceName) !== undefined
      ? { deviceName: optionalString(raw.deviceName) }
      : {}),
    ...(optionalString(raw.errorCode) !== undefined
      ? { errorCode: optionalString(raw.errorCode) }
      : {}),
    ...(optionalString(raw.message) !== undefined ? { message: optionalString(raw.message) } : {}),
  };
}

function normalizeDevice(device: Pt210DiscoveredDevice): Pt210DiscoveredDevice {
  if (typeof device !== 'object' || device === null) {
    throw new Pt210NativeError({
      code: 'native-module-invalid',
      nativeCode: 'ERR_PT210_NATIVE_CONTRACT',
      message: 'FieldPrinter returned an invalid device payload',
    });
  }
  const raw = device as Partial<Pt210DiscoveredDevice>;
  const deviceId = optionalString(raw.deviceId);
  const name = optionalString(raw.name);
  if (deviceId === undefined || name === undefined) {
    throw new Pt210NativeError({
      code: 'native-module-invalid',
      nativeCode: 'ERR_PT210_NATIVE_CONTRACT',
      message: 'FieldPrinter returned a device without deviceId/name',
    });
  }
  return {
    deviceId,
    name,
    ...(raw.paired !== undefined ? { paired: Boolean(raw.paired) } : {}),
    ...(optionalTransport(raw.transport) !== undefined
      ? { transport: optionalTransport(raw.transport) }
      : {}),
    ...(typeof raw.rssi === 'number' ? { rssi: raw.rssi } : {}),
  };
}

class ReactNativePt210NativeBinding implements Pt210NativeBinding {
  private connected = false;

  constructor(private readonly native: Pt210NativeModule) {}

  private async invoke<T>(label: string, timeoutMs: number, run: Promise<T>): Promise<T> {
    try {
      return await withTimeout(label, timeoutMs + 1_000, run);
    } catch (error) {
      throw toPt210NativeError(error);
    }
  }

  private rememberStatus(status: Pt210Status): Pt210Status {
    this.connected = status.connected && status.ready;
    return status;
  }

  async discover(options?: Pt210DiscoverOptions): Promise<Pt210DiscoveredDevice[]> {
    const timeoutMs = timeout(options);
    const devices = await this.invoke(
      'PT-210 discovery',
      timeoutMs,
      this.native.discover(timeoutMs, options?.includeUnpaired ?? false),
    );
    return devices.map(normalizeDevice);
  }

  async connect(deviceId: string, options?: Pt210CallOptions): Promise<Pt210Status> {
    const timeoutMs = timeout(options);
    return this.rememberStatus(
      normalizeStatus(
        await this.invoke('PT-210 connect', timeoutMs, this.native.connect(deviceId, timeoutMs)),
      ),
    );
  }

  async disconnect(options?: Pt210CallOptions): Promise<Pt210Status> {
    const timeoutMs = timeout(options);
    return this.rememberStatus(
      normalizeStatus(
        await this.invoke('PT-210 disconnect', timeoutMs, this.native.disconnect(timeoutMs)),
      ),
    );
  }

  isConnected(): boolean {
    return this.connected;
  }

  async status(options?: Pt210CallOptions): Promise<Pt210Status> {
    const timeoutMs = timeout(options);
    return this.rememberStatus(
      normalizeStatus(await this.invoke('PT-210 status', timeoutMs, this.native.status(timeoutMs))),
    );
  }

  async reconnect(options?: Pt210CallOptions): Promise<Pt210Status> {
    const timeoutMs = timeout(options);
    return this.rememberStatus(
      normalizeStatus(
        await this.invoke('PT-210 reconnect', timeoutMs, this.native.reconnect(timeoutMs)),
      ),
    );
  }

  async writeBytes(bytes: Uint8Array, options?: Pt210CallOptions): Promise<Pt210Status> {
    const timeoutMs = timeout(options);
    return this.rememberStatus(
      normalizeStatus(
        await this.invoke(
          'PT-210 write',
          timeoutMs,
          this.native.writeBytes(Array.from(bytes), timeoutMs),
        ),
      ),
    );
  }
}

export function normalizePt210NativeError(error: unknown): Pt210NormalizedError {
  if (error instanceof printer.NotImplementedError) {
    return { code: 'printer-not-implemented', message: error.message };
  }
  if (error instanceof Pt210NativeError) {
    return {
      code: error.code,
      message: error.message,
      ...(error.nativeCode !== undefined ? { nativeCode: error.nativeCode } : {}),
    };
  }
  const nativeCode = nativeCodeFrom(error);
  const code = nativeCode !== undefined ? NATIVE_ERROR_CODES[nativeCode] : undefined;
  return {
    code: code ?? 'transport-error',
    message: messageFrom(error),
    ...(nativeCode !== undefined ? { nativeCode } : {}),
  };
}

function hasNativeShape(native: unknown): native is Pt210NativeModule {
  if (typeof native !== 'object' || native === null) return false;
  const candidate = native as Partial<Record<keyof Pt210NativeModule, unknown>>;
  return (
    typeof candidate.discover === 'function' &&
    typeof candidate.connect === 'function' &&
    typeof candidate.disconnect === 'function' &&
    typeof candidate.status === 'function' &&
    typeof candidate.reconnect === 'function' &&
    typeof candidate.writeBytes === 'function'
  );
}

export function createPt210NativeBinding(native: unknown): Pt210NativeBinding | undefined {
  return hasNativeShape(native) ? new ReactNativePt210NativeBinding(native) : undefined;
}

/**
 * Locate the native module. Returns undefined when this binary does not include the printer
 * native module (iOS for now, old builds) — callers must treat absence as "printing
 * unavailable", never as success.
 */
export function loadPt210NativeBinding(): Pt210NativeBinding | undefined {
  try {
    const native = (NativeModules as Record<string, unknown>)[PT210_NATIVE_MODULE_NAME];
    return createPt210NativeBinding(native);
  } catch {
    return undefined;
  }
}

/** `PrinterTransport` over the native binding; explicit NotImplemented when the binding is absent. */
export class Pt210PrinterTransport implements printer.PrinterTransport {
  readonly kind: printer.PrinterTransportKind;

  constructor(
    private readonly binding: Pt210NativeBinding | undefined = loadPt210NativeBinding(),
    kind: printer.PrinterTransportKind = 'ble-gatt',
  ) {
    this.kind = kind;
  }

  private requireBinding(what: string): Pt210NativeBinding {
    if (this.binding === undefined) {
      throw new printer.NotImplementedError(
        `${what}: PT-210 native module is not installed (hardware spike pending)`,
      );
    }
    return this.binding;
  }

  async connect(deviceId: string): Promise<void> {
    await this.requireBinding('connect').connect(deviceId);
  }

  async disconnect(): Promise<void> {
    // Safe for cleanup paths even without a binding.
    await this.binding?.disconnect();
  }

  isConnected(): boolean {
    return this.binding?.isConnected() ?? false;
  }

  async writeBytes(bytes: Uint8Array): Promise<void> {
    await this.requireBinding('writeBytes').writeBytes(bytes);
  }

  async status(options?: Pt210CallOptions): Promise<Pt210Status> {
    return this.requireBinding('status').status(options);
  }

  async reconnect(options?: Pt210CallOptions): Promise<Pt210Status> {
    return this.requireBinding('reconnect').reconnect(options);
  }

  async discover(options?: Pt210DiscoverOptions): Promise<Pt210DiscoveredDevice[]> {
    return this.requireBinding('discover').discover(options);
  }
}

async function check(run: () => Promise<void>): Promise<printer.SpikeCheck> {
  try {
    await run();
    return 'pass';
  } catch {
    return 'fail';
  }
}

export function createPt210TestReceipt(input?: {
  title?: string;
  serviceRequestId?: string;
  fieldTicketId?: string;
  quantityBbl?: number;
  disposalTicketNo?: string;
  profile?: printer.PrinterProfile;
}): Uint8Array {
  const profile = input?.profile ?? printer.PT210_PROFILE;
  const title = input?.title ?? 'FIELD MOBILE';
  const serviceRequestId = input?.serviceRequestId ?? 'sr-diagnostic';
  const fieldTicketId = input?.fieldTicketId ?? 'field-ticket-test';
  const quantityBbl = input?.quantityBbl ?? 0;
  const disposalTicketNo = input?.disposalTicketNo ?? 'diagnostic';
  return printer
    .createEscPosEncoder(profile)
    .reset()
    .align('center')
    .bold(true)
    .text(title)
    .bold(false)
    .text('PT-210 TEST RECEIPT')
    .align('left')
    .separator()
    .text(`SR: ${serviceRequestId}`)
    .text(`Ticket: ${fieldTicketId}`)
    .text(`Qty: ${quantityBbl} bbl`)
    .text(`Disposal: ${disposalTicketNo}`)
    .separator()
    .feed(3)
    .encode();
}

export function createPt210SignatureBitmapTest(
  profile: printer.PrinterProfile = printer.PT210_PROFILE,
) {
  const widthPx = 256;
  const heightPx = 72;
  const widthBytes = Math.ceil(widthPx / 8);
  const data = new Uint8Array(widthBytes * heightPx);
  const setPixel = (x: number, y: number) => {
    if (x < 0 || x >= widthPx || y < 0 || y >= heightPx) return;
    const byteIndex = y * widthBytes + Math.floor(x / 8);
    const mask = 2 ** (7 - (x % 8));
    const current = data[byteIndex] ?? 0;
    if (Math.floor(current / mask) % 2 === 0) data[byteIndex] = current + mask;
  };
  const drawLine = (x0: number, y0: number, x1: number, y1: number, radius = 1) => {
    const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0), 1);
    for (let i = 0; i <= steps; i += 1) {
      const x = Math.round(x0 + ((x1 - x0) * i) / steps);
      const y = Math.round(y0 + ((y1 - y0) * i) / steps);
      for (let yy = y - radius; yy <= y + radius; yy += 1) {
        for (let xx = x - radius; xx <= x + radius; xx += 1) {
          if ((xx - x) ** 2 + (yy - y) ** 2 <= radius ** 2) setPixel(xx, yy);
        }
      }
    }
  };

  drawLine(18, 52, 42, 24, 2);
  drawLine(42, 24, 66, 54, 2);
  drawLine(66, 54, 94, 34, 2);
  drawLine(94, 34, 128, 50, 2);
  drawLine(128, 50, 170, 36, 2);
  drawLine(170, 36, 220, 46, 2);
  drawLine(42, 62, 220, 62, 1);

  return printer
    .createEscPosEncoder(profile)
    .reset()
    .align('center')
    .text('PT-210 SIGNATURE TEST')
    .bitmap({ widthPx, heightPx, data })
    .feed(3)
    .encode();
}

/**
 * Automated iOS PT-210 diagnostic: discover → connect → print test patterns (plain text,
 * bold, alignment, separators, a mock field ticket) → reconnect-after-disconnect → status.
 * Without a binding everything is `untested` and the gate stays `pending`. The checks that need
 * a human or real hardware conditions (paper legibility, restart/sleep reconnects, offline
 * queue drain) remain `untested` here by design — they live in the manual runbook.
 */
export async function runPt210Diagnostic(deps: {
  binding?: Pt210NativeBinding;
  profile?: printer.PrinterProfile;
  now?: () => Date;
}): Promise<printer.PrinterDiagnosticReport> {
  const profile = deps.profile ?? printer.PT210_PROFILE;
  const platform = 'ios' as const;
  const now = deps.now ?? (() => new Date());
  const untested: printer.PrinterDiagnosticReport['checks'] = {
    discovery: 'untested',
    connect: 'untested',
    plainText: 'untested',
    boldLarge: 'untested',
    alignment: 'untested',
    separators: 'untested',
    fieldTicketMock: 'untested',
    jhaJsaReceipt: 'untested',
    signatureBitmap: 'untested',
    qrBarcode: 'untested',
    statusReady: 'untested',
    reconnectAfterRestart: 'untested',
    reconnectAfterSleep: 'untested',
    reconnectAfterDisconnect: 'untested',
    disconnect: 'untested',
    offlineQueuedJob: 'untested',
  };

  const base: printer.PrinterDiagnosticReport = {
    modelName: profile.modelName,
    ranAt: now().toISOString(),
    platform,
    connectedTransport: 'none',
    commandSet: 'unknown',
    printableWidthDots: 'unknown',
    requiresVendorApp: 'unknown',
    checks: { ...untested },
    gateOutcome: 'pending',
  };

  const binding = deps.binding;
  if (binding === undefined) {
    return { ...base, notes: 'PT-210 native module absent — every check untested, gate pending.' };
  }

  const transport = new Pt210PrinterTransport(binding);
  const checks = { ...untested };
  let devices: Pt210DiscoveredDevice[];
  try {
    devices = await binding.discover({ timeoutMs: DEFAULT_TIMEOUT_MS, includeUnpaired: true });
    checks.discovery = 'pass';
  } catch (error) {
    checks.discovery = 'fail';
    return {
      ...base,
      checks,
      notes: `PT-210 discover failed: ${String(error).replace(/^Error: /, '')}`,
    };
  }
  const device = devices[0];
  if (device === undefined) {
    return { ...base, checks, notes: 'No PT-210 discovered — pair the printer and re-run.' };
  }

  const connected = await check(() => transport.connect(device.deviceId));
  checks.connect = connected;
  if (connected === 'fail') {
    return { ...base, checks, notes: `Discovered ${device.name} but connect failed.` };
  }

  const enc = () => printer.createEscPosEncoder(profile);
  checks.plainText = await check(() =>
    transport.writeBytes(enc().reset().text('FIELD TEST').encode()),
  );
  checks.boldLarge = await check(() =>
    transport.writeBytes(enc().bold(true).text('BOLD').bold(false).encode()),
  );
  checks.alignment = await check(() =>
    transport.writeBytes(enc().align('center').text('CENTER').align('left').encode()),
  );
  checks.separators = await check(() => transport.writeBytes(enc().separator().encode()));
  checks.fieldTicketMock = await check(() => transport.writeBytes(createPt210TestReceipt()));
  checks.signatureBitmap =
    profile.supportsBitmap === true
      ? await check(() => transport.writeBytes(createPt210SignatureBitmapTest(profile)))
      : 'untested';
  checks.statusReady = await check(async () => {
    const status = await transport.status({ timeoutMs: DEFAULT_TIMEOUT_MS });
    if (!status.connected || !status.ready) throw new Error(status.message ?? 'not ready');
  });
  checks.reconnectAfterDisconnect = await check(async () => {
    await transport.disconnect();
    await transport.reconnect({ timeoutMs: DEFAULT_TIMEOUT_MS });
  });
  checks.disconnect = await check(() => transport.disconnect());

  const allPassed = [
    checks.discovery,
    checks.connect,
    checks.plainText,
    checks.boldLarge,
    checks.alignment,
    checks.separators,
    checks.fieldTicketMock,
    checks.signatureBitmap,
    checks.statusReady,
    checks.reconnectAfterDisconnect,
    checks.disconnect,
  ].every((c) => c === 'pass');

  return {
    ...base,
    connectedTransport: device.transport ?? transport.kind,
    commandSet: allPassed ? 'escpos' : 'unknown',
    checks,
    gateOutcome:
      allPassed && (device.transport ?? transport.kind) === 'ble-gatt'
        ? 'confirmed-ble-ios'
        : 'pending',
    notes: allPassed
      ? `ESC/POS ${device.transport ?? transport.kind} path verified on ${device.name}; QR and manual sleep/restart/offline checks remain.`
      : `Some automated checks failed on ${device.name} — see checks.`,
  };
}
