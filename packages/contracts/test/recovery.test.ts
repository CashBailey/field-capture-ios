import { describe, it, expect } from "vitest";
import {
  buildIdempotencyKey,
  recoverOutboxOnRestart,
  type OutboxItem,
  type OutboxItemState,
} from "../src/sync/index.js";

function item(opId: string, localSeq: number, state: OutboxItemState, retryCount = 0): OutboxItem {
  return {
    envelope: {
      opId,
      kind: "command",
      type: "ticket.submit",
      idempotencyKey: buildIdempotencyKey("dev-1", localSeq, opId),
      localSeq,
      dependsOn: [],
      payload: {},
    },
    state,
    retryCount,
  };
}

describe("restart recovery sweep (pending→retry, in-flight→retry, terminal stays)", () => {
  it("sweeps orphaned in-flight rows back to pending with the SAME idempotency key", () => {
    const orphan = item("op-b", 2, "in-flight", 1);
    const { items, recoveredOpIds } = recoverOutboxOnRestart([orphan]);
    expect(recoveredOpIds).toEqual(["op-b"]);
    expect(items[0]).toMatchObject({ state: "pending", retryCount: 2 });
    // identity untouched — Hub can still dedupe a re-send of the interrupted attempt
    expect(items[0]?.envelope.idempotencyKey).toBe(orphan.envelope.idempotencyKey);
  });

  it("leaves pending rows queued and terminal rows frozen", () => {
    const rows = [
      item("op-pending", 1, "pending"),
      item("op-accepted", 2, "accepted"),
      item("op-rejected", 3, "rejected"),
      item("op-review", 4, "needs-review"),
    ];
    const { items, recoveredOpIds } = recoverOutboxOnRestart(rows);
    expect(recoveredOpIds).toEqual([]);
    expect(items.map((i) => i.state)).toEqual(["pending", "accepted", "rejected", "needs-review"]);
    // untouched rows are the same objects — the sweep never rewrites what it does not recover
    expect(items[0]).toBe(rows[0]);
    expect(items[1]).toBe(rows[1]);
  });

  it("never mutates its inputs", () => {
    const orphan = item("op-x", 5, "in-flight");
    recoverOutboxOnRestart([orphan]);
    expect(orphan.state).toBe("in-flight");
    expect(orphan.retryCount).toBe(0);
  });
});
