/**
 * Sync pages (GUI Master §14 / screens 70–74) — the driver's reassurance surface: "is my work
 * safe?" Every screen here is honest and calm — work is always saved on the phone first, then
 * synced to Ops Hub when a connection is available. Driver-facing only (GUI Master §20): we never
 * render payloads, queues, UUIDs, server versions, hub URLs, or raw errors. Failed items get a
 * plain-English reason, a Retry, and a path to support — the technical detail stays admin-only.
 *
 * Screens:
 *   70. SyncHomeScreen        — overall state + Pending/Failed/Synced counts + Sync Now
 *   71. PendingSyncItemsScreen — the per-item list with per-item status
 *   72. SyncFailedItemsScreen  — only-when-needed failed cards with Retry / Details / Support
 *   73. SyncItemDetailScreen   — one item's driver-facing detail + admin-only technical expander
 *   74. SyncCompleteScreen     — the calm "All Work Synced" confirmation
 *
 * Presentational + props-driven only: no domain/runtime/data imports. The real sync engine lives
 * elsewhere and feeds these screens primitive props + callbacks.
 */
import { useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  StatusBadge,
  spacing,
  useResolvedTheme,
  typeScale,
  type Theme,
  type Tone,
} from '../design';

/* -------------------------------------------------------------------------- */
/* Shared status vocabulary (GUI Master §20 status set)                        */
/* -------------------------------------------------------------------------- */

/** The sync lifecycle states a driver is allowed to see. */
export type SyncItemStatus = 'Saved on Phone' | 'Pending Sync' | 'Syncing' | 'Synced' | 'Failed';

/** The overall state of the phone's outbox, shown on Sync Home. */
export type SyncOverallState =
  | 'All Work Synced'
  | 'Saved on Phone'
  | 'Pending Sync'
  | 'Sync Failed'
  | 'Offline Mode';

const ITEM_STATUS_TONE: Record<SyncItemStatus, Tone> = {
  'Saved on Phone': 'info',
  'Pending Sync': 'warning',
  Syncing: 'info',
  Synced: 'success',
  Failed: 'danger',
};

const OVERALL_TONE: Record<SyncOverallState, Tone> = {
  'All Work Synced': 'success',
  'Saved on Phone': 'info',
  'Pending Sync': 'warning',
  'Sync Failed': 'danger',
  'Offline Mode': 'neutral',
};

/** A single item in the phone's outbox, in driver-facing language (no IDs/payloads). */
export interface SyncItem {
  /** Stable list key — a short driver-safe slug, never a UUID. */
  key: string;
  /** Driver-readable label, e.g. "Field Ticket TKT-10488". */
  label: string;
  status: SyncItemStatus;
}

/* -------------------------------------------------------------------------- */
/* 70. Sync Home                                                               */
/* -------------------------------------------------------------------------- */

/** Plain-English reassurance line for each overall state. */
function overallDetail(state: SyncOverallState, pending: number): string {
  switch (state) {
    case 'All Work Synced':
      return 'Everything on this phone has been sent to Ops Hub.';
    case 'Saved on Phone':
    case 'Pending Sync':
      return `${pending} item${pending === 1 ? '' : 's'} will sync when connection returns.`;
    case 'Sync Failed':
      return 'Some items could not sync. Your work is still safe on this phone.';
    case 'Offline Mode':
      return 'You are offline. Work is saved on this phone and will sync automatically when you reconnect.';
    default:
      return 'Your work is saved on this phone.';
  }
}

