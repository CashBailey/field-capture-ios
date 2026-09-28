/**
 * Print runtime (ADR 003): drives the contracts `PrintJobQueue` from enqueue → render →
 * transport → printed, and folds Hub's acknowledgement of the print EVENTS back into the queue.
 *
 * Sync-acknowledgement rules:
 *  - Every status milestone (queued / printed / failed / canceled) emits an append-only
 *    `PrintEvent` operation into the durable sync outbox — print jobs are output artifacts,
 *    logged then synced, never truth.
 *  - A job becomes Hub-durable (`markSynced` → purgeable) ONLY when the outbox shows its
 *    terminal-status event ACCEPTED by Hub. Printed-but-unsynced jobs stay protected; the queue
 *    itself refuses to remove anything else.
 *  - A missing native printer module is an EXPLICIT failure (`printer-not-implemented`), never
 *    a silent success: the job stays failed-retryable in the durable queue until real hardware
 *    (or a cancel) resolves it.
 *
 * Printer state never touches field/safety state: this runtime owns print_jobs rows and print
 * events only — tickets, forms, and blobs are not reachable from here.
 */
import { printer, sync } from '@fieldcapture/contracts';

import type { WriteIdentity } from './uploadEngine';

/** Durable home for finalized print payload bytes (rendered ESC/POS). */
export interface PrintPayloadStore {
  put(printJobId: string, bytes: Uint8Array): void;
  get(printJobId: string): Uint8Array | undefined;
  delete(printJobId: string): void;
}

/** In-memory payload store — test seam; a file-backed adapter is wired in production. */
export class VolatilePrintPayloadStore implements PrintPayloadStore {
  private byId = new Map<string, Uint8Array>();
  put(printJobId: string, bytes: Uint8Array): void {
    this.byId.set(printJobId, bytes);
  }
  get(printJobId: string): Uint8Array | undefined {
    return this.byId.get(printJobId);
  }
  delete(printJobId: string): void {
    this.byId.delete(printJobId);
  }
}

export interface PrintRuntimeDeps {
  queue: printer.PrintJobQueue;
  payloads: PrintPayloadStore;
  transport: printer.PrinterTransport;
  /** Bluetooth device id to connect to (from discovery/pairing). */
  deviceId?: string;
  /** Enqueue a print-event operation into the durable sync outbox (SyncEngine.enqueue). */
  enqueueEvent: (envelope: sync.OperationEnvelope<sync.PrintEvent>) => void;
  /** Outbox state of the event op for (printJobId, event) — scanned from the sync outbox. */
  eventOutcome: (
    printJobId: string,
    event: sync.PrintEvent['event'],
  ) => sync.OutboxItemState | undefined;
  identity: WriteIdentity;
  now?: () => Date;
  onError?: (printJobId: string, error: unknown) => void;
}

export interface PrintSweepReport {
  printed: number;
  failed: number;
  /** Jobs marked Hub-durable this pass (terminal event accepted). */
  synced: number;
}

export class PrintRuntime {
  private readonly now: () => Date;

  constructor(private readonly deps: PrintRuntimeDeps) {
    this.now = deps.now ?? (() => new Date());
  }

  private emitEvent(printJobId: string, event: sync.PrintEvent['event']): void {
    const opId = this.deps.identity.generateUuid();
    const localSeq = this.deps.identity.allocateLocalSeq();
    const idempotencyKey = sync.buildIdempotencyKey(
      this.deps.identity.deviceInstanceId,
      localSeq,
      opId,
    );
    this.deps.enqueueEvent({
      opId,
      kind: 'event',
      type: 'print.event',
      idempotencyKey,
      localSeq,
      dependsOn: [],
      payload: { printJobId, event, occurredAt: this.now().toISOString(), idempotencyKey },
    });
  }

