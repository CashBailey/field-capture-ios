/**
 * Domain seams for the full ADR 004 sync engine: the generic durable operation outbox (every
 * command/event the phone owes Hub) and the down-sync frontier (the server-issued change token
 * the next pull resumes after). Pure interfaces + volatile test seams — NO SQL, NO network here.
 * Production uses `data/SqliteSyncOutboxStore` / `data/SqliteSyncFrontierStore`.
 */
import { sync } from '@fieldcapture/contracts';

import type { StoreDurability } from './hubGateway';

/**
 * A durable outbox row: the contracts `OutboxItem` plus the engine's backoff stamp. Timestamps
 * are required here — durable rows must always say when they were created/last changed.
 */
export interface DurableSyncOutboxItem extends sync.OutboxItem {
  createdAt: string;
  updatedAt: string;
  /** Epoch ms before which the engine must not redispatch (full-jitter backoff). */
  nextAttemptAtMs?: number;
}

export interface SyncOutboxStore {
  readonly durability: StoreDurability;
  save(item: DurableSyncOutboxItem): void;
  get(opId: string): DurableSyncOutboxItem | undefined;
  list(): DurableSyncOutboxItem[];
  listByState(state: sync.OutboxItemState): DurableSyncOutboxItem[];
  /**
   * opIds of accepted parents that were PRUNED from the outbox (the committed-op ledger).
   * `planDispatch` needs these so a dependent enqueued after its parent was pruned still
   * resolves as satisfied instead of surfacing as a dead dependency.
   */
  committedOpIds(): Set<string>;
}

/** In-memory outbox. VOLATILE — TEST SEAM ONLY (mirrors VolatileTicketEvidenceStore). */
export class VolatileSyncOutboxStore implements SyncOutboxStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private byOpId = new Map<string, DurableSyncOutboxItem>();
  private committed = new Set<string>();

  save(item: DurableSyncOutboxItem): void {
    this.byOpId.set(item.envelope.opId, item);
  }

  get(opId: string): DurableSyncOutboxItem | undefined {
    return this.byOpId.get(opId);
  }

  list(): DurableSyncOutboxItem[] {
    return [...this.byOpId.values()];
  }

  listByState(state: sync.OutboxItemState): DurableSyncOutboxItem[] {
    return this.list().filter((item) => item.state === state);
  }

  committedOpIds(): Set<string> {
    return new Set(this.committed);
  }

  /** Test helper mirroring the durable store's prune-to-ledger move. */
  markCommittedAndRemove(opId: string): void {
    this.byOpId.delete(opId);
    this.committed.add(opId);
  }
}

export interface SyncFrontierStore {
  readonly durability: StoreDurability;
  /** The stored frontier, or undefined before the first successful pull. */
  get(): sync.ChangeToken | undefined;
  /** Persist a new frontier. Monotonicity is the ENGINE's job (advanceFrontier); a reset after
   *  a stale-token answer is the one legitimate non-monotonic write. */
  set(token: sync.ChangeToken): void;
}

/** In-memory frontier. VOLATILE — TEST SEAM ONLY. */
export class VolatileSyncFrontierStore implements SyncFrontierStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private token: sync.ChangeToken | undefined;

  get(): sync.ChangeToken | undefined {
    return this.token === undefined ? undefined : { ...this.token };
  }

  set(token: sync.ChangeToken): void {
    this.token = { ...token };
  }
}