export function SyncHomeScreen(props: {
  overallState?: SyncOverallState;
  pendingCount?: number;
  failedCount?: number;
  syncedCount?: number;
  lastSyncedAt?: string;
  syncing?: boolean;
  onSyncNow: () => void;
  onViewPending: () => void;
  onViewFailed: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const state = props.overallState ?? 'Saved on Phone';
  const pending = props.pendingCount ?? 5;
  const failed = props.failedCount ?? 0;
  const synced = props.syncedCount ?? 12;
  const lastSynced = props.lastSyncedAt ?? 'today at 8:31 AM';
  const syncing = props.syncing ?? false;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Sync</Text>

      <Card theme={t} title="Your work is safe" testID="sync-home-status">
        <StatusBadge label={state} tone={OVERALL_TONE[state]} testID="sync-home-state" />
        <Text style={[styles.body2, { color: t.text }]}>{overallDetail(state, pending)}</Text>
        <Text style={[styles.meta, { color: t.textMuted }]}>Last synced {lastSynced}.</Text>
      </Card>

      <Card theme={t} title="Counts">
        <View style={styles.counts}>
          <CountTile theme={t} label="Pending" value={pending} tone="warning" />
          <CountTile
            theme={t}
            label="Failed"
            value={failed}
            tone={failed > 0 ? 'danger' : 'neutral'}
          />
          <CountTile theme={t} label="Synced" value={synced} tone="success" />
        </View>
      </Card>

      <Card theme={t} tone="highlight" title="Keep your work moving">
        <Text style={[styles.body2, { color: t.text }]}>
          {state === 'All Work Synced'
            ? 'Nothing is waiting. You can keep working — new items sync on their own.'
            : 'Your saved work syncs automatically. Tap Sync Now to push waiting work and re-check with Ops Hub. If you are offline, items go automatically when connection returns.'}
        </Text>
        <Button
          theme={t}
          label={syncing ? 'Syncing…' : 'Sync Now'}
          onPress={props.onSyncNow}
          disabled={syncing}
          testID="sync-home-sync-now"
        />
      </Card>

      <Card theme={t} title="Review items">
        <Text style={[styles.body2, { color: t.textMuted }]}>
          See exactly what is waiting, or fix anything that did not go through.
        </Text>
        <Button
          theme={t}
          variant="secondary"
          label={pending > 0 ? `View Pending Items (${pending})` : 'View Pending Items'}
          onPress={props.onViewPending}
          testID="sync-home-view-pending"
        />
        {failed > 0 ? (
          <Button
            theme={t}
            variant="secondary"
            label={`View Failed Items (${failed})`}
            onPress={props.onViewFailed}
            testID="sync-home-view-failed"
          />
        ) : null}
      </Card>
    </View>
  );
}

function CountTile(props: { label: string; value: number; tone: Tone; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={[styles.countTile, { borderColor: t.border, backgroundColor: t.cardMuted }]}>
      <Text style={[styles.countValue, { color: t.text }]}>{props.value}</Text>
      <StatusBadge label={props.label} tone={props.tone} />
    </View>
  );
}

/* -------------------------------------------------------------------------- */
/* 71. Pending Sync Items                                                      */
/* -------------------------------------------------------------------------- */

/** A realistic sample outbox used when no items are supplied (GUI Master §14.71 list). */
const SAMPLE_ITEMS: readonly SyncItem[] = [
  { key: 'punch-in', label: 'Punch In Event', status: 'Synced' },
  { key: 'pre-trip', label: 'Pre-Trip Inspection', status: 'Synced' },
  { key: 'jha', label: 'JHA/JSA for SR 2026-000001', status: 'Synced' },
  { key: 'ticket', label: 'Field Ticket TKT-10488', status: 'Pending Sync' },
  { key: 'photos', label: '2 Photos', status: 'Pending Sync' },
  { key: 'receipt', label: 'Receipt', status: 'Saved on Phone' },
  { key: 'gps-arrival', label: 'GPS Arrival', status: 'Syncing' },
  { key: 'post-trip', label: 'Post-Trip Inspection', status: 'Saved on Phone' },
  { key: 'punch-out', label: 'Punch Out Event', status: 'Saved on Phone' },
];

