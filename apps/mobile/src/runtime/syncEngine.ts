/**
 * Full ADR 004 sync engine over the `SyncTransport` seam (`/sync/commands` + `/sync/changes`).
 * Drives the durable generic outbox and the down-sync frontier. LAYERS BESIDE the V1 submit
 * path — `OpsHubV1Client` + `RetryEngine` keep serving the minimal ticket route untouched.
 *
 * Push (up-sync) invariants:
 *  - Dispatch is dependency-ordered (`sync.planDispatch`): an item ships only after every
 *    parent committed; dead parents/cycles surface as `blocked` — reported, never dropped.
 *  - Items go in-flight BEFORE the network is touched and every outcome is folded through the
 *    contracts state machine (`applyCommandResult`) — an illegal transition throws rather than
 *    corrupting evidence.
 *  - A transport throw is transient for the WHOLE batch: every in-flight item returns to
 *    pending with full-jitter backoff and the SAME envelope (identical idempotency key), so a
 *    replay can never double-create on Hub. An auth failure returns items to pending WITHOUT a
 *    backoff stamp — they are due the moment re-auth lands.
 *  - Local state is preserved on every non-accepted outcome; only Hub's accept marks durable.
 *
 * Pull (down-sync) invariants:
 *  - Pull strictly after the STORED frontier; the next frontier is validated
 *    (`advanceFrontier` — monotonic, server-issued) BEFORE any change touches a local store.
 *  - A stale token resets the frontier (Hub's `resetTo`, else the zero token) and re-pulls
 *    once — never silently treated as an empty page.
 *  - `applyChanges` + frontier-advance commit in one transaction (the `transaction` seam), so the
 *    frontier never moves past changes that were not applied; `applyChanges` stays idempotent so a
 *    crash before the commit lands simply replays the same page on the next pull.
 */
import { sync } from '@fieldcapture/contracts';

import {
  HubAuthError,
  type DurableSyncOutboxItem,
  type SyncFrontierStore,
  type SyncOutboxStore,
} from '../domain';

export interface SyncEngineDeps {
  outbox: SyncOutboxStore;
  frontier: SyncFrontierStore;
  transport: sync.SyncTransport;
  /** Apply one page of authoritative changes to local read stores. MUST be idempotent. */
  applyChanges: (changes: readonly unknown[]) => void;
  /**
   * Run `fn` atomically (apply + frontier-advance in one DB transaction). Optional: tests pass
   * in-memory fakes and run `fn` directly. In production this is `db.transaction` so a crash can
   * never advance the frontier past changes that were not applied (and a future non-idempotent
   * consumer behind `applyChanges` can never be half-applied).
   */
  transaction?: <T>(fn: () => T) => T;
  policy?: sync.RetryPolicy;
  now?: () => Date;
  random?: () => number;
  /** Telemetry for non-fatal anomalies (e.g. Hub answered for an op we did not send). */
  onError?: (scope: string, error: unknown) => void;
  /** Fired when a NEW operation is enqueued — lets a runtime driver kick an immediate push. */
  onEnqueue?: () => void;
  /** Fired after a successful Hub exchange (commands or changes), for durable offline-policy state. */
  onHubContact?: (at: Date) => void;
}

export interface PushReport {
  /** Operations handed to the transport this pass. */
  submitted: number;
  accepted: number;
  rejected: number;
  needsReview: number;
  /** Returned to pending with a backoff stamp (transport failure / missing result). */
  rescheduled: number;
  /** Ready but still inside their backoff window — untouched this pass. */
  waitingBackoff: number;
  /** Waiting on a dependency that may yet commit. */
  waitingDependency: number;
  /** Permanently blocked (dead parent / dependency cycle) — surfaced for manual review. */
  blocked: { opId: string; reason: sync.BlockReason; deps: string[] }[];
  /** True when the transport saw a 401/403 — items are pending and due; re-auth then re-push. */
  authRequired: boolean;
}

export interface PullReport {
  applied: number;
  frontier: sync.ChangeToken;
  /** True when Hub declared the stored token stale and the frontier was reset before re-pulling. */
  frontierReset: boolean;
}

export class SyncEngine {
  private readonly policy: sync.RetryPolicy;
  private readonly now: () => Date;
  private readonly random: () => number;

