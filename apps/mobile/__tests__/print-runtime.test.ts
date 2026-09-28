/**
 * PT-210 print runtime: durable queue over real SQLite, explicit placeholder failure when the
 * native module is absent, print events through the durable outbox, Hub-acknowledgement rules
 * (synced only when the terminal event is ACCEPTED), no removal before printed + synced, and
 * the hardware-free diagnostic.
 */
import { printer, sync } from '@fieldcapture/contracts';

import { migrate, SqlitePrintJobStore } from '../src/data';
import {
  createPt210NativeBinding,
  createPt210SignatureBitmapTest,
  createPt210TestReceipt,
  normalizePt210NativeError,
  Pt210PrinterTransport,
  runPt210Diagnostic,
  type Pt210NativeBinding,
  type Pt210Status,
} from '../src/adapters/printer';
import {
  PrintRuntime,
  printEventOutcomeFromOutbox,
  VolatilePrintPayloadStore,
} from '../src/runtime';
import { betterSqliteDriver, type TestSqlDriver } from '../test-utils/betterSqliteDriver';

const PAYLOAD = new Uint8Array([0x1b, 0x40, 0x47, 0x0a]);

function fakeBinding(overrides?: Partial<Pt210NativeBinding>): Pt210NativeBinding & {
  written: Uint8Array[];
  connects: string[];
} {
  const written: Uint8Array[] = [];
  const connects: string[] = [];
  let connected = false;
  let currentDeviceId: string | undefined;
  const status = (): Pt210Status => ({
    state: connected ? 'connected' : 'disconnected',
    connected,
    ready: connected,
    ...(currentDeviceId !== undefined ? { deviceId: currentDeviceId } : {}),
  });
  return Object.assign(
    {
      discover: async () => [
        {
          deviceId: 'bt-1',
          name: 'PT-210',
          paired: true,
          transport: 'ble-gatt' as const,
        },
      ],
      connect: async (deviceId: string) => {
        connects.push(deviceId);
        currentDeviceId = deviceId;
        connected = true;
        return status();
      },
      disconnect: async () => {
        connected = false;
        return status();
      },
      isConnected: () => connected,
      status: async () => status(),
      reconnect: async () => {
        if (currentDeviceId === undefined) throw new Error('no prior device');
        connects.push(currentDeviceId);
        connected = true;
        return status();
      },
      writeBytes: async (bytes: Uint8Array) => {
        written.push(bytes);
        return status();
      },
      ...overrides,
    },
    { written, connects },
  );
}

function makeRuntime(options?: { binding?: Pt210NativeBinding; db?: TestSqlDriver }) {
  const db = options?.db ?? betterSqliteDriver();
  if (options?.db === undefined) migrate(db);
  const queue = new printer.PrintJobQueue(new SqlitePrintJobStore(db));
  const payloads = new VolatilePrintPayloadStore();
  const outbox: sync.OutboxItem[] = [];
  let seq = 0;
  let uuid = 0;
  const runtime = new PrintRuntime({
    queue,
    payloads,
    transport: new Pt210PrinterTransport(options?.binding),
    enqueueEvent: (envelope) => outbox.push({ envelope, state: 'pending', retryCount: 0 }),
    eventOutcome: (printJobId, event) => printEventOutcomeFromOutbox(outbox, printJobId, event),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { runtime, queue, payloads, outbox, db };
}

afterEach(() => {
  // each test closes its own db when it created one explicitly
});

describe('queue durability', () => {
  it('an enqueued job survives restart (re-open the same SQLite rows)', () => {
    const db = betterSqliteDriver();
    migrate(db);
    const first = makeRuntime({ db });
    const job = first.runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });
    // "Restart": a brand-new queue over the same database.
    const reopened = new printer.PrintJobQueue(new SqlitePrintJobStore(db));
    expect(reopened.get(job.printJobId)).toMatchObject({
      status: 'queued',
      payloadHash: sync.sha256Hex(PAYLOAD),
      payloadSizeBytes: PAYLOAD.length,
    });
    db.close();
  });

  it('emits the queued print event with real write identity', () => {
    const { runtime, outbox } = makeRuntime();
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });
    expect(outbox).toHaveLength(1);
    expect(outbox[0].envelope).toMatchObject({ kind: 'event', type: 'print.event' });
    expect(outbox[0].envelope.payload).toMatchObject({
      printJobId: job.printJobId,
      event: 'queued',
    });
    sync.assertEnvelopeConsistent(outbox[0].envelope);
  });
});

