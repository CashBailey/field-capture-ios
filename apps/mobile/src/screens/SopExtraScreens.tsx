/**
 * SOP extra screens (GUI Master §13 / screens 63–69) — the rest of the SOP section that sits beside
 * the SOP Library (screen 62, defined in SopScreens.tsx — not duplicated here):
 *
 *   63. Required Driver SOPs   — the SOPs every driver must have read/acknowledged.
 *   64. Job-Specific SOPs      — SOPs attached to the current job (e.g. produced water haul).
 *   65. Emergency SOPs         — fast-access emergency procedures, reachable everywhere.
 *   66. Recently Updated SOPs  — changed SOPs that need a fresh review.
 *   67. SOP Search             — filtered search across the SOP set.
 *   68. SOP Reader             — a single SOP in a mobile-friendly read layout.
 *   69. SOP Acknowledgement    — the "I reviewed and understand" confirm modal.
 *
 * Presentational + props-driven only. No backend imports. Driver-facing language only — no UUIDs,
 * versions-as-hashes, payloads, queues, or storage internals. Realistic sample fallbacks fill any
 * absent prop so each screen renders meaningful content in isolation.
 *
 * Interaction model: every control is SELF-MANAGING. Selected/active styling renders from internal
 * useState (seeded from the matching optional prop when present), tapping updates that state so the
 * control visibly responds, and the existing optional callback still fires. Required nav callbacks
 * (onOpenSop/onReviewSop/onAcknowledge/onCancel/onBackToJob) stay as-is so the app drives routing.
 * Local action buttons with no real effect yet (Save Offline, Share with Supervisor) give inline
 * visible feedback instead of a silent no-op. The app shell owns the single scroll — each screen is
 * a plain View.
 */
import { useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import {
  Button,
  Card,
  StatusBadge,
  spacing,
  typeScale,
  useResolvedTheme,
  type Theme,
  type Tone,
} from '../design';

/* ------------------------------------------------------------------ shared */

/** The driver-facing status of one SOP, drawn from the GUI Master §20 status set. */
export type SopStatus =
  | 'Required'
  | 'Needs Review'
  | 'Complete'
  | 'Not Started'
  | 'Synced'
  | 'Saved on Phone';

const SOP_STATUS_TONE: Record<SopStatus, Tone> = {
  Required: 'warning',
  'Needs Review': 'warning',
  Complete: 'success',
  'Not Started': 'neutral',
  Synced: 'success',
  'Saved on Phone': 'info',
};

/** A single SOP as the list/search/reader screens receive it (primitive fields only). */
export interface SopSummary {
  id: string;
  title: string;
  role?: string;
  version?: string;
  updated?: string;
  category?: string;
  status?: SopStatus;
  availableOffline?: boolean;
}

function StatusPill(props: { status: SopStatus }) {
  return <StatusBadge label={props.status} tone={SOP_STATUS_TONE[props.status]} />;
}

/** One SOP row rendered as a tappable Card; shared by the list-style screens. */
function SopRow(props: {
  sop: SopSummary;
  onPress: (id: string) => void;
  theme: Theme;
  testID?: string;
}) {
  const { sop, theme: t } = props;
  return (
    <Pressable
      onPress={() => props.onPress(sop.id)}
      accessibilityRole="button"
      accessibilityLabel={sop.title}
      {...(props.testID !== undefined ? { testID: props.testID } : {})}
    >
      <Card theme={t} title={sop.title}>
        <View style={styles.rowWrap}>
          {sop.role !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>Role: {sop.role}</Text>
          ) : null}
          {sop.category !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>{sop.category}</Text>
          ) : null}
          {sop.version !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>{sop.version}</Text>
          ) : null}
          {sop.updated !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>Updated {sop.updated}</Text>
          ) : null}
        </View>
        <View style={styles.badgeRow}>
          {sop.status !== undefined ? <StatusPill status={sop.status} /> : null}
          {sop.availableOffline === true ? (
            <StatusBadge label="Available Offline" tone="info" />
          ) : null}
        </View>
      </Card>
    </Pressable>
  );
}

/* -------------------------------------------------- 63. Required Driver SOPs */

