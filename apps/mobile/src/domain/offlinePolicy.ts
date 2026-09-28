/**
 * 24-hour offline policy (spec 7.14 / plan Phase 8) — a PURE state machine, no storage or clock.
 *
 * The clock-in gate ([[fieldSession]] `evaluateClockGate`) decides whether field work is unlocked
 * from Hub truth. This policy is the ORTHOGONAL "how long have we been flying blind?" axis: once a
 * worker is clocked in, an unreachable Hub WITHIN the window keeps capture/continue-work allowed
 * (offline-first), but OVER the window blocks NEW work and labels fresh captures as
 * "offline over-limit evidence / requires office review". It never relaxes the clock-in gate, and
 * it must be fed a DURABLE last-successful-Hub-contact timestamp so a restart can't reset the clock.
 */
import type { StoreDurability } from './hubGateway';

export type OfflinePolicyState = 'online' | 'offline-within-limit' | 'offline-over-limit';

export interface OfflinePolicyInput {
  /**
   * When the device last had a SUCCESSFUL Hub exchange (session-status or sync push/pull), in epoch
   * ms. `null` means no successful contact is on record (fresh install / never reached the Hub).
   */
  lastHubContactAtMs: number | null;
  /** Current time, epoch ms (caller supplies — keeps this pure and testable). */
  nowMs: number;
  /** Is the Hub reachable right now? When `true`, the window is irrelevant (state is `online`). */
  online?: boolean;
  /** Window before offline work is over-limit. Default 24h; Hub may seed a different value. */
  windowHours?: number;
}

export interface OfflinePolicy {
  state: OfflinePolicyState;
  /** ms since the last successful Hub contact (0 when online or never-contacted). */
  elapsedMs: number;
  /** ms remaining before crossing the over-limit threshold (0 when over-limit or never-contacted). */
  remainingMs: number;
  /** The resolved window length in ms (for display: "X of 24h remaining"). */
  windowMs: number;
}

const DEFAULT_WINDOW_HOURS = 24;

/**
 * Evaluate the offline policy. Conservative by construction: an unknown baseline
 * (`lastHubContactAtMs === null`) while offline is treated as OVER-limit — we never grant the
 * offline grace window without a proven recent Hub contact to start the clock from.
 */
export function evaluateOfflinePolicy(input: OfflinePolicyInput): OfflinePolicy {
  const windowMs = Math.max(0, (input.windowHours ?? DEFAULT_WINDOW_HOURS) * 60 * 60 * 1000);

  if (input.online === true) {
    return { state: 'online', elapsedMs: 0, remainingMs: windowMs, windowMs };
  }
  if (input.lastHubContactAtMs === null) {
    return { state: 'offline-over-limit', elapsedMs: 0, remainingMs: 0, windowMs };
  }

  const elapsedMs = Math.max(0, input.nowMs - input.lastHubContactAtMs);
  const remainingMs = Math.max(0, windowMs - elapsedMs);
  return {
    state: elapsedMs >= windowMs ? 'offline-over-limit' : 'offline-within-limit',
    elapsedMs,
    remainingMs,
    windowMs,
  };
}

/**
 * May NEW field work begin under this policy? (The clock-in gate is enforced separately and still
 * applies.) Over-limit blocks new work; online and within-limit allow it — offline-first.
 */
export function offlineAllowsNewWork(state: OfflinePolicyState): boolean {
  return state !== 'offline-over-limit';
}

/**
 * The needs-review sub-reason captures earned while over the offline limit are tagged with, so the
 * office can adjudicate evidence taken with no recent Hub truth. Distinct from snapshot-drift etc.
 */
export const OFFLINE_OVER_LIMIT_REVIEW_REASON = 'offline-over-limit-evidence';

// ---- durable persistence (the restart-proof part) ----

/** What survives a restart for the offline policy. */
export interface OfflinePolicyPersistedState {
  /** Durable last-successful-Hub-contact timestamp (epoch ms), or null if none on record. */
  lastHubContactAtMs: number | null;
  /** Hub-seeded window in hours, or undefined to use the 24h default. */
  windowHours?: number;
}

/**
 * Durable home for the offline-policy baseline. The contract that makes the 24h window honest:
 * `recordHubContact` is MONOTONIC-FORWARD — it never moves the timestamp backward, so neither a
 * restart nor a clock-skewed earlier value can extend the offline grace window.
 */
export interface OfflinePolicyStore {
  readonly durability: StoreDurability;
  getState(): OfflinePolicyPersistedState;
  /** Record a successful Hub contact; ignored if `atMs` is older than what's already stored. */
  recordHubContact(atMs: number): void;
  /** Persist a Hub-seeded offline window (hours). */
  setWindowHours(hours: number): void;
}

/** In-memory test seam — explicitly volatile; never present its contents as "saved on the device". */
export class VolatileOfflinePolicyStore implements OfflinePolicyStore {
  readonly durability = 'volatile-memory' as const;
  private lastHubContactAtMs: number | null = null;
  private windowHours: number | undefined;

  getState(): OfflinePolicyPersistedState {
    return {
      lastHubContactAtMs: this.lastHubContactAtMs,
      ...(this.windowHours !== undefined ? { windowHours: this.windowHours } : {}),
    };
  }

  recordHubContact(atMs: number): void {
    if (this.lastHubContactAtMs === null || atMs > this.lastHubContactAtMs) {
      this.lastHubContactAtMs = atMs;
    }
  }

  setWindowHours(hours: number): void {
    this.windowHours = hours;
  }
}