  /** Durably enqueue a finalized print payload for a ticket. Emits the 'queued' event. */
  enqueueTicketPrint(input: {
    srId: string;
    fieldTicketId: string;
    payload: Uint8Array;
    workerRef?: string;
    printerProfileId?: string;
  }): printer.PrintJob {
    const printJobId = this.deps.identity.generateUuid();
    this.deps.payloads.put(printJobId, input.payload);
    const job = this.deps.queue.enqueue({
      printJobId,
      srId: input.srId,
      fieldTicketId: input.fieldTicketId,
      ...(input.workerRef !== undefined ? { workerRef: input.workerRef } : {}),
      printerProfileId: input.printerProfileId ?? printer.PT210_PROFILE_ID,
      createdAt: this.now().toISOString(),
      printedAt: null,
      syncedAt: null,
      status: 'queued',
      retryCount: 0,
      errorCode: null,
      diagnosticMessage: null,
      payloadHash: sync.sha256Hex(input.payload),
      payloadSizeBytes: input.payload.length,
    });
    this.emitEvent(printJobId, 'queued');
    return job;
  }

  /** Print every queued/failed-retryable job. One bad job never blocks the rest. */
  async processOnce(): Promise<PrintSweepReport> {
    const report: PrintSweepReport = { printed: 0, failed: 0, synced: 0 };
    for (const job of this.deps.queue.pending()) {
      if (job.status !== 'queued' && job.status !== 'failed') continue; // printed/canceled await sync only
      try {
        const payload = this.deps.payloads.get(job.printJobId);
        if (payload === undefined) {
          // Payload bytes lost out-of-band: surface loudly; the job row itself is preserved.
          throw new printer.NotImplementedError(
            `payload bytes for ${job.printJobId} are missing from the payload store`,
          );
        }
        this.deps.queue.markRendering(job.printJobId);
        this.deps.queue.markPrinting(job.printJobId);
        if (!this.deps.transport.isConnected()) {
          await this.deps.transport.connect(this.deps.deviceId ?? 'pt210');
        }
        await this.deps.transport.writeBytes(payload);
        this.deps.queue.markPrinted(job.printJobId, this.now().toISOString());
        this.emitEvent(job.printJobId, 'printed');
        report.printed += 1;
      } catch (error) {
        const code =
          error instanceof printer.NotImplementedError
            ? 'printer-not-implemented'
            : 'transport-error';
        this.deps.queue.markFailed(job.printJobId, code, String(error));
        this.emitEvent(job.printJobId, 'failed');
        report.failed += 1;
        this.deps.onError?.(job.printJobId, error);
      }
    }
    return report;
  }

  /** Explicit cancel — the cancellation itself still syncs to Hub as an event. */
  cancel(printJobId: string): printer.PrintJob {
    const job = this.deps.queue.cancel(printJobId);
    this.emitEvent(printJobId, 'canceled');
    return job;
  }

  /**
   * Fold Hub acknowledgements back into the queue: a terminal job whose terminal-status event
   * the outbox shows ACCEPTED becomes Hub-durable (markSynced). Nothing else changes.
   */
  reconcileSync(): number {
    let synced = 0;
    for (const job of this.deps.queue.list()) {
      if (job.syncedAt !== null) continue;
      const terminalEvent =
        job.status === 'printed'
          ? 'printed'
          : job.status === 'failed'
            ? 'failed'
            : job.status === 'canceled'
              ? 'canceled'
              : undefined;
      if (terminalEvent === undefined) continue;
      if (this.deps.eventOutcome(job.printJobId, terminalEvent) === 'accepted') {
        this.deps.queue.markSynced(job.printJobId, this.now().toISOString());
        synced += 1;
      }
    }
    return synced;
  }

  /** Remove Hub-durable jobs (the queue structurally refuses everything else) + their bytes. */
  purgeSynced(): string[] {
    const removed = this.deps.queue.purge();
    for (const job of removed) this.deps.payloads.delete(job.printJobId);
    return removed.map((j) => j.printJobId);
  }
}

/**
 * Scan helper for `eventOutcome` over the durable sync outbox: find the print-event op for
 * (printJobId, event) and return its state.
 */
export function printEventOutcomeFromOutbox(
  items: readonly sync.OutboxItem[],
  printJobId: string,
  event: sync.PrintEvent['event'],
): sync.OutboxItemState | undefined {
  for (const item of items) {
    if (item.envelope.type !== 'print.event') continue;
    const payload = item.envelope.payload as Partial<sync.PrintEvent>;
    if (payload.printJobId === printJobId && payload.event === event) return item.state;
  }
  return undefined;
}
