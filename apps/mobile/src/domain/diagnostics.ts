/**
 * Diagnostic logs + a copy-pasteable diagnostic report (spec 7.15 Sync Center / §4f-g). The
 * Sync Center and More screens expose a "copy diagnostic" affordance; this is the durable backing
 * store for it plus the pure formatter that assembles a report. SECRET-FREE by construction: the
 * report never includes bearer tokens, passwords, or full payloads — only counts, states, and
 * timestamps an office can act on.
 */
import type { StoreDurability } from './hubGateway';

export type DiagnosticLevel = 'info' | 'warning' | 'error';

export interface DiagnosticLog {
  id: string;
  level: DiagnosticLevel;
  /** Short human-facing message. Callers must NOT put secrets/tokens here. */
  message: string;
  /** Optional small context (codes, ids, counts) — never tokens or full payloads. */
  context?: Record<string, unknown>;
  createdAt: string;
}

export interface DiagnosticLogStore {
  readonly durability: StoreDurability;
  /** Append a log entry (append-only; diagnostic logs may be rotated, never field WORK). */
  record(entry: DiagnosticLog): void;
  /** The most recent entries, newest first, capped at `limit`. */
  recent(limit: number): DiagnosticLog[];
  count(): number;
}

/** In-memory test seam — explicitly volatile. */
export class VolatileDiagnosticLogStore implements DiagnosticLogStore {
  readonly durability = 'volatile-memory' as const;
  private readonly rows: DiagnosticLog[] = [];

  record(entry: DiagnosticLog): void {
    this.rows.push({ ...entry });
  }
  recent(limit: number): DiagnosticLog[] {
    return this.rows
      .slice(-Math.max(0, limit))
      .reverse()
      .map((row) => ({ ...row }));
  }
  count(): number {
    return this.rows.length;
  }
}

export interface DiagnosticReportInput {
  appEnv: string;
  hubUrl: string | null;
  storageDurability: StoreDurability;
  /** Last successful Hub contact (epoch ms) or null. */
  lastHubContactAtMs: number | null;
  /** Offline-policy state label (online / offline-within-limit / offline-over-limit). */
  offlinePolicyState: string;
  /** Outbox rollup counts (Sync Center categories → counts). */
  counts: Readonly<Record<string, number>>;
  recentLogs: readonly DiagnosticLog[];
  /** Stamp for the report header (epoch ms). Injected, never read from a global clock. */
  generatedAtMs: number;
}

/**
 * Assemble a copy-pasteable, SECRET-FREE diagnostic report. Defensive redaction: any context key
 * that looks like a credential is dropped, so a careless caller can never leak a token here.
 */
export function buildDiagnosticReport(input: DiagnosticReportInput): string {
  const lines: string[] = [];
  lines.push('Field Capture diagnostic');
  lines.push(`generated: ${new Date(input.generatedAtMs).toISOString()}`);
  lines.push(`hub env: ${input.appEnv}`);
  lines.push(`hub url: ${input.hubUrl ?? 'not configured'}`);
  lines.push(`local storage: ${input.storageDurability}`);
  lines.push(
    `last hub contact: ${
      input.lastHubContactAtMs === null ? 'never' : new Date(input.lastHubContactAtMs).toISOString()
    }`,
  );
  lines.push(`offline policy: ${input.offlinePolicyState}`);
  lines.push('queues:');
  for (const [key, value] of Object.entries(input.counts)) lines.push(`  ${key}: ${value}`);
  if (input.recentLogs.length > 0) {
    lines.push('recent:');
    for (const log of input.recentLogs) {
      const ctx = log.context !== undefined ? ` ${JSON.stringify(redactSecrets(log.context))}` : '';
      lines.push(`  [${log.level}] ${log.createdAt} ${log.message}${ctx}`);
    }
  }
  return lines.join('\n');
}

const SECRET_KEY = /(token|secret|password|authorization|bearer|key)/i;

function redactSecrets(context: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(context)) {
    out[key] = SECRET_KEY.test(key) ? '[redacted]' : value;
  }
  return out;
}
