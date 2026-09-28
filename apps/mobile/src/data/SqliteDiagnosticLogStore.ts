/**
 * Durable diagnostic-log store over SQLite (§4f-g) — append-only entries backing the Sync Center /
 * More copy-diagnostic export. `recent(n)` returns the newest entries first.
 */
import type {
  DiagnosticLevel,
  DiagnosticLog,
  DiagnosticLogStore,
  StoreDurability,
} from '../domain';
import type { SqlDriver } from './sqlDriver';

interface LogRow extends Record<string, unknown> {
  id: string;
  level: string;
  message: string;
  context_json: string | null;
  created_at: string;
}

function fromRow(row: LogRow): DiagnosticLog {
  return {
    id: row.id,
    level: row.level as DiagnosticLevel,
    message: row.message,
    ...(row.context_json !== null
      ? { context: JSON.parse(row.context_json) as Record<string, unknown> }
      : {}),
    createdAt: row.created_at,
  };
}

export class SqliteDiagnosticLogStore implements DiagnosticLogStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  record(entry: DiagnosticLog): void {
    this.db.run(
      `INSERT OR REPLACE INTO diagnostic_logs (id, level, message, context_json, created_at)
       VALUES (?, ?, ?, ?, ?)`,
      [
        entry.id,
        entry.level,
        entry.message,
        entry.context !== undefined ? JSON.stringify(entry.context) : null,
        entry.createdAt,
      ],
    );
  }

  recent(limit: number): DiagnosticLog[] {
    return this.db
      .all<LogRow>(
        'SELECT id, level, message, context_json, created_at FROM diagnostic_logs ORDER BY created_at DESC, id DESC LIMIT ?',
        [Math.max(0, limit)],
      )
      .map(fromRow);
  }

  count(): number {
    return this.db.first<{ n: number }>('SELECT COUNT(*) AS n FROM diagnostic_logs')?.n ?? 0;
  }
}
