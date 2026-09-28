import { describe, it, expect } from "vitest";
import {
  PrintJobQueue,
  InMemoryPrintJobStore,
  PrintJobError,
  isProtected,
  isHubDurable,
  type PrintJob,
} from "../src/printer/index.js";

function makeJob(id: string, over: Partial<PrintJob> = {}): PrintJob {
  return {
    printJobId: id,
    srId: "sr-1",
    fieldTicketId: "ft-1",
    employeeId: "emp-1",
    printerProfileId: "pt210",
    createdAt: "2026-06-07T12:00:00.000Z",
    printedAt: null,
    syncedAt: null,
    status: "queued",
    retryCount: 0,
    errorCode: null,
    diagnosticMessage: null,
    payloadHash: "deadbeef",
    payloadSizeBytes: 1234,
    ...over,
  };
}

function newQueue() {
  return new PrintJobQueue(new InMemoryPrintJobStore());
}

describe("PrintJobQueue durability", () => {
  it("enqueues a finalized payload as queued", () => {
    const q = newQueue();
    const j = q.enqueue(makeJob("a"));
    expect(j.status).toBe("queued");
    expect(q.get("a")?.status).toBe("queued");
  });

  it("refuses to enqueue before the payload is finalized", () => {
    const q = newQueue();
    expect(() => q.enqueue(makeJob("a", { payloadHash: "" }))).toThrow(PrintJobError);
    expect(() => q.enqueue(makeJob("b", { payloadSizeBytes: 0 }))).toThrow(PrintJobError);
  });

  it("rejects duplicate printJobId", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    expect(() => q.enqueue(makeJob("a"))).toThrow(/duplicate/);
  });

  // ---- The headline guarantee: NO job is silently discarded before printed AND synced ----

  it("purge removes nothing while jobs are unprinted/unsynced", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.enqueue(makeJob("b"));
    q.enqueue(makeJob("c"));
    const removed = q.purge();
    expect(removed).toHaveLength(0);
    expect(q.list()).toHaveLength(3);
  });

  it("purge retains a printed-but-unsynced job", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.markRendering("a");
    q.markPrinting("a");
    q.markPrinted("a", "2026-06-07T12:01:00.000Z");
    expect(isProtected(q.get("a")!)).toBe(true);
    expect(q.purge()).toHaveLength(0);
    expect(q.get("a")).toBeDefined();
  });

  it("purge retains a failed (unsynced) job so it can be retried", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.markFailed("a", "E_TRANSPORT", "no device");
    expect(q.get("a")?.retryCount).toBe(1);
    expect(q.purge()).toHaveLength(0);
    expect(q.get("a")).toBeDefined();
  });

  it("purge retains a canceled-but-unsynced job (cancellation must still sync)", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.cancel("a");
    expect(q.purge()).toHaveLength(0);
    expect(q.get("a")).toBeDefined();
  });

  it("only removes a job once it is printed AND synced", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.markPrinted("a", "2026-06-07T12:01:00.000Z");
    q.markSynced("a", "2026-06-07T12:02:00.000Z");
    expect(isHubDurable(q.get("a")!)).toBe(true);
    const removed = q.purge();
    expect(removed.map((j) => j.printJobId)).toEqual(["a"]);
    expect(q.get("a")).toBeUndefined();
  });

  it("markSynced is illegal before a terminal state", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    expect(() => q.markSynced("a", "2026-06-07T12:02:00.000Z")).toThrow(/terminal/);
  });

  it("remove() refuses to delete a protected job", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.markPrinted("a", "2026-06-07T12:01:00.000Z");
    expect(() => q.remove("a")).toThrow(/would lose work/);
    expect(q.get("a")).toBeDefined();
  });

  it("pending() lists exactly the jobs still needing work or Hub ack", () => {
    const q = newQueue();
    q.enqueue(makeJob("a")); // queued -> protected
    q.enqueue(makeJob("b"));
    q.markPrinted("b", "2026-06-07T12:01:00.000Z"); // printed unsynced -> protected
    q.enqueue(makeJob("c"));
    q.markPrinted("c", "2026-06-07T12:01:00.000Z");
    q.markSynced("c", "2026-06-07T12:02:00.000Z"); // durable -> not pending
    expect(q.pending().map((j) => j.printJobId).sort()).toEqual(["a", "b"]);
  });

  it("a partial predicate still cannot remove protected jobs", () => {
    const q = newQueue();
    q.enqueue(makeJob("a"));
    q.markPrinted("a", "t");
    q.markSynced("a", "t2");
    q.enqueue(makeJob("b")); // unsynced
    // Try to purge everything; only the durable one goes.
    const removed = q.purge(() => true);
    expect(removed.map((j) => j.printJobId)).toEqual(["a"]);
    expect(q.get("b")).toBeDefined();
  });
});
