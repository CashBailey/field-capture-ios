/**
 * Outbox behaviour (ADR 004): the durable, ordered, dependency-aware queue of commands/events
 * the phone submits to Hub. Pure contracts only — NO persistence, NO network. This module owns:
 *
 *   1. Envelope consistency invariants (write identity is internally coherent before it queues).
 *   2. The outbox item state machine (which transitions are legal).
 *   3. Dispatch planning: which items may be sent now, in `local_seq` order, gated on their
 *      dependencies — and which are permanently blocked (a parent that can never commit, or a
 *      dependency cycle), so they surface for review instead of retrying forever.
 *
 * Cross-cutting invariant #2 ("never silently lose work"): a blocked item is never dropped; it is
 * reported so a later engine slice can route it to manual review (report 03: "any command depends
 * on a parent object that never committed" → manual review).
 */
import { parseIdempotencyKey } from "./idempotency";
import type {
  ChangeToken,
  CommandResult,
  OperationEnvelope,
  OutboxItem,
  OutboxItemState,
} from "./types";

export class OutboxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OutboxError";
  }
}

// ---- envelope consistency ----

/**
 * Assert one envelope is internally coherent before it enters the outbox. This is write-identity
 * hygiene, not business validation (Hub still authoritatively validates the operation):
 * - opId non-empty; localSeq a non-negative integer;
 * - idempotencyKey parses AND its embedded local_seq matches the envelope's (one source of truth);
 * - dependsOn has no self-reference and no duplicates;
 * - immutable events carry no version precondition (append-only; preconditions are for mutable edits).
 */
export function assertEnvelopeConsistent(env: OperationEnvelope): void {
  if (!env.opId) throw new OutboxError("envelope.opId must be non-empty");
  if (!Number.isInteger(env.localSeq) || env.localSeq < 0) {
    throw new OutboxError("envelope.localSeq must be a non-negative integer");
  }
  // Throws IdempotencyKeyError if malformed — a malformed key IS an identity error.
  const parsed = parseIdempotencyKey(env.idempotencyKey);
  if (parsed.localSeq !== env.localSeq) {
    throw new OutboxError(
      `idempotencyKey local_seq (${parsed.localSeq}) disagrees with envelope.localSeq (${env.localSeq})`,
    );
  }
  if (env.dependsOn.includes(env.opId)) {
    throw new OutboxError(`envelope ${env.opId} depends on itself`);
  }
  if (new Set(env.dependsOn).size !== env.dependsOn.length) {
    throw new OutboxError(`envelope ${env.opId} has duplicate dependsOn entries`);
  }
  if (env.kind === "event" && env.precondition !== undefined) {
    throw new OutboxError(
      `immutable event ${env.opId} must not carry a version precondition (append-only)`,
    );
  }
}

// ---- state machine ----

/**
 * Legal outbox transitions. `pending` → dispatched (`in-flight`) or locally retired
 * (`rejected`/`needs-review`, e.g. a dead dependency). `in-flight` → a Hub outcome, or back to
 * `pending` for a transient retry. `accepted`/`rejected`/`needs-review` are terminal.
 */
const OUTBOX_TRANSITIONS: Record<OutboxItemState, readonly OutboxItemState[]> = {
  pending: ["in-flight", "rejected", "needs-review"],
  "in-flight": ["accepted", "rejected", "needs-review", "pending"],
  accepted: [],
  rejected: [],
  "needs-review": [],
};

export function canTransition(from: OutboxItemState, to: OutboxItemState): boolean {
  return OUTBOX_TRANSITIONS[from].includes(to);
}

export function assertTransition(from: OutboxItemState, to: OutboxItemState): void {
  if (!canTransition(from, to)) {
    throw new OutboxError(`illegal outbox transition: ${from} -> ${to}`);
  }
}

/** Mark an item dispatched. Must be `pending`. Returns a new item (inputs are never mutated). */
export function markInFlight<T>(item: OutboxItem<T>): OutboxItem<T> {
  assertTransition(item.state, "in-flight");
  return { ...item, state: "in-flight" };
}

/** Return an in-flight item to the queue for a transient retry (network/5xx/429), bumping retryCount. */
export function markForRetry<T>(item: OutboxItem<T>): OutboxItem<T> {
  assertTransition(item.state, "pending");
  return { ...item, state: "pending", retryCount: item.retryCount + 1 };
}

/**
 * Fold a Hub `CommandResult` into the outbox item. The item must be `in-flight`. `accepted` records
 * the committed change token; `rejected` records the machine-readable code; `needs-review` freezes
 * it for manual resolution. Never auto-merges (ADR 004).
 */
export function applyCommandResult<T>(
  item: OutboxItem<T>,
  result: CommandResult<T>,
): OutboxItem<T> {
  if (result.opId !== item.envelope.opId) {
    throw new OutboxError(
      `CommandResult opId ${result.opId} does not match item ${item.envelope.opId}`,
    );
  }
  switch (result.outcome) {
    case "accepted":
      assertTransition(item.state, "accepted");
      return { ...item, state: "accepted", committedToken: result.token };
    case "rejected":
      assertTransition(item.state, "rejected");
      return { ...item, state: "rejected", rejectionCode: result.rejectionCode };
    case "needs-review":
      assertTransition(item.state, "needs-review");
      return { ...item, state: "needs-review" };
    default: {
      // Exhaustiveness guard (cross-cutting #2): a future wire-deserialized outcome fails loud
      // rather than silently returning undefined and dropping the Hub result.
      const _exhaustive: never = result;
      void _exhaustive;
      throw new OutboxError(`unknown command outcome: ${(result as { outcome: string }).outcome}`);
    }
  }
}

// ---- dispatch planning ----

export type BlockReason = "dead-dependency" | "dependency-cycle";

