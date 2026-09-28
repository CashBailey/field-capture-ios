/**
 * Restart recovery (ADR 004): what happens to durable outbox rows when the app comes back up
 * after being killed. Pure — takes rows, returns rows; persistence is the caller's job.
 *
 * Policy (ops-triad-contract.md "in-flight orphan recovery on restart"):
 *   pending      -> stays pending (the dispatch loop will pick it up)
 *   in-flight    -> swept back to pending for retry (the app died before Hub's answer landed;
 *                   the SAME idempotency key makes the re-send safe — Hub dedupes)
 *   accepted     -> stays accepted (done)
 *   rejected / needs-review -> stay frozen (terminal; manual review, never silent resubmission)
 *
 * The sweep MUST run before any dispatch path executes, or orphaned in-flight rows deadlock
 * against the double-submit guard ("already-in-flight") forever.
 */
import { markForRetry } from "./outbox";
import type { OutboxItem } from "./types";

export interface RestartRecovery<TPayload = unknown> {
  /** Every input row, post-sweep, in input order. */
  items: OutboxItem<TPayload>[];
  /** opIds that were orphaned in-flight and have been returned to pending. */
  recoveredOpIds: string[];
}

export function recoverOutboxOnRestart<TPayload>(
  items: readonly OutboxItem<TPayload>[],
): RestartRecovery<TPayload> {
  const recoveredOpIds: string[] = [];
  const swept = items.map((item) => {
    if (item.state !== "in-flight") return item;
    recoveredOpIds.push(item.envelope.opId);
    return markForRetry(item); // pending, retryCount+1 — the interrupted attempt counts
  });
  return { items: swept, recoveredOpIds };
}