export function PendingSyncItemsScreen(props: {
  items?: readonly SyncItem[];
  syncing?: boolean;
  onSyncNow: () => void;
  onOpenItem: (key: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const items = props.items ?? SAMPLE_ITEMS;
  const syncing = props.syncing ?? false;
  const waiting = items.filter((i) => i.status !== 'Synced').length;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Sync Items</Text>
      <Text style={[styles.meta, { color: t.textMuted }]}>
        {waiting === 0
          ? 'All items have synced to Ops Hub.'
          : `${waiting} item${waiting === 1 ? '' : 's'} still to sync. Everything here is saved on this phone.`}
      </Text>

      <Card theme={t} title="Today’s items">
        {items.map((item) => (
          <SyncItemRow theme={t} key={item.key} item={item} onPress={props.onOpenItem} />
        ))}
      </Card>

      <Button
        theme={t}
        label={syncing ? 'Syncing…' : 'Sync Now'}
        onPress={props.onSyncNow}
        disabled={syncing || waiting === 0}
        testID="pending-sync-now"
      />
    </View>
  );
}

/** A bordered, full-width tappable row showing a sync item's label + its status badge. */
function SyncItemRow(props: { item: SyncItem; onPress: (key: string) => void; theme: Theme }) {
  const t = props.theme;
  const { item } = props;
  return (
    <Pressable
      testID={`pending-item-${item.key}`}
      onPress={() => props.onPress(item.key)}
      accessibilityRole="button"
      accessibilityLabel={`${item.label}, ${item.status}`}
      style={({ pressed }) => [
        styles.itemRow,
        { borderColor: t.border, backgroundColor: t.card },
        pressed ? styles.pressed : null,
      ]}
    >
      <Text style={[styles.rowLabel, { color: t.text }]} numberOfLines={2}>
        {item.label}
      </Text>
      <StatusBadge label={item.status} tone={ITEM_STATUS_TONE[item.status]} />
    </Pressable>
  );
}

/* -------------------------------------------------------------------------- */
/* 72. Sync Failed Items                                                       */
/* -------------------------------------------------------------------------- */

/** A failed item in driver-facing language — no error codes, stack traces, or payloads. */
export interface FailedSyncItem {
  key: string;
  label: string;
  /** Plain-English reason, e.g. "Could not reach Ops Hub." Defaults to a generic line. */
  reason?: string;
}

const SAMPLE_FAILED: readonly FailedSyncItem[] = [
  { key: 'ticket', label: 'Field Ticket TKT-10488' },
];

export function SyncFailedItemsScreen(props: {
  items?: readonly FailedSyncItem[];
  retryingKey?: string;
  onRetry: (key: string) => void;
  onViewDetails: (key: string) => void;
  onContactSupport: (key: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const items = props.items ?? SAMPLE_FAILED;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Couldn’t Sync</Text>
      <Text style={[styles.meta, { color: t.textMuted }]}>
        These items are still saved on this phone. Nothing has been lost — try again, or get help.
      </Text>

      {items.map((item) => (
        <FailedItemCard
          theme={t}
          key={item.key}
          item={item}
          initialRetrying={props.retryingKey === item.key}
          onRetry={props.onRetry}
          onViewDetails={props.onViewDetails}
          onContactSupport={props.onContactSupport}
        />
      ))}
    </View>
  );
}

/**
 * A single failed-item card. Self-managing: tapping Retry / View Details / Contact Support flips
 * internal state so the driver sees an inline confirmation line, while still calling the existing
 * navigation callbacks the app drives.
 */
function FailedItemCard(props: {
  item: FailedSyncItem;
  initialRetrying: boolean;
  onRetry: (key: string) => void;
  onViewDetails: (key: string) => void;
  onContactSupport: (key: string) => void;
  theme: Theme;
}) {
  const t = props.theme;
  const { item } = props;
  const [retrying, setRetrying] = useState(props.initialRetrying);
  const [notice, setNotice] = useState<string | null>(null);

  return (
    <Card theme={t} title={item.label} testID={`failed-item-${item.key}`}>
      <StatusBadge label="Failed" tone="danger" />
      <Text style={[styles.body2, { color: t.text }]}>{item.reason ?? 'Could not sync.'}</Text>
      <Text style={[styles.meta, { color: t.textMuted }]}>Saved on this phone.</Text>
      <Button
        theme={t}
        label={retrying ? 'Retrying…' : 'Retry'}
        onPress={() => {
          setRetrying(true);
          setNotice('Retrying now…');
          props.onRetry(item.key);
        }}
        disabled={retrying}
        testID={`failed-retry-${item.key}`}
      />
      <Button
        theme={t}
        variant="secondary"
        label="View Details"
        onPress={() => {
          setNotice('Opening details…');
          props.onViewDetails(item.key);
        }}
        testID={`failed-details-${item.key}`}
      />
      <Button
        theme={t}
        variant="secondary"
        label="Contact Support"
        onPress={() => {
          setNotice('Contacting support…');
          props.onContactSupport(item.key);
        }}
        testID={`failed-support-${item.key}`}
      />
      {notice !== null ? (
        <Text style={[styles.meta, { color: t.textMuted }]} testID={`failed-notice-${item.key}`}>
          {notice}
        </Text>
      ) : null}
    </Card>
  );
}

/* -------------------------------------------------------------------------- */
/* 73. Sync Item Detail                                                        */
/* -------------------------------------------------------------------------- */

export function SyncItemDetailScreen(props: {
  itemLabel?: string;
  status?: SyncItemStatus;
  savedAt?: string;
  lastAttemptAt?: string;
  /** Plain-English line shown for a failed item. Drivers never see raw errors. */
  failureReason?: string;
  /** Whether this device is an admin device that may reveal technical detail. */
  isAdmin?: boolean;
  /** Admin-only technical lines (only rendered when isAdmin AND expanded). */
  technicalDetails?: readonly string[];
  onRetry?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const label = props.itemLabel ?? 'Field Ticket TKT-10488';
  const status = props.status ?? 'Pending Sync';
  const savedAt = props.savedAt ?? 'Today at 10:44 AM';
  const lastAttempt = props.lastAttemptAt ?? 'Today at 10:47 AM';
  const isAdmin = props.isAdmin ?? false;
  const [showTech, setShowTech] = useState(false);

  const techLines = props.technicalDetails ?? [];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Item</Text>

      <Card theme={t} title={label} testID="item-detail-card">
        <DetailRow theme={t} field="Status">
          <StatusBadge label={status} tone={ITEM_STATUS_TONE[status]} testID="item-detail-status" />
        </DetailRow>
        <DetailRow theme={t} field="Saved">
          <Text style={[styles.detailValue, { color: t.text }]}>{savedAt}</Text>
        </DetailRow>
        <DetailRow theme={t} field="Last attempt">
          <Text style={[styles.detailValue, { color: t.text }]}>{lastAttempt}</Text>
        </DetailRow>
        {props.failureReason !== undefined ? (
          <DetailRow theme={t} field="What happened">
            <Text style={[styles.detailValue, { color: t.text }]}>{props.failureReason}</Text>
          </DetailRow>
        ) : null}
      </Card>

      {status === 'Failed' && props.onRetry !== undefined ? (
        <Button theme={t} label="Retry" onPress={props.onRetry} testID="item-detail-retry" />
      ) : null}

      {isAdmin ? (
        <Card theme={t} title="Admin">
          <Button
            theme={t}
            variant="secondary"
            label={showTech ? 'Hide Technical Details' : 'Technical Details'}
            onPress={() => setShowTech((v) => !v)}
            testID="item-detail-tech-toggle"
          />
          {showTech ? (
            <View style={styles.techBox}>
              {techLines.length === 0 ? (
                <Text style={[styles.meta, { color: t.textMuted }]}>
                  No additional technical detail recorded.
                </Text>
              ) : (
                techLines.map((line, i) => (
                  <Text key={`tech-${i}`} style={[styles.techLine, { color: t.textMuted }]}>
                    {line}
                  </Text>
                ))
              )}
            </View>
          ) : null}
        </Card>
      ) : null}
    </View>
  );
}

function DetailRow(props: { field: string; children: ReactNode; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.detailRow}>
      <Text style={[styles.detailField, { color: t.textMuted }]}>{props.field}</Text>
      {props.children}
    </View>
  );
}

/* -------------------------------------------------------------------------- */
/* 74. Sync Complete                                                           */
/* -------------------------------------------------------------------------- */

export function SyncCompleteScreen(props: {
  lastSyncedAt?: string;
  syncedCount?: number;
  onDone: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const lastSynced = props.lastSyncedAt ?? 'today at 5:52 PM';
  const synced = props.syncedCount;

  return (
    <View style={styles.bodyCentered}>
      <Card theme={t} tone="highlight" title="All Work Synced" testID="sync-complete-card">
        <StatusBadge label="Synced" tone="success" testID="sync-complete-state" />
        <Text style={[styles.body2, { color: t.text }]}>
          {synced !== undefined
            ? `${synced} item${synced === 1 ? '' : 's'} sent to Ops Hub.`
            : 'Everything on this phone has been sent to Ops Hub.'}
        </Text>
        <Text style={[styles.meta, { color: t.textMuted }]}>Last synced {lastSynced}.</Text>
        <Button theme={t} label="Done" onPress={props.onDone} testID="sync-complete-done" />
      </Card>
    </View>
  );
}

/* -------------------------------------------------------------------------- */
/* Styles                                                                      */
/* -------------------------------------------------------------------------- */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  bodyCentered: {
    padding: spacing.lg,
    gap: spacing.md,
    flex: 1,
    justifyContent: 'center',
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  meta: {
    fontSize: typeScale.label,
  },
  counts: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  countTile: {
    flex: 1,
    borderWidth: 1,
    borderRadius: 12,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.sm,
    alignItems: 'center',
    gap: spacing.xs,
  },
  countValue: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  itemRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.sm,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 10,
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    minHeight: 56,
  },
  pressed: {
    opacity: 0.7,
  },
  rowLabel: {
    flex: 1,
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  detailRow: {
    paddingVertical: spacing.sm,
    gap: spacing.xs,
  },
  detailField: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  detailValue: {
    fontSize: typeScale.body,
  },
  techBox: {
    gap: spacing.xs,
    paddingTop: spacing.sm,
  },
  techLine: {
    fontSize: typeScale.caption,
  },
});