  constructor(private readonly deps: SyncEngineDeps) {
    this.policy = deps.policy ?? sync.DEFAULT_RETRY_POLICY;
    this.now = deps.now ?? (() => new Date());
    this.random = deps.random ?? Math.random;
  }

  /**
   * Add one operation to the durable outbox. Validates write identity
   * (`assertEnvelopeConsistent`) and is idempotent on opId: re-enqueueing the same envelope
   * returns the existing row; a DIFFERENT envelope under the same opId throws.
   */
  enqueue(envelope: sync.OperationEnvelope): DurableSyncOutboxItem {
    sync.assertEnvelopeConsistent(envelope);
    const existing = this.deps.outbox.get(envelope.opId);
    if (existing !== undefined) {
      if (existing.envelope.idempotencyKey !== envelope.idempotencyKey) {
        throw new sync.OutboxError(
          `opId ${envelope.opId} is already queued with a different idempotency key`,
        );
      }
      return existing;
    }
    const at = this.now().toISOString();
    const item: DurableSyncOutboxItem = {
      envelope,
      state: 'pending',
      retryCount: 0,
      createdAt: at,
      updatedAt: at,
    };
    this.deps.outbox.save(item);
    this.deps.onEnqueue?.(); // kick a runtime driver (if any) to push the fresh work promptly
    return item;
  }

  /**
   * Boot sweep: orphaned in-flight rows (the app died before Hub's answer landed) return to
   * pending — the SAME idempotency key makes the re-send safe. MUST run before any push.
   */
  recoverOnStartup(): string[] {
    const recovery = sync.recoverOutboxOnRestart(this.deps.outbox.list());
    const at = this.now().toISOString();
    for (const item of recovery.items) {
      if (recovery.recoveredOpIds.includes(item.envelope.opId)) {
        this.deps.outbox.save({ ...(item as DurableSyncOutboxItem), updatedAt: at });
      }
    }
    return recovery.recoveredOpIds;
  }

  /** One push pass: dispatch every due, dependency-satisfied pending item as a single batch. */
  async pushOnce(): Promise<PushReport> {
    const report: PushReport = {
      submitted: 0,
      accepted: 0,
      rejected: 0,
      needsReview: 0,
      rescheduled: 0,
      waitingBackoff: 0,
      waitingDependency: 0,
      blocked: [],
      authRequired: false,
    };

    const items = this.deps.outbox.list();
    const plan = sync.planDispatch(items, this.deps.outbox.committedOpIds());
    report.waitingDependency = plan.waiting.length;
    report.blocked = plan.blocked.map((b) => ({
      opId: b.item.envelope.opId,
      reason: b.reason,
      deps: b.deps,
    }));

    const nowMs = this.now().getTime();
    const due: DurableSyncOutboxItem[] = [];
    for (const ready of plan.ready as DurableSyncOutboxItem[]) {
      if (ready.nextAttemptAtMs !== undefined && ready.nextAttemptAtMs > nowMs) {
        report.waitingBackoff += 1;
      } else {
        due.push(ready);
      }
    }
    if (due.length === 0) return report;

    const at = this.now().toISOString();
    const inFlight = due.map((item) => {
      // markInFlight spreads its input, so the durable fields survive; the cast restores the
      // narrower durable type the generic contracts signature cannot carry.
      const next: DurableSyncOutboxItem = {
        ...(sync.markInFlight(item) as DurableSyncOutboxItem),
        updatedAt: at,
      };
      this.deps.outbox.save(next);
      return next;
    });
    report.submitted = inFlight.length;

    let results: sync.CommandResult[];
    try {
      results = await this.deps.transport.submitBatch(inFlight.map((i) => i.envelope));
    } catch (error) {
      const auth = error instanceof HubAuthError;
      for (const item of inFlight) {
        this.rescheduleAfterTransportFailure(item, error, auth);
      }
      if (auth) {
        report.authRequired = true;
      } else {
        report.rescheduled = inFlight.length;
      }
      return report;
    }
    this.deps.onHubContact?.(this.now());

    const resultByOpId = new Map(results.map((r) => [r.opId, r]));
    for (const item of inFlight) {
      const result = resultByOpId.get(item.envelope.opId);
      if (result === undefined) {
        // Hub answered the batch but omitted this op — transient for THIS op only.
        this.rescheduleAfterTransportFailure(
          item,
          new Error('no result for op in commands response'),
          false,
        );
        report.rescheduled += 1;
        continue;
      }
      resultByOpId.delete(item.envelope.opId);
      const folded = sync.applyCommandResult(item, result) as DurableSyncOutboxItem;
      const next: DurableSyncOutboxItem = {
        ...folded,
        updatedAt: this.now().toISOString(),
        // Preserve Hub's reason verbatim where the state machine has no field for it.
        ...(result.outcome === 'needs-review' ? { lastError: result.reviewReason } : {}),
        ...(result.outcome === 'rejected' && result.detail !== undefined
          ? { lastError: result.detail }
          : {}),
      };
      this.deps.outbox.save(next);
      if (result.outcome === 'accepted') report.accepted += 1;
      else if (result.outcome === 'rejected') report.rejected += 1;
      else report.needsReview += 1;
    }
    for (const orphan of resultByOpId.keys()) {
      this.deps.onError?.('push', new Error(`Hub returned a result for unknown op ${orphan}`));
    }
    return report;
  }