describe('placeholder behavior (native module absent)', () => {
  it('processing fails EXPLICITLY — job stays failed-retryable, never silently "printed"', async () => {
    const { runtime, queue, outbox, db } = makeRuntime(); // no binding
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });

    const report = await runtime.processOnce();

    expect(report).toMatchObject({ printed: 0, failed: 1 });
    expect(queue.get(job.printJobId)).toMatchObject({
      status: 'failed',
      errorCode: 'printer-not-implemented',
      retryCount: 1,
    });
    expect(outbox.some((i) => (i.envelope.payload as sync.PrintEvent).event === 'failed')).toBe(
      true,
    );
    db.close();
  });

  it('the bare transport rejects loudly and reports disconnected', async () => {
    const transport = new Pt210PrinterTransport(undefined);
    expect(transport.isConnected()).toBe(false);
    await expect(transport.connect('bt-1')).rejects.toThrow(printer.NotImplementedError);
    await expect(transport.writeBytes(PAYLOAD)).rejects.toThrow(printer.NotImplementedError);
    await expect(transport.status()).rejects.toThrow(printer.NotImplementedError);
    await expect(transport.reconnect()).rejects.toThrow(printer.NotImplementedError);
    await expect(transport.disconnect()).resolves.toBeUndefined(); // cleanup stays safe
  });

  it('normalizes native-module absence to the queue-safe printer-not-implemented code', () => {
    expect(normalizePt210NativeError(new printer.NotImplementedError('x'))).toMatchObject({
      code: 'printer-not-implemented',
    });
    expect(normalizePt210NativeError(new Error('socket closed'))).toMatchObject({
      code: 'transport-error',
    });
  });
});

