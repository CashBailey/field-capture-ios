/**
 * Durable `SyncFrontierStore` over SQLite — the single-row table holding the server-issued
 * change token the next `/sync/changes` pull resumes after. Monotonicity is enforced by the
 * engine (`sync.advanceFrontier`); the one legitimate non-monotonic write is the explicit reset
 * after Hub declares the stored token stale.
 */
import type { sync } from '@fieldcapture/contracts';

import type { StoreDurability, SyncFrontierStore } from '../domain';
import type { SqlDriver } from './sqlDriver';

export class SqliteSyncFrontierStore implements SyncFrontierStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  get(): sync.ChangeToken | undefined {
    const row = this.db.first<{ authority_epoch: number; commit_seq: number }>(
      'SELECT authority_epoch, commit_seq FROM sync_frontier WHERE id = 1',
    );
    return row === null
      ? undefined
      : { authorityEpoch: row.authority_epoch, commitSeq: row.commit_seq };
  }

  set(token: sync.ChangeToken): void {
    this.db.run(
      `INSERT INTO sync_frontier (id, authority_epoch, commit_seq) VALUES (1, ?, ?)
       ON CONFLICT(id) DO UPDATE SET authority_epoch = excluded.authority_epoch,
                                     commit_seq      = excluded.commit_seq`,
      [token.authorityEpoch, token.commitSeq],
    );
  }
}