  /** Return an in-flight item to pending. Auth failures skip the backoff stamp — the item is
   *  due the moment a fresh token exists; everything else gets full-jitter backoff. */
  private rescheduleAfterTransportFailure(
    item: DurableSyncOutboxItem,
    error: unknown,
    authFailure: boolean,
  ): void {
    const retried = sync.markForRetry(item) as DurableSyncOutboxItem;
    const rest = { ...retried };
    delete rest.nextAttemptAtMs;
    const base: DurableSyncOutboxItem = {
      ...rest,
      updatedAt: this.now().toISOString(),
      lastError: String(error),
    };
    this.deps.outbox.save(
      authFailure
        ? base
        : {
            ...base,
            nextAttemptAtMs: sync.computeNextAttemptAtMs(
              this.now().getTime(),
              Math.max(0, base.retryCount - 1),
              this.random,
              this.policy,
            ),
          },
    );
  }

  /**
   * One pull pass: fetch the page after the stored frontier, validate the next token, apply,
   * persist. On a stale token: reset the frontier and re-pull once in the same pass.
   */
  async pullOnce(): Promise<PullReport> {
    const since = this.deps.frontier.get() ?? sync.ZERO_CHANGE_TOKEN;
    let frontierReset = false;
    let effectiveSince = since;
    let page: sync.ChangePage;
    try {
      page = await this.deps.transport.pullChanges(since);
    } catch (error) {
      if (!(error instanceof sync.StaleChangeTokenError)) throw error;
      effectiveSince = error.resetTo ?? sync.ZERO_CHANGE_TOKEN;
      this.deps.frontier.set(effectiveSince); // the one legitimate non-monotonic write
      frontierReset = true;
      page = await this.deps.transport.pullChanges(effectiveSince);
    }
    this.deps.onHubContact?.(this.now());
    // Validate BEFORE applying — a regressed/garbage token must not let changes touch stores.
    const nextFrontier = sync.advanceFrontier(effectiveSince, page.token);
    // Apply + advance the frontier atomically: the frontier must never move past changes that were
    // not durably applied. Without a transaction seam (test fakes) the two run back-to-back and the
    // engine's idempotent re-delivery still covers a crash between them.
    const commit = (): void => {
      this.deps.applyChanges(page.changes);
      this.deps.frontier.set(nextFrontier);
    };
    if (this.deps.transaction !== undefined) this.deps.transaction(commit);
    else commit();
    return { applied: page.changes.length, frontier: nextFrontier, frontierReset };
  }

  /** Push then pull. A pull failure is reported via onError, never masks the push report. */
  async syncOnce(): Promise<{ push: PushReport; pull?: PullReport }> {
    const push = await this.pushOnce();
    try {
      return { push, pull: await this.pullOnce() };
    } catch (error) {
      // A pull-leg auth failure must pause the driver too: pushOnce sets authRequired on the push
      // leg, but a pass with nothing to push would otherwise 401 on pull every tick. Surface it.
      if (error instanceof HubAuthError) push.authRequired = true;
      this.deps.onError?.('pull', error);
      return { push };
    }
  }
}
