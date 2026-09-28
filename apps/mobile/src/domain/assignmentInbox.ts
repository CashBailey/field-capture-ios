/**
 * Assignment inbox logic (spec 7.5) — PURE, no UI/storage. Two concerns the AssignmentInboxScreen
 * composes: (1) a per-SR "last sync state" rolled up from the durable outbox/form/blob work items,
 * and (2) the seven inbox filters. Kept pure so every rule is unit-tested headlessly; the screen
 * only renders the results. Surfacing needs-review (incl. Hub snapshot-drift rejections) on this
 * read path is display-only — it never triggers an auto-refetch or wipes local work.
 */
import type { sync } from '@fieldcapture/contracts';

import type { AssignmentStatus, HubAssignment } from './hubGateway';

// ---- per-SR sync-state rollup ----

/**
 * One unit of sync-tracked work tied to a Service Request (a ticket submit, a safety-form event, a
 * blob link…). The caller collects these from the outbox / form / blob stores — each already knows
 * its `serviceRequestId` (e.g. `TicketEvidence.envelope.payload.serviceRequestId`).
 */
export interface SrSyncItem {
  serviceRequestId: string;
  state: sync.OutboxItemState;
}

/** The per-SR rollup shown as "Last sync state" and filtered on. */
export type SrSyncState = 'no-local-work' | 'synced' | 'needs-sync' | 'needs-review';

export const SR_SYNC_STATE_LABELS: Record<SrSyncState, string> = {
  'no-local-work': 'Not started',
  synced: 'Synced',
  'needs-sync': 'Needs sync',
  'needs-review': 'Needs review',
};

/**
 * Roll a set of work items for ONE SR into a single state, WORST-first so the most urgent state
 * wins: needs-review (Hub rejected / needs office review) > needs-sync (still owed to Hub) >
 * synced (everything Hub-accepted). No items → the SR has no local work yet.
 */
export function rollUpSrSyncState(items: readonly SrSyncItem[]): SrSyncState {
  if (items.length === 0) return 'no-local-work';
  if (items.some((i) => i.state === 'needs-review' || i.state === 'rejected'))
    return 'needs-review';
  if (items.some((i) => i.state === 'pending' || i.state === 'in-flight')) return 'needs-sync';
  return 'synced';
}

/** Group work items by SR and roll each up. SRs with no items are simply absent from the map. */
export function perSrSyncState(items: readonly SrSyncItem[]): Map<string, SrSyncState> {
  const grouped = new Map<string, SrSyncItem[]>();
  for (const item of items) {
    const list = grouped.get(item.serviceRequestId);
    if (list) list.push(item);
    else grouped.set(item.serviceRequestId, [item]);
  }
  const out = new Map<string, SrSyncState>();
  for (const [srId, list] of grouped) out.set(srId, rollUpSrSyncState(list));
  return out;
}

// ---- the 7 inbox filters (spec 7.5) ----

export type InboxFilter =
  | 'today'
  | 'active'
  | 'on-hold'
  | 'completed-locally'
  | 'needs-sync'
  | 'needs-review'
  | 'all-cached';

export const INBOX_FILTERS: readonly InboxFilter[] = [
  'today',
  'active',
  'on-hold',
  'completed-locally',
  'needs-sync',
  'needs-review',
  'all-cached',
];

export const INBOX_FILTER_LABELS: Record<InboxFilter, string> = {
  today: 'Today',
  active: 'Active',
  'on-hold': 'On hold',
  'completed-locally': 'Completed locally',
  'needs-sync': 'Needs sync',
  'needs-review': 'Needs review',
  'all-cached': 'All cached',
};

/** Statuses that count as workable-now (drive Today/Active). */
const ACTIVE_STATUSES: readonly AssignmentStatus[] = ['assigned', 'in_progress'];

/**
 * Today-dashboard priority (spec 7.4 priority ladder) — LOWER ranks first. Most-actionable first:
 * office-review needs, then work owed to Hub, then in-progress, then not-yet-started, then on-hold.
 */
export function todayPriority(assignment: HubAssignment, syncState: SrSyncState): number {
  if (syncState === 'needs-review') return 0;
  if (syncState === 'needs-sync') return 1;
  const status = assignment.details?.status;
  if (status === 'in_progress') return 2;
  if (status === 'assigned' || status === undefined) return 3;
  if (status === 'on_hold') return 4;
  return 5;
}

/** Order the cached assignments by Today priority (stable: ties break on serviceRequestId). */
export function rankTodayAssignments(
  assignments: readonly HubAssignment[],
  srStateById: ReadonlyMap<string, SrSyncState>,
): HubAssignment[] {
  return [...assignments].sort((a, b) => {
    const rank =
      todayPriority(a, srStateById.get(a.serviceRequestId) ?? 'no-local-work') -
      todayPriority(b, srStateById.get(b.serviceRequestId) ?? 'no-local-work');
    return rank !== 0 ? rank : a.serviceRequestId.localeCompare(b.serviceRequestId);
  });
}

function syncStateOf(map: ReadonlyMap<string, SrSyncState>, a: HubAssignment): SrSyncState {
  return map.get(a.serviceRequestId) ?? 'no-local-work';
}

/**
 * Filter the cached assignments for one inbox tab. The Hub only returns active assigned SRs, so:
 *  - Today / Active: workable now (status assigned|in_progress). Today == Active until the Hub
 *    surfaces a per-SR scheduled date; status-less legacy payloads stay visible (default active).
 *  - On hold: dispatcher-paused (status on_hold).
 *  - Completed locally: an accepted local submission exists with nothing still owed (sync 'synced').
 *  - Needs sync / Needs review: the per-SR rollup.
 *  - All cached: everything held on the device (offline view).
 */
export function filterAssignments(
  assignments: readonly HubAssignment[],
  srStateById: ReadonlyMap<string, SrSyncState>,
  filter: InboxFilter,
): HubAssignment[] {
  switch (filter) {
    case 'all-cached':
      return [...assignments];
    case 'today':
    case 'active':
      return assignments.filter((a) => {
        const status = a.details?.status;
        return status === undefined || ACTIVE_STATUSES.includes(status);
      });
    case 'on-hold':
      return assignments.filter((a) => a.details?.status === 'on_hold');
    case 'completed-locally':
      return assignments.filter((a) => syncStateOf(srStateById, a) === 'synced');
    case 'needs-sync':
      return assignments.filter((a) => syncStateOf(srStateById, a) === 'needs-sync');
    case 'needs-review':
      return assignments.filter((a) => syncStateOf(srStateById, a) === 'needs-review');
  }
}