describe('PT-210 native binding boundary', () => {
  function nativeModule(overrides?: Record<string, unknown>) {
    const status = {
      state: 'connected',
      connected: true,
      ready: true,
      deviceId: 'AA:BB:CC:DD:EE:FF',
      deviceName: 'PT-210',
    };
    return {
      discover: jest.fn(async () => [
        {
          deviceId: 'AA:BB:CC:DD:EE:FF',
          name: 'PT-210',
          paired: true,
          transport: 'ble-gatt',
        },
      ]),
      connect: jest.fn(async () => status),
      disconnect: jest.fn(async () => ({
        ...status,
        state: 'disconnected',
        connected: false,
        ready: false,
      })),
      isConnected: jest.fn(() => true),
      status: jest.fn(async () => status),
      reconnect: jest.fn(async () => status),
      writeBytes: jest.fn(async () => status),
      ...overrides,
    };
  }

  it('treats a missing or incomplete native module as unsupported, not as a fake printer', () => {
    expect(createPt210NativeBinding(null)).toBeUndefined();
    expect(createPt210NativeBinding({ discover: async () => [] })).toBeUndefined();
  });

  it('passes discovery options through to FieldPrinter and preserves transport metadata', async () => {
    const native = nativeModule();
    const binding = createPt210NativeBinding(native);

    await expect(binding?.discover({ timeoutMs: 1234, includeUnpaired: true })).resolves.toEqual([
      {
        deviceId: 'AA:BB:CC:DD:EE:FF',
        name: 'PT-210',
        paired: true,
        transport: 'ble-gatt',
      },
    ]);
    expect(native.discover).toHaveBeenCalledWith(1234, true);
  });

  it('preserves BLE metadata from the iOS FieldPrinter module', async () => {
    const native = nativeModule({
      discover: jest.fn(async () => [
        {
          deviceId: '7E2B7371-72D2-4B8F-A219-5FD4D8ED7D67',
          name: 'PT-210_261D',
          paired: false,
          transport: 'ble-gatt',
          rssi: -44,
        },
      ]),
      status: jest.fn(async () => ({
        state: 'connected',
        connected: true,
        ready: true,
        deviceId: '7E2B7371-72D2-4B8F-A219-5FD4D8ED7D67',
        deviceName: 'PT-210_261D',
        transport: 'ble-gatt',
      })),
    });
    const binding = createPt210NativeBinding(native);

    await expect(binding?.discover({ timeoutMs: 500, includeUnpaired: true })).resolves.toEqual([
      {
        deviceId: '7E2B7371-72D2-4B8F-A219-5FD4D8ED7D67',
        name: 'PT-210_261D',
        paired: false,
        transport: 'ble-gatt',
        rssi: -44,
      },
    ]);
    await expect(binding?.status({ timeoutMs: 500 })).resolves.toMatchObject({
      transport: 'ble-gatt',
    });
  });

  it('keeps isConnected cache-only so iOS never hits a synchronous native bridge method', async () => {
    const native = nativeModule({
      isConnected: jest.fn(() => {
        throw new Error('sync bridge should not be called');
      }),
    });
    const binding = createPt210NativeBinding(native);

    expect(binding?.isConnected()).toBe(false);
    await expect(binding?.status({ timeoutMs: 250 })).resolves.toMatchObject({
      connected: true,
      ready: true,
    });
    expect(binding?.isConnected()).toBe(true);
    expect(native.isConnected).not.toHaveBeenCalled();
  });

  it('maps permission denied native errors to explicit PT-210 domain errors', async () => {
    const native = nativeModule({
      discover: jest.fn(async () => {
        throw Object.assign(new Error('BLUETOOTH_CONNECT permission is required'), {
          code: 'ERR_PT210_PERMISSION_DENIED',
        });
      }),
    });
    const binding = createPt210NativeBinding(native);

    let error: unknown;
    try {
      await binding?.discover({ timeoutMs: 50 });
    } catch (caught) {
      error = caught;
    }

    expect(error).toMatchObject({
      code: 'permission-denied',
      nativeCode: 'ERR_PT210_PERMISSION_DENIED',
    });
    expect(normalizePt210NativeError(error)).toMatchObject({
      code: 'permission-denied',
      nativeCode: 'ERR_PT210_PERMISSION_DENIED',
    });
  });

  it('preserves native status readiness instead of treating every connection as printable', async () => {
    const native = nativeModule({
      status: jest.fn(async () => ({
        state: 'connected',
        connected: true,
        ready: false,
        deviceId: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'PT-210',
        errorCode: 'paper-out',
        message: 'paper door open',
      })),
    });
    const binding = createPt210NativeBinding(native);

    await expect(binding?.status({ timeoutMs: 250 })).resolves.toMatchObject({
      state: 'connected',
      connected: true,
      ready: false,
      deviceId: 'AA:BB:CC:DD:EE:FF',
      errorCode: 'paper-out',
      message: 'paper door open',
    });
    expect(native.status).toHaveBeenCalledWith(250);
  });

  it('maps write failure and reconnect failure without reporting success', async () => {
    const native = nativeModule({
      writeBytes: jest.fn(async () => {
        throw Object.assign(new Error('socket closed'), { code: 'ERR_PT210_WRITE_FAILED' });
      }),
      reconnect: jest.fn(async () => {
        throw Object.assign(new Error('No previous PT-210 device'), {
          code: 'ERR_PT210_NO_DEVICE',
        });
      }),
    });
    const binding = createPt210NativeBinding(native);

    await expect(binding?.writeBytes(PAYLOAD, { timeoutMs: 50 })).rejects.toMatchObject({
      code: 'write-failed',
      nativeCode: 'ERR_PT210_WRITE_FAILED',
    });
    expect(native.writeBytes).toHaveBeenCalledWith(Array.from(PAYLOAD), 50);
    await expect(binding?.reconnect({ timeoutMs: 50 })).rejects.toMatchObject({
      code: 'no-prior-device',
      nativeCode: 'ERR_PT210_NO_DEVICE',
    });
  });

  it('maps missing writable BLE characteristic to an explicit diagnostic error', async () => {
    const native = nativeModule({
      connect: jest.fn(async () => {
        throw Object.assign(new Error('No PT-210 write-with-response characteristic found'), {
          code: 'ERR_PT210_NO_WRITABLE_CHARACTERISTIC',
        });
      }),
    });
    const binding = createPt210NativeBinding(native);

    await expect(binding?.connect('bt-1', { timeoutMs: 50 })).rejects.toMatchObject({
      code: 'no-writable-characteristic',
      nativeCode: 'ERR_PT210_NO_WRITABLE_CHARACTERISTIC',
    });
  });
});