export interface BlockedItem<TPayload = unknown> {
  item: OutboxItem<TPayload>;
  reason: BlockReason;
  /** The dependency opIds responsible for the block (dead parents, or cycle members). */
  deps: string[];
}

export interface DispatchPlan<TPayload = unknown> {
  /** `pending` items whose dependencies are all satisfied — send these, in `local_seq` order. */
  ready: OutboxItem<TPayload>[];
  /** `pending` items still waiting on a dependency that may yet commit. */
  waiting: OutboxItem<TPayload>[];
  /** `pending` items that can never proceed (dead parent or cycle) — route to review, never retry. */
  blocked: BlockedItem<TPayload>[];
}

/**
 * Kahn's algorithm over the *pending* sub-graph. Any node left with a positive in-degree is in a
 * dependency cycle or transitively behind one — i.e. it can never be topologically ordered, so it
 * can never become ready. In-flight items are deliberately excluded: an item only reaches in-flight
 * after a prior plan found it `ready` (all deps satisfied), so it cannot be a live cycle member, and
 * its Hub outcome is still unknown — a pending item behind it should `wait`, not be declared a
 * permanent cycle.
 */
function unorderableOpIds<T>(items: readonly OutboxItem<T>[]): Set<string> {
  const nodeIds = new Set<string>();
  for (const it of items) {
    if (it.state === "pending") nodeIds.add(it.envelope.opId);
  }
  const indegree = new Map<string, number>();
  const dependents = new Map<string, string[]>();
  for (const id of nodeIds) {
    indegree.set(id, 0);
    dependents.set(id, []);
  }
  for (const it of items) {
    const id = it.envelope.opId;
    if (!nodeIds.has(id)) continue;
    for (const dep of it.envelope.dependsOn) {
      if (!nodeIds.has(dep)) continue; // only in-set deps form cycle edges
      indegree.set(id, (indegree.get(id) ?? 0) + 1);
      dependents.get(dep)?.push(id);
    }
  }
  const queue: string[] = [];
  for (const [id, deg] of indegree) if (deg === 0) queue.push(id);
  while (queue.length > 0) {
    const id = queue.shift() as string;
    for (const succ of dependents.get(id) ?? []) {
      const deg = (indegree.get(succ) ?? 0) - 1;
      indegree.set(succ, deg);
      if (deg === 0) queue.push(succ);
    }
  }
  const unorderable = new Set<string>();
  for (const [id, deg] of indegree) if (deg > 0) unorderable.add(id);
  return unorderable;
}

/**
 * Classify every `pending` item as ready / waiting / blocked, gated on its dependencies. A
 * dependency is *satisfied* if it already committed (in `committedOpIds`, for parents already
 * pruned from the outbox) or is present and `accepted`; *dead* if present and terminally
 * rejected/under-review, or absent entirely (a parent that never committed); otherwise it is still
 * in flight and the dependent *waits*. `ready` is returned in ascending `local_seq` order (report
 * 03: process in `local_seq` order). In-flight and terminal items are not returned — they are not
 * candidates for dispatch. Throws on a duplicate opId (the outbox must have unique write identity).
 */
export function planDispatch<T>(
  items: readonly OutboxItem<T>[],
  committedOpIds: ReadonlySet<string> = new Set(),
): DispatchPlan<T> {
  const byOpId = new Map<string, OutboxItem<T>>();
  for (const it of items) {
    if (byOpId.has(it.envelope.opId)) {
      throw new OutboxError(`duplicate opId in outbox: ${it.envelope.opId}`);
    }
    byOpId.set(it.envelope.opId, it);
  }

  const unorderable = unorderableOpIds(items);
  const ready: OutboxItem<T>[] = [];
  const waiting: OutboxItem<T>[] = [];
  const blocked: BlockedItem<T>[] = [];

  for (const it of items) {
    if (it.state !== "pending") continue;
    const opId = it.envelope.opId;

    if (unorderable.has(opId)) {
      // Report every culprit: cycle members AND any genuinely-dead parent (absent, or terminally
      // rejected/under-review), so a reviewer sees the full reason — not just the cycle edge.
      const culprits = it.envelope.dependsOn.filter((d) => {
        if (committedOpIds.has(d)) return false;
        if (unorderable.has(d)) return true;
        const parent = byOpId.get(d);
        return parent === undefined || parent.state === "rejected" || parent.state === "needs-review";
      });
      blocked.push({ item: it, reason: "dependency-cycle", deps: culprits });
      continue;
    }

    const dead: string[] = [];
    let anyWaiting = false;
    for (const dep of it.envelope.dependsOn) {
      if (committedOpIds.has(dep)) continue; // already committed and pruned
      const parent = byOpId.get(dep);
      if (parent === undefined) {
        dead.push(dep); // never committed, not in outbox
      } else if (parent.state === "accepted") {
        continue; // satisfied
      } else if (parent.state === "rejected" || parent.state === "needs-review") {
        dead.push(dep); // will never commit
      } else {
        anyWaiting = true; // pending / in-flight — may yet commit
      }
    }

    if (dead.length > 0) {
      blocked.push({ item: it, reason: "dead-dependency", deps: dead });
    } else if (anyWaiting) {
      waiting.push(it);
    } else {
      ready.push(it);
    }
  }

  ready.sort((a, b) => a.envelope.localSeq - b.envelope.localSeq);
  return { ready, waiting, blocked };
}

/** Convenience: the committed change tokens of all `accepted` items, in commit order. */
export function committedTokens<T>(items: readonly OutboxItem<T>[]): ChangeToken[] {
  const tokens: ChangeToken[] = [];
  for (const it of items) {
    if (it.state === "accepted" && it.committedToken !== undefined) tokens.push(it.committedToken);
  }
  return tokens;
}
