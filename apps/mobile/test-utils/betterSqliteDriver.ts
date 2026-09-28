/**
 * Test-only `SqlDriver` over better-sqlite3 — real SQL in jest without native modules.
 * Production uses quickSqliteDriver; both are dumb pass-throughs over the same seam, so the
 * store logic exercised here is exactly what runs on-device.
 */
import Database from 'better-sqlite3';

import type { SqlDriver, SqlRow, SqlValue } from '../src/data/sqlDriver';

export interface TestSqlDriver extends SqlDriver {
  close(): void;
}

export function betterSqliteDriver(filename = ':memory:'): TestSqlDriver {
  const db = new Database(filename);
  return {
    exec(sql) {
      db.exec(sql);
    },
    run(sql, params = []) {
      db.prepare(sql).run(...params);
    },
    all<T extends SqlRow>(sql: string, params: readonly SqlValue[] = []) {
      return db.prepare(sql).all(...params) as T[];
    },
    first<T extends SqlRow>(sql: string, params: readonly SqlValue[] = []) {
      return (db.prepare(sql).get(...params) as T | undefined) ?? null;
    },
    transaction<T>(fn: () => T): T {
      return db.transaction(fn)();
    },
    close() {
      db.close();
    },
  };
}
