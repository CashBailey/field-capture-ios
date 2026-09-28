/**
 * Sync Center rollup (spec 7.15) — PURE, no UI/storage. Turns the durable outbox/draft/blob state
 * into the plain-language buckets a worker actually understands ("Saved on this phone", "Waiting to
 * sync", "Needs office review", …) instead of raw 409/snapshot-drift codes. The screen renders
 * these; the raw technical codes stay in an expandable developer section. Honest by construction:
 * nothing is ever shown as "synced" that the Hub has not explicitly accepted.
 */
import type { sync } from '@fieldcapture/contracts';

export type SyncCenterCategory =
  | 'saved-on-phone'
  | 'waiting-to-sync'
  | 'waiting-on-you'
  | 'accepted-by-hub'
  | 'needs-review'
  | 'rejected-by-hub';

/** Plain-language, worker-facing labels (spec 7.15). */
export const SYNC_CENTER_LABELS: Record<SyncCenterCategory, string> = {
  'saved-on-phone': 'Saved on this phone',
  'waiting-to-sync': 'Waiting to sync',
  'waiting-on-you': 'Waiting on you',
  'accepted-by-hub': 'Accepted by Hub',
  'needs-review': 'Needs office review',
  'rejected-by-hub': 'Rejected by Hub',
};

/** Display order, worst/most-actionable last so it reads top-to-bottom as a lifecycle. */
export const SYNC_CENTER_ORDER: readonly SyncCenterCategory[] = [
  'saved-on-phone',
  'waiting-to-sync',
  'accepted-by-hub',
  'waiting-on-you',
  'needs-review',
  'rejected-by-hub',
];

/** One outbox row, reduced to just what the rollup needs. */
export interface SyncCenterEvidence {
  state: sync.OutboxItemState;
  /** Present on a 403/409 "blocked" row — it is waiting on the worker to act, not on the network. */
  lastRejectionCode?: string;
}

/** One blob/upload row, reduced. */
export interface SyncCenterBlob {
  /** True once the Hub confirmed the attachment.link — the byte is durably owned by the Hub. */
  linkConfirmed: boolean;
}

export interface SyncCenterInput {
  /** Drafts saved locally but never submitted (FieldTicketDraft / ReceiptDraft count). */
  draftCount: number;
  evidence: readonly SyncCenterEvidence[];
  /** Live uploads; empty until the ADR-004 upload path is wired (Section 4e). */
  blobs?: readonly SyncCenterBlob[];
}

export interface SyncCenterSummary {
  counts: Record<SyncCenterCategory, number>;
  /** Total tracked items across every bucket. */
  total: number;
  /** True when something is owed to the Hub or needs the worker/office (drives the badge). */
  hasOutstanding: boolean;
}

/**
 * Bucket the durable state into worker-facing categories:
 *  - saved-on-phone: local drafts not yet submitted.
 *  - waiting-to-sync: owed to Hub over the network (pending without a block, in-flight, unlinked blobs).
 *  - waiting-on-you: a 403/409 block the worker must clear (e.g. clock in, finish a required step).
 *  - accepted-by-hub: Hub-accepted submits + linked blobs (the only "durable on Hub" bucket).
 *  - needs-review / rejected-by-hub: office adjudication / hard rejection.
 */
export function summarizeSyncCenter(input: SyncCenterInput): SyncCenterSummary {
  const blobs = input.blobs ?? [];
  const counts: Record<SyncCenterCategory, number> = {
    'saved-on-phone': input.draftCount,
    'waiting-to-sync':
      input.evidence.filter(
        (e) =>
          (e.state === 'pending' && e.lastRejectionCode === undefined) || e.state === 'in-flight',
      ).length + blobs.filter((b) => !b.linkConfirmed).length,
    'waiting-on-you': input.evidence.filter(
      (e) => e.state === 'pending' && e.lastRejectionCode !== undefined,
    ).length,
    'accepted-by-hub':
      input.evidence.filter((e) => e.state === 'accepted').length +
      blobs.filter((b) => b.linkConfirmed).length,
    'needs-review': input.evidence.filter((e) => e.state === 'needs-review').length,
    'rejected-by-hub': input.evidence.filter((e) => e.state === 'rejected').length,
  };
  const total = SYNC_CENTER_ORDER.reduce((sum, key) => sum + counts[key], 0);
  const hasOutstanding =
    counts['saved-on-phone'] +
      counts['waiting-to-sync'] +
      counts['waiting-on-you'] +
      counts['needs-review'] +
      counts['rejected-by-hub'] >
    0;
  return { counts, total, hasOutstanding };
}
