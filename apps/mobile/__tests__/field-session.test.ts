import {
  HubAuthError,
  HubNetworkError,
  HubResponseError,
  VolatileAssignmentStore,
  applyOfflinePolicyToGate,
  evaluateClockGate,
  fieldWorkGateLockReason,
  parseWorkflowRequirementsFromAssignments,
  refreshFieldSession,
  type HubAssignment,
  type HubSessionStatus,
  type OfflinePolicy,
} from '../src/domain';

const CLOCKED_IN: HubSessionStatus = {
  clockedIn: true,
  clockedInSince: '2026-06-09T12:00:00Z',
  source: 'timeclock',
  employeeId: 'emp-1',
  assignmentsAvailable: true,
};

const CLOCKED_OUT: HubSessionStatus = {
  clockedIn: false,
  clockedInSince: null,
  source: null,
  employeeId: 'emp-1',
  assignmentsAvailable: false,
};

const ASSIGNMENTS: HubAssignment[] = [
  { serviceRequestId: 'sr-1', snapshotHash: 'h1', snapshot: { srId: 'sr-1' } },
  { serviceRequestId: 'sr-2', snapshotHash: 'h2', snapshot: { srId: 'sr-2' } },
];

const WITHIN_LIMIT_POLICY: OfflinePolicy = {
  state: 'offline-within-limit',
  elapsedMs: 2 * 60 * 60 * 1000,
  remainingMs: 22 * 60 * 60 * 1000,
  windowMs: 24 * 60 * 60 * 1000,
};

const OVER_LIMIT_POLICY: OfflinePolicy = {
  state: 'offline-over-limit',
  elapsedMs: 25 * 60 * 60 * 1000,
  remainingMs: 0,
  windowMs: 24 * 60 * 60 * 1000,
};

const statusSource = (status: HubSessionStatus) => ({ getSessionStatus: async () => status });
const failingStatusSource = (err: Error) => ({
  getSessionStatus: async (): Promise<HubSessionStatus> => {
    throw err;
  },
});

describe('clock gate (Hub/TimeClock is the authority on clock-in)', () => {
  it('unlocks field work when Hub says the driver is clocked in', async () => {
    const gate = await evaluateClockGate(statusSource(CLOCKED_IN));
    expect(gate).toEqual({
      state: 'unlocked',
      clockedInSince: '2026-06-09T12:00:00Z',
      source: 'timeclock',
      employeeId: 'emp-1',
    });
  });

  it('locks field work when the driver is not clocked in (app may open; actions non-actionable)', async () => {
    const gate = await evaluateClockGate(statusSource(CLOCKED_OUT));
    expect(gate).toEqual({ state: 'locked', reason: 'not-clocked-in' });
  });

  it('locks (visibly) when Hub is unreachable — never assumes clocked in while offline', async () => {
    const gate = await evaluateClockGate(failingStatusSource(new HubNetworkError('offline')));
    expect(gate).toMatchObject({ state: 'locked', reason: 'hub-unreachable' });
  });

  it('locks (visibly) when auth fails', async () => {
    const gate = await evaluateClockGate(failingStatusSource(new HubAuthError('bad token', 401)));
    expect(gate).toMatchObject({ state: 'locked', reason: 'auth-failed' });
  });

  it('locks (visibly) when Hub answers garbage — a malformed body is never treated as clocked in', async () => {
    const gate = await evaluateClockGate(
      failingStatusSource(
        new HubResponseError('session-status body is missing a boolean clocked_in'),
      ),
    );
    expect(gate).toMatchObject({ state: 'locked', reason: 'bad-hub-response' });
  });

  it('locks (visibly) when Hub returns a 5xx on session-status', async () => {
    const gate = await evaluateClockGate(
      failingStatusSource(
        new HubResponseError('Hub returned 503 for GET /api/v1/sync/session-status', 503),
      ),
    );
    expect(gate).toMatchObject({ state: 'locked', reason: 'bad-hub-response' });
  });

  it('does not swallow client-side programming errors as a lock reason', async () => {
    await expect(evaluateClockGate(failingStatusSource(new Error('boom')))).rejects.toThrow('boom');
  });
});

