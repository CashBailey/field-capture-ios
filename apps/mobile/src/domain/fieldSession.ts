/**
 * Clock gate + assignment pull (first real OpsHub integration slice).
 *
 * The TimeClock clock-in, surfaced through Hub, gates field work: the app may always OPEN, but
 * field steps/actions are non-actionable until Hub confirms an open punch. This gating is
 * advisory UX only — Hub's submit guard remains the authority and re-checks clock-in on every
 * submission (docs/integration/ops-triad-contract.md).
 */
import {
  HubAuthError,
  HubNetworkError,
  HubResponseError,
  type AssignmentSource,
  type HubAssignment,
  type HubSessionStatus,
  type SessionStatusSource,
  type StoreDurability,
} from './hubGateway';
import { OFFLINE_OVER_LIMIT_REVIEW_REASON, type OfflinePolicy } from './offlinePolicy';

/**
 * Whether field work is actionable. Locked is the safe default: an unreachable Hub or a failed
 * auth NEVER unlocks field work (we refuse to assume a clock-in we cannot verify), but it also
 * never crashes the app shell — the reason is surfaced to the user instead.
 */
export type FieldWorkGate =
  | {
      state: 'locked';
      reason:
        | 'not-clocked-in'
        | 'hub-unreachable'
        | 'auth-failed'
        | 'bad-hub-response'
        | 'offline-over-limit';
      detail?: string;
    }
  | {
      state: 'unlocked';
      clockedInSince: string | null;
      source: string | null;
      /** Hub's logged-in employee id, when session-status reports it. Used only as evidence actor. */
      employeeId?: string | null;
    };

/**
 * Apply the 24h offline grace window without relaxing the Hub clock-in rule.
 *
 * A Hub-unreachable refresh can keep field work actionable only when this app session already had
 * a Hub-proven unlocked gate and the durable last-Hub-contact timestamp is still within the
 * offline window. A cold offline startup, signed-out state, or expired over-limit window stays
 * locked — we never invent a clock-in from a timestamp alone.
 */
export function applyOfflinePolicyToGate(input: {
  previousGate: FieldWorkGate;
  nextGate: FieldWorkGate;
  offlinePolicy?: OfflinePolicy;
}): FieldWorkGate {
  const { previousGate, nextGate, offlinePolicy } = input;
  if (nextGate.state === 'unlocked') return nextGate;
  if (nextGate.reason !== 'hub-unreachable') return nextGate;
  if (previousGate.state !== 'unlocked') return nextGate;
  if (offlinePolicy?.state === 'offline-within-limit') return previousGate;
  if (offlinePolicy?.state === 'offline-over-limit') {
    return {
      state: 'locked',
      reason: 'offline-over-limit',
      detail: OFFLINE_OVER_LIMIT_REVIEW_REASON,
    };
  }
  return nextGate;
}

/** Driver-facing lock reason for UI/runtime messages; stable codes stay internal. */
export function fieldWorkGateLockReason(gate: Extract<FieldWorkGate, { state: 'locked' }>): string {
  if (gate.reason === 'offline-over-limit') {
    return 'offline over limit — reconnect to Ops Hub before starting new work';
  }
  return gate.reason;
}

/**
 * Ask Hub for the driver's clock state and map it to a gate. Every Hub-side failure (offline,
 * auth, 5xx, malformed body, missing field) resolves to a LOCKED gate — anything other than an
 * explicit `clocked_in: true` locks field work. Only non-Hub errors (client bugs) propagate.
 */
export async function evaluateClockGate(source: SessionStatusSource): Promise<FieldWorkGate> {
  let status: HubSessionStatus;
  try {
    status = await source.getSessionStatus();
  } catch (error) {
    if (error instanceof HubNetworkError) {
      return { state: 'locked', reason: 'hub-unreachable', detail: error.message };
    }
    if (error instanceof HubAuthError) {
      return { state: 'locked', reason: 'auth-failed', detail: error.message };
    }
    if (error instanceof HubResponseError) {
      // Hub answered garbage (5xx, non-JSON, missing clocked_in). Never guess a clock state
      // from it — lock, and surface what Hub actually said.
      return { state: 'locked', reason: 'bad-hub-response', detail: error.message };
    }
    throw error; // client-side programming errors must fail loud, not masquerade as a lock
  }
  if (!status.clockedIn) {
    return { state: 'locked', reason: 'not-clocked-in' };
  }
  return {
    state: 'unlocked',
    clockedInSince: status.clockedInSince,
    source: status.source,
    employeeId: status.employeeId,
  };
}

// ---- assignment cache ----

/**
 * Where pulled assignments (frozen SR snapshots + hashes) are kept between pulls. Implementations
 * MUST declare their real durability; this slice ships only the volatile in-memory stub below.
 */
export interface AssignmentStore {
  readonly durability: StoreDurability;
  /** Replace the cached set with Hub's latest answer (Hub is the authority on assignment). */
  putAssignments(assignments: readonly HubAssignment[]): void;
  listAssignments(): HubAssignment[];
  getSnapshotHash(serviceRequestId: string): string | undefined;
}

/**
 * In-memory assignment cache. VOLATILE: lost on app restart. TEST SEAM ONLY — production uses
 * `data/SqliteAssignmentStore` (durable, SQLCipher in real builds). Do not present its contents
 * as "saved on the device".
 */
export class VolatileAssignmentStore implements AssignmentStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private assignments: HubAssignment[] = [];

  putAssignments(assignments: readonly HubAssignment[]): void {
    this.assignments = [...assignments];
  }

  listAssignments(): HubAssignment[] {
    return [...this.assignments];
  }

  getSnapshotHash(serviceRequestId: string): string | undefined {
    return this.assignments.find((a) => a.serviceRequestId === serviceRequestId)?.snapshotHash;
  }
}

// ---- session refresh (gate, then pull) ----

export type AssignmentRefresh =
  | { status: 'synced'; count: number }
  | { status: 'not-pulled'; reason: 'locked' }
  /** The gate is open but the pull failed; any previously-cached assignments are kept. */
  | { status: 'unavailable'; reason: string };

export interface FieldSessionResult {
  gate: FieldWorkGate;
  assignments: AssignmentRefresh;
}

/**
 * One refresh cycle: evaluate the clock gate; only if unlocked, pull assignments and retain the
 * snapshots + hashes. A failed pull never wipes the existing cache and never unlocks anything.
 */
export async function refreshFieldSession(deps: {
  statusSource: SessionStatusSource;
  assignmentSource: AssignmentSource;
  store: AssignmentStore;
}): Promise<FieldSessionResult> {
  const gate = await evaluateClockGate(deps.statusSource);
  if (gate.state === 'locked') {
    return { gate, assignments: { status: 'not-pulled', reason: 'locked' } };
  }
  try {
    const assignments = await deps.assignmentSource.getAssignments();
    deps.store.putAssignments(assignments);
    return { gate, assignments: { status: 'synced', count: assignments.length } };
  } catch (error) {
    if (
      error instanceof HubNetworkError ||
      error instanceof HubAuthError ||
      error instanceof HubResponseError
    ) {
      return { gate, assignments: { status: 'unavailable', reason: error.message } };
    }
    throw error;
  }
}
