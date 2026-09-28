/**
 * Diagnostic logs + report (§4f-g). The report must be copy-pasteable AND secret-free.
 */
import {
  buildDiagnosticReport,
  VolatileDiagnosticLogStore,
  type DiagnosticLog,
} from '../src/domain';

const T0 = 1_750_000_000_000;

function log(id: string, message: string, context?: Record<string, unknown>): DiagnosticLog {
  return {
    id,
    level: 'info',
    message,
    ...(context ? { context } : {}),
    createdAt: '2026-06-15T03:00:00.000Z',
  };
}

describe('VolatileDiagnosticLogStore', () => {
  it('appends and returns the most recent first, capped', () => {
    const store = new VolatileDiagnosticLogStore();
    store.record(log('a', 'first'));
    store.record(log('b', 'second'));
    store.record(log('c', 'third'));
    expect(store.count()).toBe(3);
    expect(store.recent(2).map((l) => l.id)).toEqual(['c', 'b']);
  });
});

describe('buildDiagnosticReport', () => {
  const base = {
    appEnv: 'dev',
    hubUrl: 'http://192.168.1.149:8000',
    storageDurability: 'durable-encrypted' as const,
    lastHubContactAtMs: T0 - 5 * 60 * 60 * 1000,
    offlinePolicyState: 'offline-within-limit',
    counts: { 'waiting-to-sync': 2, 'needs-review': 1 },
    recentLogs: [] as DiagnosticLog[],
    generatedAtMs: T0,
  };

  it('renders a copy-pasteable report with env, contact, policy and queue counts', () => {
    const report = buildDiagnosticReport(base);
    expect(report).toContain('hub env: dev');
    expect(report).toContain('hub url: http://192.168.1.149:8000');
    expect(report).toContain('local storage: durable-encrypted');
    expect(report).toContain('offline policy: offline-within-limit');
    expect(report).toContain('waiting-to-sync: 2');
    expect(report).toContain('needs-review: 1');
  });

  it('says "never" when there has been no Hub contact', () => {
    expect(buildDiagnosticReport({ ...base, lastHubContactAtMs: null })).toContain(
      'last hub contact: never',
    );
  });

  it('REDACTS any credential-like context key — the report can never leak a token', () => {
    const report = buildDiagnosticReport({
      ...base,
      recentLogs: [
        log('x', 'auth refresh', { authorization: 'Bearer super-secret', httpStatus: 401 }),
      ],
    });
    expect(report).not.toContain('super-secret');
    expect(report).toContain('[redacted]');
    expect(report).toContain('401'); // non-secret context survives
  });
});
