/**
 * Pure 24-hour offline-policy state machine (Phase 8). The honest-persistence + wiring lands later;
 * here we pin the math + the graduated semantics so a restart can never be used to dodge the clock.
 */
import {
  evaluateOfflinePolicy,
  offlineAllowsNewWork,
  OFFLINE_OVER_LIMIT_REVIEW_REASON,
} from '../src/domain';

const HOUR = 60 * 60 * 1000;
const T0 = 1_000_000_000_000; // arbitrary fixed epoch ms (Date.now is not used — kept pure)

describe('evaluateOfflinePolicy', () => {
  it('online: window is irrelevant, full window reported as remaining', () => {
    const p = evaluateOfflinePolicy({
      lastHubContactAtMs: T0 - 50 * HOUR,
      nowMs: T0,
      online: true,
    });
    expect(p.state).toBe('online');
    expect(p.elapsedMs).toBe(0);
    expect(p.remainingMs).toBe(24 * HOUR);
  });

  it('offline within the 24h window: capture stays allowed, remaining counts down', () => {
    const p = evaluateOfflinePolicy({ lastHubContactAtMs: T0 - 5 * HOUR, nowMs: T0 });
    expect(p.state).toBe('offline-within-limit');
    expect(p.elapsedMs).toBe(5 * HOUR);
    expect(p.remainingMs).toBe(19 * HOUR);
  });

  it('offline past 24h: over-limit, no remaining', () => {
    const p = evaluateOfflinePolicy({ lastHubContactAtMs: T0 - 25 * HOUR, nowMs: T0 });
    expect(p.state).toBe('offline-over-limit');
    expect(p.elapsedMs).toBe(25 * HOUR);
    expect(p.remainingMs).toBe(0);
  });

  it('exactly at the boundary is over-limit (>= window)', () => {
    const p = evaluateOfflinePolicy({ lastHubContactAtMs: T0 - 24 * HOUR, nowMs: T0 });
    expect(p.state).toBe('offline-over-limit');
    expect(p.remainingMs).toBe(0);
  });

  it('never-contacted while offline is conservatively over-limit (no baseline to trust)', () => {
    const p = evaluateOfflinePolicy({ lastHubContactAtMs: null, nowMs: T0 });
    expect(p.state).toBe('offline-over-limit');
    expect(p.elapsedMs).toBe(0);
    expect(p.remainingMs).toBe(0);
  });

  it('a future last-contact (clock skew) clamps elapsed to 0, not negative', () => {
    const p = evaluateOfflinePolicy({ lastHubContactAtMs: T0 + 2 * HOUR, nowMs: T0 });
    expect(p.elapsedMs).toBe(0);
    expect(p.state).toBe('offline-within-limit');
    expect(p.remainingMs).toBe(24 * HOUR);
  });

  it('honors a Hub-seeded window other than 24h', () => {
    const p = evaluateOfflinePolicy({
      lastHubContactAtMs: T0 - 5 * HOUR,
      nowMs: T0,
      windowHours: 4,
    });
    expect(p.windowMs).toBe(4 * HOUR);
    expect(p.state).toBe('offline-over-limit');
  });

  it('a restart cannot reset the clock — same durable timestamp yields the same verdict', () => {
    const input = { lastHubContactAtMs: T0 - 30 * HOUR, nowMs: T0 } as const;
    expect(evaluateOfflinePolicy(input)).toEqual(evaluateOfflinePolicy({ ...input }));
    expect(evaluateOfflinePolicy(input).state).toBe('offline-over-limit');
  });
});

describe('offlineAllowsNewWork', () => {
  it('blocks new work only when over-limit (offline-first within the window)', () => {
    expect(offlineAllowsNewWork('online')).toBe(true);
    expect(offlineAllowsNewWork('offline-within-limit')).toBe(true);
    expect(offlineAllowsNewWork('offline-over-limit')).toBe(false);
  });

  it('exposes a distinct over-limit review reason for captured evidence', () => {
    expect(OFFLINE_OVER_LIMIT_REVIEW_REASON).toBe('offline-over-limit-evidence');
  });
});
