/**
 * Durable `AssignmentStore` over the local SQLite database. Hub is the authority on assignment:
 * each successful pull wholesale-replaces the cached set (in one transaction, so a crash mid-
 * replace can never leave a half-merged cache). Snapshots are stored verbatim as JSON — Mobile
 * never edits or merges them (contract boundary).
 */
import type { AssignmentDetails, AssignmentStore, HubAssignment, StoreDurability } from '../domain';
import type { SqlDriver } from './sqlDriver';

interface AssignmentRow extends Record<string, unknown> {
  service_request_id: string;
  snapshot_hash: string;
  snapshot_json: string;
  latest_server_version: string | null;
  rich_json: string;
}

export class SqliteAssignmentStore implements AssignmentStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
    private readonly now: () => Date = () => new Date(),
  ) {}

  putAssignments(assignments: readonly HubAssignment[]): void {
    const at = this.now().toISOString();
    this.db.transaction(() => {
      this.db.run('DELETE FROM assignments');
      for (const a of assignments) {
        // OR REPLACE: a duplicated SR in one Hub payload (server bug) must not abort the whole
        // refresh with a PK violation — last entry wins, matching the volatile test seam.
        this.db.run(
          `INSERT OR REPLACE INTO assignments (
             service_request_id, snapshot_hash, snapshot_json, latest_server_version, rich_json, updated_at
           )
           VALUES (?, ?, ?, ?, ?, ?)`,
          [
            a.serviceRequestId,
            a.snapshotHash,
            JSON.stringify(a.snapshot ?? null),
            a.latestServerVersion ?? null,
            JSON.stringify(a.details ?? {}),
            at,
          ],
        );
      }
    });
  }

  listAssignments(): HubAssignment[] {
    const rows = this.db.all<AssignmentRow>(
      `SELECT service_request_id, snapshot_hash, snapshot_json, latest_server_version, rich_json
         FROM assignments
        ORDER BY service_request_id`,
    );
    return rows.map((r) => {
      const parsedDetails = JSON.parse(r.rich_json) as Partial<AssignmentDetails>;
      const details =
        typeof parsedDetails === 'object' &&
        parsedDetails !== null &&
        Object.keys(parsedDetails).length > 0
          ? (parsedDetails as AssignmentDetails)
          : undefined;
      return {
        serviceRequestId: r.service_request_id,
        snapshotHash: r.snapshot_hash,
        snapshot: JSON.parse(r.snapshot_json) as unknown,
        ...(r.latest_server_version !== null
          ? { latestServerVersion: r.latest_server_version }
          : {}),
        ...(details !== undefined ? { details } : {}),
      };
    });
  }

  getSnapshotHash(serviceRequestId: string): string | undefined {
    const row = this.db.first<{ snapshot_hash: string }>(
      'SELECT snapshot_hash FROM assignments WHERE service_request_id = ?',
      [serviceRequestId],
    );
    return row?.snapshot_hash;
  }
}
