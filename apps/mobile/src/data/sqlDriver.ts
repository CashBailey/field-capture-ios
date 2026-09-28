/**
 * Minimal synchronous SQL driver seam for the durable local store (req: SQLite or equivalent).
 *
 * The data layer is written against this tiny surface instead of native SQLite directly so that:
 *  - store logic runs against REAL SQL in jest (test-utils/betterSqliteDriver.ts wraps
 *    better-sqlite3 — same engine family, same SQL dialect) without native modules;
 *  - the production adapter (quickSqliteDriver.ts) stays a dumb pass-through.
 *
 * Synchronous on purpose: the domain store interfaces (`AssignmentStore`, `TicketEvidenceStore`)
 * are synchronous, and react-native-quick-sqlite exposes synchronous JSI execution.
 */

/** What may be bound as a statement parameter. (No booleans — store 0/1; keeps drivers honest.) */
export type SqlValue = string | number | null | Uint8Array;

export type SqlRow = Record<string, unknown>;

export interface SqlDriver {
  /** Execute one or more statements WITHOUT parameter binding (DDL / PRAGMA only). */
  exec(sql: string): void;
  /** Execute one write statement with positional `?` parameters. */
  run(sql: string, params?: readonly SqlValue[]): void;
  /** Query all rows. */
  all<T extends SqlRow = SqlRow>(sql: string, params?: readonly SqlValue[]): T[];
  /** Query the first row, or null. */
  first<T extends SqlRow = SqlRow>(sql: string, params?: readonly SqlValue[]): T | null;
  /** Run `fn` inside a transaction; rolls back if it throws, returns its result otherwise. */
  transaction<T>(fn: () => T): T;
}