describe('print → sync acknowledgement rules', () => {
  it('a real (fake-bound) print lands printed + emits the printed event', async () => {
    const binding = fakeBinding();
    const { runtime, queue, db } = makeRuntime({ binding });
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });

    const report = await runtime.processOnce();

    expect(report.printed).toBe(1);
    expect(binding.written).toEqual([PAYLOAD]);
    expect(queue.get(job.printJobId)).toMatchObject({ status: 'printed', syncedAt: null });
    db.close();
  });

  it('write failure keeps the durable job protected and retryable', async () => {
    const binding = fakeBinding({
      writeBytes: async () => {
        throw new Error('write timeout');
      },
    });
    const { runtime, queue, db } = makeRuntime({ binding });
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });

    await expect(runtime.processOnce()).resolves.toMatchObject({ printed: 0, failed: 1 });

    expect(queue.get(job.printJobId)).toMatchObject({
      status: 'failed',
      errorCode: 'transport-error',
      retryCount: 1,
    });
    expect(runtime.purgeSynced()).toEqual([]);
    expect(queue.get(job.printJobId)).toBeDefined();
    db.close();
  });

  it('NO removal before printed + synced: purge refuses at every pre-durable stage', async () => {
    const binding = fakeBinding();
    const { runtime, queue, outbox, db } = makeRuntime({ binding });
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });

    // queued: protected.
    expect(runtime.purgeSynced()).toEqual([]);
    expect(() => queue.remove(job.printJobId)).toThrow(printer.PrintJobError);

    // printed but the printed-event NOT yet accepted by Hub: still protected.
    await runtime.processOnce();
    expect(runtime.reconcileSync()).toBe(0); // event still pending in the outbox
    expect(runtime.purgeSynced()).toEqual([]);
    expect(queue.get(job.printJobId)?.status).toBe('printed');

    // Hub accepts the printed event → synced → now (and only now) removable.
    const printedOp = outbox.find(
      (i) => (i.envelope.payload as sync.PrintEvent).event === 'printed',
    ) as sync.OutboxItem;
    printedOp.state = 'accepted';
    expect(runtime.reconcileSync()).toBe(1);
    expect(queue.get(job.printJobId)).toMatchObject({ status: 'synced' });
    expect(runtime.purgeSynced()).toEqual([job.printJobId]);
    expect(queue.get(job.printJobId)).toBeUndefined();
    db.close();
  });

  it('a canceled job still syncs its cancellation before becoming removable', async () => {
    const { runtime, outbox, db } = makeRuntime();
    const job = runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: PAYLOAD,
    });
    runtime.cancel(job.printJobId);

    expect(runtime.purgeSynced()).toEqual([]); // canceled-unsynced is protected
    const canceledOp = outbox.find(
      (i) => (i.envelope.payload as sync.PrintEvent).event === 'canceled',
    ) as sync.OutboxItem;
    canceledOp.state = 'accepted';
    expect(runtime.reconcileSync()).toBe(1);
    expect(runtime.purgeSynced()).toEqual([job.printJobId]);
    db.close();
  });
});