describe('applyOfflinePolicyToGate', () => {
  it('keeps work actionable during a short Hub outage only after a Hub-proven unlock', () => {
    const hubUnlocked = {
      state: 'unlocked',
      clockedInSince: '2026-06-09T12:00:00Z',
      source: 'timeclock',
      employeeId: 'emp-1',
    } as const;

    expect(
      applyOfflinePolicyToGate({
        previousGate: hubUnlocked,
        nextGate: { state: 'locked', reason: 'hub-unreachable', detail: 'offline' },
        offlinePolicy: WITHIN_LIMIT_POLICY,
      }),
    ).toBe(hubUnlocked);
  });

  it('does not invent a clock-in on cold offline startup even inside the grace window', () => {
    const nextGate = { state: 'locked', reason: 'hub-unreachable', detail: 'offline' } as const;

    expect(
      applyOfflinePolicyToGate({
        previousGate: { state: 'locked', reason: 'hub-unreachable' },
        nextGate,
        offlinePolicy: WITHIN_LIMIT_POLICY,
      }),
    ).toBe(nextGate);
  });

  it('blocks new work once the offline window is over limit', () => {
    expect(
      applyOfflinePolicyToGate({
        previousGate: {
          state: 'unlocked',
          clockedInSince: '2026-06-09T12:00:00Z',
          source: 'timeclock',
          employeeId: 'emp-1',
        },
        nextGate: { state: 'locked', reason: 'hub-unreachable', detail: 'offline' },
        offlinePolicy: OVER_LIMIT_POLICY,
      }),
    ).toEqual({
      state: 'locked',
      reason: 'offline-over-limit',
      detail: 'offline-over-limit-evidence',
    });
  });

  it('does not soften auth failures or bad Hub responses', () => {
    const nextGate = { state: 'locked', reason: 'auth-failed' } as const;

    expect(
      applyOfflinePolicyToGate({
        previousGate: {
          state: 'unlocked',
          clockedInSince: '2026-06-09T12:00:00Z',
          source: 'timeclock',
        },
        nextGate,
        offlinePolicy: WITHIN_LIMIT_POLICY,
      }),
    ).toBe(nextGate);
  });

  it('formats the over-limit lock reason for drivers', () => {
    expect(
      fieldWorkGateLockReason({
        state: 'locked',
        reason: 'offline-over-limit',
        detail: 'offline-over-limit-evidence',
      }),
    ).toBe('offline over limit — reconnect to Ops Hub before starting new work');
  });
});