const REQUIRED_BASE: readonly SopSummary[] = [
  { id: 'r1', title: 'Driver Daily Workday Procedure', status: 'Complete' },
  { id: 'r2', title: 'DVIR / Vehicle Inspection', status: 'Complete' },
  { id: 'r3', title: 'Vacuum Truck Loading and Unloading', status: 'Required' },
  { id: 'r4', title: 'H2S Safety', status: 'Needs Review' },
  { id: 'r5', title: 'PPE Requirements', status: 'Complete' },
  { id: 'r6', title: 'Hose Handling', status: 'Required' },
  { id: 'r7', title: 'Spill Response', status: 'Required' },
  { id: 'r8', title: 'Stop Work Authority', status: 'Complete' },
  { id: 'r9', title: 'Heat Stress', status: 'Not Started' },
  { id: 'r10', title: 'Vehicle Incident Response', status: 'Required' },
];

const DEFAULT_REQUIRED: readonly SopSummary[] = REQUIRED_BASE.map((s) => ({
  ...s,
  role: 'Driver',
  version: 'Version 3',
  updated: 'May 14, 2026',
  availableOffline: true,
}));

export function RequiredDriverSopsScreen(props: {
  sops?: readonly SopSummary[];
  title?: string;
  onOpenSop: (id: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sops = props.sops ?? DEFAULT_REQUIRED;
  const outstanding = sops.filter(
    (s) => s.status === 'Required' || s.status === 'Needs Review' || s.status === 'Not Started',
  ).length;
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>{props.title ?? 'Required Driver SOPs'}</Text>
      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          {outstanding === 0
            ? 'You have reviewed every SOP required for your role. Nice work.'
            : `${outstanding} of ${sops.length} SOPs still need your review before you are fully signed off as a driver.`}
        </Text>
      </Card>
      {sops.map((sop) => (
        <SopRow
          key={sop.id}
          sop={sop}
          onPress={props.onOpenSop}
          theme={t}
          testID={`required-sop-${sop.id}`}
        />
      ))}
    </View>
  );
}

/* ------------------------------------------------------ 64. Job-Specific SOPs */

const JOB_SOPS_BASE: readonly SopSummary[] = [
  { id: 'j1', title: 'Vacuum Truck Loading and Unloading', status: 'Complete' },
  { id: 'j2', title: 'H2S Safety', status: 'Needs Review' },
  { id: 'j3', title: 'Hose Handling', status: 'Required' },
  { id: 'j4', title: 'Spill Response', status: 'Required' },
  { id: 'j5', title: 'Stop Work Authority', status: 'Complete' },
  { id: 'j6', title: 'Customer Site Rules', status: 'Required' },
];

const DEFAULT_JOB_SOPS: readonly SopSummary[] = JOB_SOPS_BASE.map((s) => ({
  ...s,
  role: 'Driver',
  version: 'Version 2',
  availableOffline: true,
}));

export function JobSpecificSopsScreen(props: {
  jobType?: string;
  customer?: string;
  lease?: string;
  well?: string;
  sops?: readonly SopSummary[];
  onOpenSop: (id: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sops = props.sops ?? DEFAULT_JOB_SOPS;
  const jobType = props.jobType ?? 'Produced Water Haul';
  const customer = props.customer ?? 'Acme Energy';
  const lease = props.lease ?? 'Northfield';
  const well = props.well ?? '114H';
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Job-Specific SOPs</Text>
      <Card theme={t} title={jobType}>
        <Text style={[styles.body2, { color: t.textMuted }]}>
          {customer} · {lease} {well}
        </Text>
        <Text style={[styles.body2, { color: t.text }]}>
          These procedures apply to this job. Review them before you start work on site.
        </Text>
      </Card>
      {sops.map((sop) => (
        <SopRow
          key={sop.id}
          sop={sop}
          onPress={props.onOpenSop}
          theme={t}
          testID={`job-sop-${sop.id}`}
        />
      ))}
    </View>
  );
}

/* ---------------------------------------------------------- 65. Emergency SOPs */

export interface EmergencySop {
  id: string;
  title: string;
}

const DEFAULT_EMERGENCY: readonly EmergencySop[] = [
  { id: 'e1', title: 'H2S Alarm' },
  { id: 'e2', title: 'Spill / Release' },
  { id: 'e3', title: 'Fire' },
  { id: 'e4', title: 'Heat Illness' },
  { id: 'e5', title: 'Vehicle Incident' },
  { id: 'e6', title: 'Unsafe Road' },
  { id: 'e7', title: 'Stop Work Authority' },
  { id: 'e8', title: 'Emergency Contacts' },
];

export function EmergencySopsScreen(props: {
  sops?: readonly EmergencySop[];
  onOpenSop: (id: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sops = props.sops ?? DEFAULT_EMERGENCY;
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Emergency SOPs</Text>
      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          Stop work and make the area safe first. Open the procedure that matches the emergency for
          step-by-step actions. These stay available offline.
        </Text>
      </Card>
      {sops.map((sop) => (
        <Card key={sop.id} theme={t} title={sop.title} testID={`emergency-sop-${sop.id}`}>
          <View style={styles.badgeRow}>
            <StatusBadge label="Available Offline" tone="info" />
          </View>
          <Button
            theme={t}
            variant="destructive"
            label="Open Emergency Procedure"
            onPress={() => props.onOpenSop(sop.id)}
            testID={`emergency-open-${sop.id}`}
          />
        </Card>
      ))}
    </View>
  );
}

/* ----------------------------------------------------- 66. Recently Updated SOPs */

const RECENT_BASE: readonly SopSummary[] = [
  { id: 'u1', title: 'H2S Safety Procedure', updated: 'May 14, 2026', status: 'Needs Review' },
  { id: 'u2', title: 'Hose Handling', updated: 'May 9, 2026', status: 'Needs Review' },
  { id: 'u3', title: 'Spill Response', updated: 'May 2, 2026', status: 'Needs Review' },
];

const DEFAULT_RECENT: readonly SopSummary[] = RECENT_BASE.map((s) => ({
  ...s,
  role: 'Driver',
  version: 'Version 4',
  availableOffline: true,
}));

export function RecentlyUpdatedSopsScreen(props: {
  sops?: readonly SopSummary[];
  onReviewSop: (id: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sops = props.sops ?? DEFAULT_RECENT;
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Recently Updated SOPs</Text>
      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          {sops.length === 0
            ? 'No SOPs have changed since your last review.'
            : `${sops.length} SOP${sops.length === 1 ? ' has' : 's have'} changed and need a fresh review.`}
        </Text>
      </Card>
      {sops.map((sop) => (
        <Card key={sop.id} theme={t} title={sop.title} testID={`recent-sop-${sop.id}`}>
          {sop.updated !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>Updated {sop.updated}</Text>
          ) : null}
          <View style={styles.badgeRow}>
            <StatusPill status={sop.status ?? 'Needs Review'} />
            {sop.availableOffline === true ? (
              <StatusBadge label="Available Offline" tone="info" />
            ) : null}
          </View>
          <Button
            theme={t}
            label="Review SOP"
            onPress={() => props.onReviewSop(sop.id)}
            testID={`recent-review-${sop.id}`}
          />
        </Card>
      ))}
    </View>
  );
}

/* ---------------------------------------------------------------- 67. SOP Search */

export type SopSearchFilter = 'all' | 'driver' | 'emergency' | 'job' | 'ack-needed' | 'offline';

const SEARCH_FILTERS: readonly { key: SopSearchFilter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'driver', label: 'Driver' },
  { key: 'job', label: 'Job' },
  { key: 'ack-needed', label: 'Acknowledgement Needed' },
  { key: 'offline', label: 'Available Offline' },
];

const DEFAULT_SEARCH_RESULTS: readonly SopSummary[] = [
  {
    id: 's1',
    title: 'H2S Safety',
    category: 'Emergency',
    status: 'Needs Review',
    version: 'Version 4',
    role: 'Driver',
    availableOffline: true,
  },
  {
    id: 's2',
    title: 'Vacuum Truck Loading and Unloading',
    category: 'Driver',
    status: 'Required',
    version: 'Version 3',
    role: 'Driver',
    availableOffline: true,
  },
  {
    id: 's3',
    title: 'Customer Site Rules',
    category: 'Job',
    status: 'Required',
    version: 'Version 2',
    role: 'Driver',
    availableOffline: false,
  },
  {
    id: 's4',
    title: 'PPE Requirements',
    category: 'Driver',
    status: 'Complete',
    version: 'Version 1',
    role: 'Driver',
    availableOffline: true,
  },
];

function matchesFilter(sop: SopSummary, filter: SopSearchFilter): boolean {
  switch (filter) {
    case 'all':
      return true;
    case 'driver':
      return sop.category === 'Driver';
    case 'emergency':
      return sop.category === 'Emergency';
    case 'job':
      return sop.category === 'Job';
    case 'ack-needed':
      return sop.status === 'Needs Review' || sop.status === 'Required';
    case 'offline':
      return sop.availableOffline === true;
    default:
      return true;
  }
}

export function SopSearchScreen(props: {
  results?: readonly SopSummary[];
  query?: string;
  filter?: SopSearchFilter;
  onQueryChange?: (query: string) => void;
  onFilterChange?: (filter: SopSearchFilter) => void;
  onOpenSop: (id: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const all = props.results ?? DEFAULT_SEARCH_RESULTS;
  const [query, setQuery] = useState(props.query ?? '');
  const [filter, setFilter] = useState<SopSearchFilter>(props.filter ?? 'all');

  const onChangeQuery = (next: string) => {
    setQuery(next);
    props.onQueryChange?.(next);
  };
  const onPickFilter = (next: SopSearchFilter) => {
    setFilter(next);
    props.onFilterChange?.(next);
  };

  const q = query.trim().toLowerCase();
  const results = all.filter(
    (sop) => matchesFilter(sop, filter) && (q === '' || sop.title.toLowerCase().includes(q)),
  );

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>SOP Search</Text>
      <TextInput
        value={query}
        onChangeText={onChangeQuery}
        placeholder="Search SOPs"
        placeholderTextColor={t.textMuted}
        accessibilityLabel="Search SOPs"
        testID="sop-search-input"
        style={[styles.input, { color: t.text, borderColor: t.border, backgroundColor: t.card }]}
      />
      <View style={styles.filters}>
        {SEARCH_FILTERS.map((f) => {
          const selected = f.key === filter;
          return (
            <Pressable
              key={f.key}
              testID={`sop-search-filter-${f.key}`}
              onPress={() => onPickFilter(f.key)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={[
                styles.chip,
                { borderColor: selected ? t.primary : t.border },
                selected ? { backgroundColor: t.primary } : null,
              ]}
            >
              <Text style={[styles.chipText, { color: selected ? t.onPrimary : t.textMuted }]}>
                {f.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {results.length === 0 ? (
        <Card theme={t}>
          <Text style={[styles.body2, { color: t.textMuted }]}>
            No SOPs match your search. Try a different word or filter.
          </Text>
        </Card>
      ) : (
        results.map((sop) => (
          <SopRow
            key={sop.id}
            sop={sop}
            onPress={props.onOpenSop}
            theme={t}
            testID={`sop-search-result-${sop.id}`}
          />
        ))
      )}
    </View>
  );
}

/* ---------------------------------------------------------------- 68. SOP Reader */

export interface SopReaderContent {
  title: string;
  version?: string;
  role?: string;
  status?: SopStatus;
  availableOffline?: boolean;
  summary?: string;
  steps?: readonly string[];
  ppe?: readonly string[];
  warnings?: readonly string[];
  emergencyActions?: readonly string[];
  relatedForms?: readonly string[];
}

const DEFAULT_READER: Required<
  Pick<
    SopReaderContent,
    | 'title'
    | 'version'
    | 'role'
    | 'status'
    | 'availableOffline'
    | 'summary'
    | 'steps'
    | 'ppe'
    | 'warnings'
    | 'emergencyActions'
    | 'relatedForms'
  >
> = {
  title: 'H2S Safety',
  version: 'Version 4',
  role: 'Driver',
  status: 'Needs Review',
  availableOffline: true,
  summary:
    'Hydrogen sulfide can be present at well sites and tank batteries. Always wear your monitor, know the wind direction, and move upwind and uphill if an alarm sounds.',
  steps: [
    'Turn on and bump-test your H2S monitor before leaving the yard.',
    'On arrival, check the wind sock and note your upwind escape route.',
    'Keep your monitor on and within hearing range at all times.',
    'If an alarm sounds, hold your breath, move upwind and uphill, and account for others.',
  ],
  ppe: ['Personal H2S monitor', 'FR clothing', 'Safety glasses', 'Steel-toe boots', 'Hard hat'],
  warnings: [
    'H2S is heavier than air and collects in low spots.',
    'You can lose your sense of smell at dangerous concentrations — never rely on odor.',
  ],
  emergencyActions: [
    'Move upwind and uphill to the muster point.',
    'Call for help and account for all personnel.',
    'Do not re-enter the area until it is declared safe.',
  ],
  relatedForms: ['JHA / JSA', 'Vehicle Incident Report'],
};

function ReaderSection(props: { title: string; theme: Theme; children: ReactNode }) {
  return (
    <Card theme={props.theme} title={props.title}>
      {props.children}
    </Card>
  );
}

function BulletList(props: { items: readonly string[]; theme: Theme }) {
  return (
    <>
      {props.items.map((item, i) => (
        <View key={`${i}-${item}`} style={styles.bulletRow}>
          <Text style={[styles.bullet, { color: props.theme.textMuted }]}>•</Text>
          <Text style={[styles.body2, styles.bulletText, { color: props.theme.text }]}>{item}</Text>
        </View>
      ))}
    </>
  );
}

function StepList(props: { items: readonly string[]; theme: Theme }) {
  return (
    <>
      {props.items.map((item, i) => (
        <View key={`${i}-${item}`} style={styles.bulletRow}>
          <Text style={[styles.stepNum, { color: props.theme.primary }]}>{i + 1}.</Text>
          <Text style={[styles.body2, styles.bulletText, { color: props.theme.text }]}>{item}</Text>
        </View>
      ))}
    </>
  );
}

export function SopReaderScreen(props: {
  sop?: SopReaderContent;
  onAcknowledge: () => void;
  onSaveOffline?: () => void;
  onShareWithSupervisor?: () => void;
  onBackToJob: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sop = props.sop ?? DEFAULT_READER;
  const status = sop.status ?? DEFAULT_READER.status;

  // Self-managing local actions: "Save Offline" and "Share with Supervisor" have no real effect
  // yet, so they flip internal state and show an inline confirmation instead of a silent no-op.
  // Seed the saved-offline flag from the SOP so a SOP already offline reads as saved on open.
  const [savedOffline, setSavedOffline] = useState(sop.availableOffline ?? false);
  const [shared, setShared] = useState(false);

  const onSaveOffline = () => {
    setSavedOffline(true);
    props.onSaveOffline?.();
  };
  const onShare = () => {
    setShared(true);
    props.onShareWithSupervisor?.();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>{sop.title}</Text>
      <Card theme={t}>
        <View style={styles.rowWrap}>
          {sop.version !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>{sop.version}</Text>
          ) : null}
          {sop.role !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>Role: {sop.role}</Text>
          ) : null}
        </View>
        <View style={styles.badgeRow}>
          <StatusPill status={status} />
          {savedOffline ? <StatusBadge label="Available Offline" tone="info" /> : null}
        </View>
      </Card>

      {sop.summary !== undefined ? (
        <Card theme={t} tone="highlight" title="Important summary">
          <Text style={[styles.body2, { color: t.text }]}>{sop.summary}</Text>
        </Card>
      ) : null}

      {sop.steps !== undefined && sop.steps.length > 0 ? (
        <ReaderSection theme={t} title="Procedure steps">
          <StepList items={sop.steps} theme={t} />
        </ReaderSection>
      ) : null}

      {sop.ppe !== undefined && sop.ppe.length > 0 ? (
        <ReaderSection theme={t} title="Required PPE">
          <BulletList items={sop.ppe} theme={t} />
        </ReaderSection>
      ) : null}

      {sop.warnings !== undefined && sop.warnings.length > 0 ? (
        <ReaderSection theme={t} title="Warnings">
          <BulletList items={sop.warnings} theme={t} />
        </ReaderSection>
      ) : null}

      {sop.emergencyActions !== undefined && sop.emergencyActions.length > 0 ? (
        <ReaderSection theme={t} title="Emergency actions">
          <BulletList items={sop.emergencyActions} theme={t} />
        </ReaderSection>
      ) : null}

      {sop.relatedForms !== undefined && sop.relatedForms.length > 0 ? (
        <ReaderSection theme={t} title="Related forms">
          <BulletList items={sop.relatedForms} theme={t} />
        </ReaderSection>
      ) : null}

      <Button
        theme={t}
        label="Acknowledge"
        onPress={props.onAcknowledge}
        testID="sop-reader-acknowledge"
      />
      <Button
        theme={t}
        variant="secondary"
        label={savedOffline ? 'Saved Offline' : 'Save Offline'}
        onPress={onSaveOffline}
        disabled={savedOffline}
        testID="sop-reader-save-offline"
      />
      {savedOffline ? (
        <Text style={[styles.feedback, { color: t.textMuted }]} testID="sop-reader-save-feedback">
          Saved on this phone
        </Text>
      ) : null}
      <Button
        theme={t}
        variant="secondary"
        label={shared ? 'Shared with Supervisor' : 'Share with Supervisor'}
        onPress={onShare}
        testID="sop-reader-share"
      />
      {shared ? (
        <Text style={[styles.feedback, { color: t.textMuted }]} testID="sop-reader-share-feedback">
          Sent to your supervisor
        </Text>
      ) : null}
      <Button
        theme={t}
        variant="secondary"
        label="Back to Job"
        onPress={props.onBackToJob}
        testID="sop-reader-back"
      />
    </View>
  );
}

/* ------------------------------------------------------- 69. SOP Acknowledgement */

export function SopAcknowledgementScreen(props: {
  sopTitle?: string;
  acknowledged?: boolean;
  acknowledgedBy?: string;
  acknowledgedAt?: string;
  onAcknowledge: () => void;
  onCancel: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const title = props.sopTitle ?? 'H2S Safety';
  const by = props.acknowledgedBy ?? 'You';
  const at = props.acknowledgedAt ?? 'May 16, 2026';

  // Self-managing: the "Acknowledged" state renders from internal state seeded from the prop, so
  // tapping Acknowledge flips the card to the confirmed view immediately while the required nav
  // callback still fires so the app can route on.
  const [acknowledged, setAcknowledged] = useState(props.acknowledged ?? false);

  const onAcknowledge = () => {
    setAcknowledged(true);
    props.onAcknowledge();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Acknowledge SOP?</Text>
      <Card theme={t} tone="highlight" title={title}>
        {acknowledged ? (
          <>
            <View style={styles.badgeRow}>
              <StatusBadge label="Acknowledged" tone="success" />
            </View>
            <Text style={[styles.body2, { color: t.text }]}>
              {by} acknowledged this SOP on {at}.
            </Text>
            <Button
              theme={t}
              variant="secondary"
              label="Done"
              onPress={props.onCancel}
              testID="sop-ack-done"
            />
          </>
        ) : (
          <>
            <Text style={[styles.body2, { color: t.text }]}>
              By acknowledging, you confirm that you reviewed this SOP and understand the driver
              requirements.
            </Text>
            <Button
              theme={t}
              label="Acknowledge"
              onPress={onAcknowledge}
              testID="sop-ack-confirm"
            />
            <Button
              theme={t}
              variant="secondary"
              label="Cancel"
              onPress={props.onCancel}
              testID="sop-ack-cancel"
            />
          </>
        )}
      </Card>
    </View>
  );
}

/* ---------------------------------------------------------------------- styles */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 24,
  },
  meta: {
    fontSize: typeScale.label,
  },
  feedback: {
    fontSize: typeScale.label,
    fontWeight: '600',
    marginTop: -spacing.sm,
  },
  rowWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    columnGap: spacing.md,
    rowGap: spacing.xs,
  },
  badgeRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    marginTop: spacing.xs,
  },
  input: {
    minHeight: 48,
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: spacing.md,
    fontSize: typeScale.body,
  },
  filters: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  chip: {
    borderWidth: 1,
    borderRadius: 16,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  chipText: {
    fontSize: typeScale.caption,
    fontWeight: '600',
  },
  bulletRow: {
    flexDirection: 'row',
    gap: spacing.sm,
    paddingVertical: 2,
  },
  bullet: {
    fontSize: typeScale.body,
    lineHeight: 24,
  },
  stepNum: {
    fontSize: typeScale.body,
    fontWeight: '700',
    lineHeight: 24,
    minWidth: 22,
  },
  bulletText: {
    flex: 1,
  },
});