describe('PT-210 diagnostic', () => {
  it('without a binding: every check untested, gate pending — never a fake pass', async () => {
    const report = await runPt210Diagnostic({ now: () => new Date('2026-06-10T12:00:00Z') });
    expect(report.connectedTransport).toBe('none');
    expect(report.gateOutcome).toBe('pending');
    expect(Object.values(report.checks).every((check) => check === 'untested')).toBe(true);
  });

  it('with a working iOS binding: all checks pass and the ADR 001 BLE gate closes', async () => {
    const binding = fakeBinding();
    const report = await runPt210Diagnostic({
      binding,
      now: () => new Date('2026-06-10T12:00:00Z'),
    });
    expect(report.checks).toMatchObject({
      plainText: 'pass',
      boldLarge: 'pass',
      alignment: 'pass',
      separators: 'pass',
      fieldTicketMock: 'pass',
      reconnectAfterDisconnect: 'pass',
      signatureBitmap: 'pass',
      // hardware/manual-only checks stay untested in the automated run:
      qrBarcode: 'untested',
      reconnectAfterRestart: 'untested',
      reconnectAfterSleep: 'untested',
    });
    expect(report.platform).toBe('ios');
    expect(report.connectedTransport).toBe('ble-gatt');
    expect(report.commandSet).toBe('escpos');
    expect(report.gateOutcome).toBe('confirmed-ble-ios');
    expect(binding.written.length).toBeGreaterThanOrEqual(6);
    expect(binding.connects).toEqual(['bt-1', 'bt-1']);
  });

  it('reports an iOS BLE diagnostic as feasible when core ESC/POS checks pass', async () => {
    const binding = fakeBinding({
      discover: async () => [
        {
          deviceId: 'ios-ble-1',
          name: 'PT-210_261D',
          paired: false,
          transport: 'ble-gatt',
        },
      ],
    });

    const report = await runPt210Diagnostic({
      binding,
      now: () => new Date('2026-06-10T12:00:00Z'),
    });

    expect(report.platform).toBe('ios');
    expect(report.connectedTransport).toBe('ble-gatt');
    expect(report.commandSet).toBe('escpos');
    expect(report.checks.signatureBitmap).toBe('pass');
    expect(report.gateOutcome).toBe('confirmed-ble-ios');
  });

  it('a connect failure is reported, not thrown', async () => {
    const binding = fakeBinding({
      connect: async () => {
        throw new Error('bluetooth off');
      },
    });
    const report = await runPt210Diagnostic({ binding });
    expect(report.checks.plainText).toBe('untested');
    expect(report.notes).toMatch(/connect failed/);
  });

  it('a discovery failure is reported, not thrown', async () => {
    const binding = fakeBinding({
      discover: async () => {
        throw new Error('permission denied');
      },
    });
    const report = await runPt210Diagnostic({ binding });
    expect(report.connectedTransport).toBe('none');
    expect(report.checks.plainText).toBe('untested');
    expect(report.notes).toMatch(/discover failed: permission denied/);
  });

  it('records write failure, status, reconnect, and disconnect outcomes visibly', async () => {
    const binding = fakeBinding({
      writeBytes: async () => {
        throw new Error('paper out');
      },
    });
    const report = await runPt210Diagnostic({ binding });

    expect(report.checks.plainText).toBe('fail');
    expect(report.checks.reconnectAfterDisconnect).toBe('pass');
    expect(report.checks.statusReady).toBe('pass');
    expect(report.checks.disconnect).toBe('pass');
    expect(report.notes).toMatch(/Some automated checks failed/);
  });

  it('generates ESC/POS bytes for the diagnostic receipt instead of a fake print marker', () => {
    const bytes = createPt210TestReceipt({
      title: 'FIELD MOBILE',
      serviceRequestId: 'sr-9',
      fieldTicketId: 'ft-1',
      quantityBbl: 120,
      disposalTicketNo: 'D-123',
    });

    expect(Array.from(bytes.slice(0, 2))).toEqual([0x1b, 0x40]);
    expect(Buffer.from(bytes).toString('latin1')).toContain('FIELD MOBILE');
    expect(Buffer.from(bytes).toString('latin1')).toContain('SR: sr-9');
  });

  it('generates a GS v 0 signature bitmap payload for the PT-210', () => {
    const bytes = createPt210SignatureBitmapTest();
    const markerIndex = Array.from(bytes).findIndex(
      (_byte, index, all) =>
        all[index] === 0x1d &&
        all[index + 1] === 0x76 &&
        all[index + 2] === 0x30 &&
        all[index + 3] === 0x00,
    );

    expect(markerIndex).toBeGreaterThan(0);
    expect(Array.from(bytes.slice(markerIndex, markerIndex + 8))).toEqual([
      0x1d, 0x76, 0x30, 0x00, 32, 0, 72, 0,
    ]);
  });
});