describe('refreshFieldSession (clock gate + assignment pull)', () => {
  it('pulls assignments and retains snapshot hashes when unlocked', async () => {
    const store = new VolatileAssignmentStore();
    const result = await refreshFieldSession({
      statusSource: statusSource(CLOCKED_IN),
      assignmentSource: { getAssignments: async () => ASSIGNMENTS },
      store,
    });
    expect(result.gate.state).toBe('unlocked');
    expect(result.assignments).toEqual({ status: 'synced', count: 2 });
    expect(store.listAssignments().map((a) => a.serviceRequestId)).toEqual(['sr-1', 'sr-2']);
    expect(store.getSnapshotHash('sr-1')).toBe('h1');
    expect(store.getSnapshotHash('sr-2')).toBe('h2');
  });

  it('does NOT pull assignments when locked — field steps stay non-actionable', async () => {
    const store = new VolatileAssignmentStore();
    let called = false;
    const result = await refreshFieldSession({
      statusSource: statusSource(CLOCKED_OUT),
      assignmentSource: {
        getAssignments: async () => {
          called = true;
          return ASSIGNMENTS;
        },
      },
      store,
    });
    expect(result.gate).toEqual({ state: 'locked', reason: 'not-clocked-in' });
    expect(result.assignments).toEqual({ status: 'not-pulled', reason: 'locked' });
    expect(called).toBe(false);
    expect(store.listAssignments()).toEqual([]);
  });

  it('reports assignments unavailable (and keeps the prior cache) if the pull fails after unlock', async () => {
    const store = new VolatileAssignmentStore();
    store.putAssignments([ASSIGNMENTS[0]]);
    const result = await refreshFieldSession({
      statusSource: statusSource(CLOCKED_IN),
      assignmentSource: {
        getAssignments: async () => {
          throw new HubNetworkError('offline');
        },
      },
      store,
    });
    expect(result.gate.state).toBe('unlocked');
    expect(result.assignments).toMatchObject({ status: 'unavailable' });
    // the previously-cached assignment is preserved, not wiped by a failed refresh
    expect(store.listAssignments().map((a) => a.serviceRequestId)).toEqual(['sr-1']);
  });

  it('keeps cached rich assignments when a malformed refresh is rejected', async () => {
    const store = new VolatileAssignmentStore();
    store.putAssignments([
      {
        serviceRequestId: 'sr-1',
        snapshotHash: 'h1',
        latestServerVersion: 'h1',
        snapshot: { srId: 'sr-1' },
        details: {
          customer: { id: 'cust-1', name: 'ACME Oil' },
          workflowRequirements: {
            clockInRequired: true,
            requiredSteps: ['pre_trip_dvir', 'jha'],
          },
        },
      },
    ]);

    const result = await refreshFieldSession({
      statusSource: statusSource(CLOCKED_IN),
      assignmentSource: {
        getAssignments: async () => {
          throw new HubResponseError('assignment[0].customer is malformed');
        },
      },
      store,
    });

    expect(result).toMatchObject({
      gate: { state: 'unlocked' },
      assignments: { status: 'unavailable' },
    });
    expect(store.listAssignments()).toHaveLength(1);
    expect(store.listAssignments()[0]).toMatchObject({
      serviceRequestId: 'sr-1',
      snapshotHash: 'h1',
      latestServerVersion: 'h1',
      details: { customer: { name: 'ACME Oil' } },
    });
  });
});

describe('VolatileAssignmentStore (explicit about durability limits)', () => {
  it('declares itself volatile — it must never be mistaken for the durable offline store', () => {
    expect(new VolatileAssignmentStore().durability).toBe('volatile-memory');
  });

  it('replaces the assignment set on each successful sync (Hub is the authority)', () => {
    const store = new VolatileAssignmentStore();
    store.putAssignments(ASSIGNMENTS);
    store.putAssignments([ASSIGNMENTS[1]]);
    expect(store.listAssignments().map((a) => a.serviceRequestId)).toEqual(['sr-2']);
    expect(store.getSnapshotHash('sr-1')).toBeUndefined();
  });

  it('surfaces workflow requirements from rich metadata and legacy snapshots', () => {
    const store = new VolatileAssignmentStore();
    store.putAssignments([
      {
        serviceRequestId: 'sr-rich',
        snapshotHash: 'h-rich',
        snapshot: {},
        details: {
          workflowRequirements: {
            clockInRequired: true,
            requiredSteps: ['pre_trip_dvir', 'jha'],
          },
        },
      },
      {
        serviceRequestId: 'sr-legacy',
        snapshotHash: 'h-legacy',
        snapshot: {
          workflow_requirements: {
            clock_in_required: true,
            required_steps: ['post_trip_dvir'],
          },
        },
      },
    ]);

    expect(parseWorkflowRequirementsFromAssignments(store.listAssignments(), 'sr-rich')).toEqual({
      clockInRequired: true,
      requiredSteps: ['pre_trip_dvir', 'jha'],
    });
    expect(parseWorkflowRequirementsFromAssignments(store.listAssignments(), 'sr-legacy')).toEqual({
      clockInRequired: true,
      requiredSteps: ['post_trip_dvir'],
    });
  });
});
