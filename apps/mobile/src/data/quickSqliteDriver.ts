/**
 * Production `SqlDriver` over react-native-quick-sqlite's synchronous JSI API.
 * Store logic remains behind the tiny `SqlDriver` seam so tests still run against better-sqlite3.
 */
import { QuickSQLite } from 'react-native-quick-sqlite';

import type { SqlDriver, SqlRow, SqlValue } from './sqlDriver';

function params(values: readonly SqlValue[]): unknown[] {
  return values.map((value) => (value instanceof Uint8Array ? Array.from(value) : value));
}

function statements(sql: string): string[] {
  return sql
    .split(';')
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

export function quickSqliteDriver(databaseName: string): SqlDriver {
  return {
    exec(sql) {
      for (const statement of statements(sql)) {
        QuickSQLite.execute(databaseName, statement);
      }
    },
    run(sql, bound = []) {
      QuickSQLite.execute(databaseName, sql, params(bound));
    },
    all<T extends SqlRow>(sql: string, bound: readonly SqlValue[] = []) {
      const rows = QuickSQLite.execute(databaseName, sql, params(bound)).rows?._array ?? [];
      return rows as T[];
    },
    first<T extends SqlRow>(sql: string, bound: readonly SqlValue[] = []) {
      const rows = QuickSQLite.execute(databaseName, sql, params(bound)).rows?._array ?? [];
      return (rows[0] as T | undefined) ?? null;
    },
    transaction<T>(fn: () => T): T {
      QuickSQLite.execute(databaseName, 'BEGIN IMMEDIATE');
      try {
        const result = fn();
        QuickSQLite.execute(databaseName, 'COMMIT');
        return result;
      } catch (error) {
        QuickSQLite.execute(databaseName, 'ROLLBACK');
        throw error;
      }
    },
  };
}

export function openQuickSqliteDriver(databaseName: string): SqlDriver {
  QuickSQLite.open(databaseName);
  return quickSqliteDriver(databaseName);
}

export function deleteQuickSqliteDatabase(databaseName: string): void {
  QuickSQLite.delete(databaseName);
}
