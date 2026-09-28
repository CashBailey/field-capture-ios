import type { PrintJob, PrintJobStatus } from "./types";

/**
 * Durable store abstraction. The real app backs this with SQLite; tests use an in-memory
 * implementation. The queue's safety invariants do not depend on the backing store.
 */
export interface PrintJobStore {
  upsert(job: PrintJob): void;
  get(id: string): PrintJob | undefined;
  all(): PrintJob[];
  delete(id: string): void;
}

export class InMemoryPrintJobStore implements PrintJobStore {
  private map = new Map<string, PrintJob>();
  upsert(job: PrintJob): void {
    this.map.set(job.printJobId, { ...job });
  }
  get(id: string): PrintJob | undefined {
    const j = this.map.get(id);
    return j ? { ...j } : undefined;
  }
  all(): PrintJob[] {
    return [...this.map.values()].map((j) => ({ ...j }));
  }
  delete(id: string): void {
    this.map.delete(id);
  }
}

export class PrintJobError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PrintJobError";
  }
}

/**
 * A print job is HUB-DURABLE (and therefore purgeable) only once it has been synced to Field
 * Hub — i.e. `syncedAt` is set. This single rule enforces ADR 002's "never silently evict":
 * unprinted, printed-but-unsynced, failed-unsynced, and canceled-unsynced jobs are all
 * protected, because none of them have `syncedAt`.
 */
export function isHubDurable(job: PrintJob): boolean {
  return job.syncedAt !== null;
}

/** Protected = must never be removed by purge/eviction. */
export function isProtected(job: PrintJob): boolean {
  return !isHubDurable(job);
}

const TERMINAL: ReadonlySet<PrintJobStatus> = new Set(["printed", "failed", "canceled"]);

/**
 * Manages the on-device print-job queue with durable, never-silently-lose semantics.
 *
 * Lifecycle: queued -> rendering -> printing -> printed -> synced
 *                                          \-> failed (retryable)
 *            queued/rendering -> canceled (explicit)
 * Any terminal state may later be marked synced once Hub acknowledges the print event.
 */
export class PrintJobQueue {
  constructor(private readonly store: PrintJobStore) {}

  /**
   * Durably enqueue a job. The payload must already be finalized (hash + size present), per
   * ADR 002: "store the print job durably only after its data payload is finalized."
   */
  enqueue(job: PrintJob): PrintJob {
    if (this.store.get(job.printJobId)) {
      throw new PrintJobError(`duplicate printJobId ${job.printJobId}`);
    }
    if (!job.payloadHash || job.payloadSizeBytes <= 0) {
      throw new PrintJobError("cannot enqueue a job before its payload is finalized");
    }
    const queued: PrintJob = { ...job, status: "queued", printedAt: null, syncedAt: null };
    this.store.upsert(queued);
    return queued;
  }

  get(id: string): PrintJob | undefined {
    return this.store.get(id);
  }

  list(): PrintJob[] {
    return this.store.all();
  }

  /** Jobs that still need work or Hub acknowledgement. These must survive restarts/eviction. */
  pending(): PrintJob[] {
    return this.store.all().filter(isProtected);
  }

  private transition(id: string, patch: Partial<PrintJob>): PrintJob {
    const cur = this.store.get(id);
    if (!cur) throw new PrintJobError(`unknown printJobId ${id}`);
    const next: PrintJob = { ...cur, ...patch };
    this.store.upsert(next);
    return next;
  }

  markRendering(id: string): PrintJob {
    return this.transition(id, { status: "rendering" });
  }

  markPrinting(id: string): PrintJob {
    return this.transition(id, { status: "printing" });
  }

  markPrinted(id: string, printedAt: string): PrintJob {
    return this.transition(id, { status: "printed", printedAt, errorCode: null, diagnosticMessage: null });
  }

  markFailed(id: string, errorCode: string, diagnosticMessage: string): PrintJob {
    const cur = this.store.get(id);
    if (!cur) throw new PrintJobError(`unknown printJobId ${id}`);
    return this.transition(id, {
      status: "failed",
      errorCode,
      diagnosticMessage,
      retryCount: cur.retryCount + 1,
    });
  }

  /** Explicit user/dispatch action only. The cancellation itself still has to sync to Hub. */
  cancel(id: string): PrintJob {
    return this.transition(id, { status: "canceled" });
  }

  /** Record Hub acknowledgement of the print event. Allowed only from a terminal state. */
  markSynced(id: string, syncedAt: string): PrintJob {
    const cur = this.store.get(id);
    if (!cur) throw new PrintJobError(`unknown printJobId ${id}`);
    if (!TERMINAL.has(cur.status)) {
      throw new PrintJobError(
        `cannot mark synced from status "${cur.status}" — job must reach a terminal state first`,
      );
    }
    return this.transition(id, { status: "synced", syncedAt });
  }

  /**
   * Remove jobs from durable storage. SAFETY-CRITICAL: only Hub-durable (synced) jobs may be
   * removed. Any attempt to remove a protected job is rejected — there is no code path that
   * silently drops an unprinted or unsynced job.
   */
  purge(predicate: (job: PrintJob) => boolean = () => true): PrintJob[] {
    const removed: PrintJob[] = [];
    for (const job of this.store.all()) {
      if (!predicate(job)) continue;
      if (isProtected(job)) continue; // never silently evict
      this.store.delete(job.printJobId);
      removed.push(job);
    }
    return removed;
  }

  /**
   * Hard-delete a single job by id. Throws if the job is protected — callers cannot bypass the
   * never-silently-lose rule even for a targeted delete.
   */
  remove(id: string): void {
    const cur = this.store.get(id);
    if (!cur) throw new PrintJobError(`unknown printJobId ${id}`);
    if (isProtected(cur)) {
      throw new PrintJobError(
        `refusing to remove unsynced print job ${id} (status "${cur.status}") — would lose work`,
      );
    }
    this.store.delete(id);
  }
}
