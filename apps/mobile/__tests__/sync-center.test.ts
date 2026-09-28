/**
 * Pure Sync Center rollup (spec 7.15): raw outbox/draft/blob state → worker-facing buckets.
 */
import {
  summarizeSyncCenter,
  SYNC_CENTER_LABELS,
  SYNC_CENTER_ORDER,
  type SyncCenterEvidence,
} from '../src/domain';

const ev = (state: SyncCenterEvidence['state'], lastRejectionCode?: string): SyncCenterEvidence =>
  lastRejectionCode === undefined ? { state } : { state, lastRejectionCode };

describe('summarizeSyncCenter', () => {
  it('an empty world has no outstanding work', () => {
    const s = summarizeSyncCenter({ draftCount: 0, evidence: [] });
    expect(s.total).toBe(0);
    expect(s.hasOutstanding).toBe(false);
    expect(s.counts['waiting-to-sync']).toBe(0);
  });

  it('buckets each outbox state into the right worker-facing category', () => {
    const s = summarizeSyncCenter({
      draftCount: 2,
      evidence: [
        ev('pending'), // waiting-to-sync
        ev('in-flight'), // waiting-to-sync
        ev('pending', 'not_clocked_in'), // waiting-on-you (a 403/409 block)
        ev('accepted'),
        ev('needs-review'),
        ev('rejected'),
      ],
      blobs: [{ linkConfirmed: false }, { linkConfirmed: true }],
    });
    expect(s.counts).toEqual({
      'saved-on-phone': 2,
      'waiting-to-sync': 3, // 2 evidence + 1 unlinked blob
      'waiting-on-you': 1,
      'accepted-by-hub': 2, // 1 evidence + 1 linked blob
      'needs-review': 1,
      'rejected-by-hub': 1,
    });
    expect(s.total).toBe(10);
    expect(s.hasOutstanding).toBe(true);
  });

  it('only Hub-accepted work counts as accepted — a blocked pending is never "synced"', () => {
    const s = summarizeSyncCenter({ draftCount: 0, evidence: [ev('pending', 'in_progress')] });
    expect(s.counts['accepted-by-hub']).toBe(0);
    expect(s.counts['waiting-on-you']).toBe(1);
    expect(s.counts['waiting-to-sync']).toBe(0);
  });

  it('accepted-only work is durable on Hub with nothing outstanding', () => {
    const s = summarizeSyncCenter({ draftCount: 0, evidence: [ev('accepted'), ev('accepted')] });
    expect(s.hasOutstanding).toBe(false);
    expect(s.counts['accepted-by-hub']).toBe(2);
  });

  it('exposes a plain-language label and a stable display order for every category', () => {
    expect(SYNC_CENTER_ORDER).toHaveLength(6);
    for (const category of SYNC_CENTER_ORDER) {
      expect(SYNC_CENTER_LABELS[category]).toBeTruthy();
    }
    expect(SYNC_CENTER_LABELS['needs-review']).toBe('Needs office review');
  });
});
