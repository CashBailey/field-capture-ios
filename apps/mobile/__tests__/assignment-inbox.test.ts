/**
 * Pure assignment-inbox logic (spec 7.5): per-SR sync rollup + the 7 filters. The screen renders
 * what these return, so the rules live here under test.
 */
import {
  filterAssignments,
  perSrSyncState,
  rankTodayAssignments,
  rollUpSrSyncState,
  todayPriority,
  INBOX_FILTERS,
  type HubAssignment,
  type InboxFilter,
  type SrSyncItem,
  type SrSyncState,
} from '../src/domain';

function sr(id: string): HubAssignment {
  return { serviceRequestId: id, snapshotHash: `h-${id}`, snapshot: null };
}
function srWith(
  id: string,
  status: NonNullable<HubAssignment['details']>['status'],
): HubAssignment {
  return { serviceRequestId: id, snapshotHash: `h-${id}`, snapshot: null, details: { status } };
}
function item(serviceRequestId: string, state: SrSyncItem['state']): SrSyncItem {
  return { serviceRequestId, state };
}

describe('rollUpSrSyncState (worst-first)', () => {
  it('no items → no-local-work', () => {
    expect(rollUpSrSyncState([])).toBe('no-local-work');
  });
  it('needs-review wins over everything else', () => {
    expect(
      rollUpSrSyncState([item('a', 'accepted'), item('a', 'pending'), item('a', 'needs-review')]),
    ).toBe('needs-review');
    expect(rollUpSrSyncState([item('a', 'rejected'), item('a', 'accepted')])).toBe('needs-review');
  });
  it('needs-sync when something is still owed but nothing rejected', () => {
    expect(rollUpSrSyncState([item('a', 'accepted'), item('a', 'in-flight')])).toBe('needs-sync');
    expect(rollUpSrSyncState([item('a', 'pending')])).toBe('needs-sync');
  });
  it('synced only when every item is accepted', () => {
    expect(rollUpSrSyncState([item('a', 'accepted'), item('a', 'accepted')])).toBe('synced');
  });
});

describe('perSrSyncState', () => {
  it('groups by SR and rolls each up independently', () => {
    const map = perSrSyncState([
      item('sr-1', 'accepted'),
      item('sr-1', 'needs-review'),
      item('sr-2', 'pending'),
      item('sr-3', 'accepted'),
    ]);
    expect(map.get('sr-1')).toBe('needs-review');
    expect(map.get('sr-2')).toBe('needs-sync');
    expect(map.get('sr-3')).toBe('synced');
    expect(map.has('sr-4')).toBe(false);
  });
});

describe('filterAssignments (the 7 inbox filters)', () => {
  const assignments: HubAssignment[] = [
    srWith('sr-assigned', 'assigned'),
    srWith('sr-progress', 'in_progress'),
    srWith('sr-hold', 'on_hold'),
    sr('sr-legacy'), // no status → defaults to active/visible
  ];
  const state = new Map<string, SrSyncState>([
    ['sr-assigned', 'needs-sync'],
    ['sr-progress', 'needs-review'],
    ['sr-hold', 'synced'],
  ]);
  const ids = (filter: InboxFilter) =>
    filterAssignments(assignments, state, filter).map((a) => a.serviceRequestId);

  it('exposes exactly the 7 spec-7.5 filters', () => {
    expect(INBOX_FILTERS).toEqual([
      'today',
      'active',
      'on-hold',
      'completed-locally',
      'needs-sync',
      'needs-review',
      'all-cached',
    ]);
  });

  it('all-cached returns everything held on device', () => {
    expect(ids('all-cached')).toEqual(['sr-assigned', 'sr-progress', 'sr-hold', 'sr-legacy']);
  });

  it('active/today: assigned + in_progress + status-less legacy, never on-hold', () => {
    expect(ids('active')).toEqual(['sr-assigned', 'sr-progress', 'sr-legacy']);
    expect(ids('today')).toEqual(ids('active'));
  });

  it('on-hold: only dispatcher-paused SRs', () => {
    expect(ids('on-hold')).toEqual(['sr-hold']);
  });

  it('needs-sync / needs-review / completed-locally derive from the per-SR rollup', () => {
    expect(ids('needs-sync')).toEqual(['sr-assigned']);
    expect(ids('needs-review')).toEqual(['sr-progress']);
    expect(ids('completed-locally')).toEqual(['sr-hold']); // synced = accepted, nothing owed
  });

  it('an SR with no local work appears only in all-cached / active, not the sync filters', () => {
    expect(ids('needs-sync')).not.toContain('sr-legacy');
    expect(ids('completed-locally')).not.toContain('sr-legacy');
    expect(ids('all-cached')).toContain('sr-legacy');
  });
});

describe('Today priority ladder (spec 7.4)', () => {
  it('ranks most-actionable first: needs-review > needs-sync > in_progress > assigned > on_hold', () => {
    expect(todayPriority(srWith('a', 'on_hold'), 'needs-review')).toBeLessThan(
      todayPriority(srWith('b', 'in_progress'), 'needs-sync'),
    );
    expect(todayPriority(srWith('c', 'in_progress'), 'no-local-work')).toBeLessThan(
      todayPriority(srWith('d', 'assigned'), 'no-local-work'),
    );
    expect(todayPriority(srWith('e', 'assigned'), 'no-local-work')).toBeLessThan(
      todayPriority(srWith('f', 'on_hold'), 'no-local-work'),
    );
  });

  it('orders a mixed set and breaks ties stably by serviceRequestId', () => {
    const list = [
      srWith('sr-hold', 'on_hold'),
      srWith('sr-assigned', 'assigned'),
      srWith('sr-progress', 'in_progress'),
      srWith('sr-review', 'in_progress'),
      srWith('sr-sync', 'assigned'),
    ];
    const state = new Map<string, SrSyncState>([
      ['sr-review', 'needs-review'],
      ['sr-sync', 'needs-sync'],
    ]);
    expect(rankTodayAssignments(list, state).map((a) => a.serviceRequestId)).toEqual([
      'sr-review', // needs-review
      'sr-sync', // needs-sync
      'sr-progress', // in_progress
      'sr-assigned', // assigned
      'sr-hold', // on_hold last
    ]);
  });
});
