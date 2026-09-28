/**
 * Durable `OfflinePolicyStore` over SQLite — the single-row table that makes the 24h offline
 * window honest across restarts. `recordHubContact` is monotonic-forward (a row write only ever
 * advances `last_hub_contact_at_ms`), so neither a relaunch nor a clock-skewed earlier value can
 * extend the offline grace window.
 */
import type { OfflinePolicyPersistedState, OfflinePolicyStore, StoreDurability } from '../domain';
import type { SqlDriver } from './sqlDriver';

interface OfflinePolicyRow extends Record<string, unknown> {
  last_hub_contact_at_ms: number | null;
  window_hours: number | null;
}

export class SqliteOfflinePolicyStore implements OfflinePolicyStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  getState(): OfflinePolicyPersistedState {
    const row = this.db.first<OfflinePolicyRow>(
      'SELECT last_hub_contact_at_ms, window_hours FROM offline_policy_state WHERE id = 1',
    );
    return {
      lastHubContactAtMs: row?.last_hub_contact_at_ms ?? null,
      ...(row?.window_hours != null ? { windowHours: row.window_hours } : {}),
    };
  }

  recordHubContact(atMs: number): void {
    // Monotonic-forward read-then-write (single-writer app store, same idiom as DeviceIdentity):
    // keep the GREATER of stored and incoming, so a stale/earlier value never wins.
    const current = this.getState().lastHubContactAtMs;
    const next = current === null ? atMs : Math.max(current, atMs);
    this.db.run(
      `INSERT INTO offline_policy_state (id, last_hub_contact_at_ms) VALUES (1, ?)
       ON CONFLICT(id) DO UPDATE SET last_hub_contact_at_ms = excluded.last_hub_contact_at_ms`,
      [next],
    );
  }

  setWindowHours(hours: number): void {
    this.db.run(
      `INSERT INTO offline_policy_state (id, window_hours) VALUES (1, ?)
       ON CONFLICT(id) DO UPDATE SET window_hours = excluded.window_hours`,
      [hours],
    );
  }
}
