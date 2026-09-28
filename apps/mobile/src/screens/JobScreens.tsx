/**
 * Job pages (GUI Master §9 / screens 27–32) — the per-job experience for a vacuum-truck driver:
 *
 *   27. Jobs List            — assigned / next / completed jobs with status + filter chips
 *   28. Job Overview         — the job command center (required flow + supporting actions + menu)
 *   29. Job Details          — the full job sheet, driver-facing fields only
 *   30. Job SOPs             — SOPs relevant to this job, grouped by relevance
 *   31. Emergency Info       — fast-access emergency contacts mapped from the JHA/JSA
 *   32. Stop Work / Report Concern — stop-work authority made visible + a concern report form
 *
 * All six screens are presentational and props-driven. They never touch the domain/runtime/data
 * layers and never render UUIDs, hashes, snapshots, sync internals, server versions, or hub URLs
 * (GUI Master §20). Realistic opshub sample fallbacks fill any absent prop so the screens always
 * render meaningful field content. Camera / GPS validation / print / directions are wired by the
 * host shell from this presentational surface.
 */
import { useState } from 'react';
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

/* ------------------------------------------------------------------ *
 * Shared status vocabulary (GUI Master §20). Only these labels appear.
 * ------------------------------------------------------------------ */

export type JobStatusLabel =
  | 'Not Started'
  | 'In Progress'
  | 'Required'
  | 'Locked'
  | 'Blocked'
  | 'Needs Review'
  | 'Saved on Phone'
  | 'Pending Sync'
  | 'Syncing'
  | 'Synced'
  | 'Submitted'
  | 'Complete';

const STATUS_TONE: Record<JobStatusLabel, Tone> = {
  'Not Started': 'neutral',
  'In Progress': 'info',
  Required: 'warning',
  Locked: 'neutral',
  Blocked: 'danger',
  'Needs Review': 'warning',
  'Saved on Phone': 'info',
  'Pending Sync': 'warning',
  Syncing: 'info',
  Synced: 'success',
  Submitted: 'success',
  Complete: 'success',
};

function statusTone(label: JobStatusLabel): Tone {
  return STATUS_TONE[label] ?? 'neutral';
}

/* ================================================================== *
 * 27. Jobs List
 * ================================================================== */

export type JobsFilter =
  | 'all'
  | 'not-started'
  | 'in-progress'
  | 'blocked'
  | 'completed'
  | 'pending-sync';

const JOBS_FILTERS: readonly { key: JobsFilter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'not-started', label: 'Not Started' },
  { key: 'in-progress', label: 'In Progress' },
  { key: 'blocked', label: 'Blocked' },
  { key: 'completed', label: 'Completed' },
  { key: 'pending-sync', label: 'Pending Sync' },
];

export type JobGroup = 'current' | 'next' | 'completed';

export interface JobListItem {
  /** Driver-facing service-record number, e.g. "2026-000001". Never a UUID. */
  serviceRecord: string;
  customer: string;
  lease: string;
  well: string;
  jobType: string;
  group: JobGroup;
  jhaStatus: JobStatusLabel;
  ticketStatus: JobStatusLabel;
  syncStatus: JobStatusLabel;
  /** The job's primary verb. */
  primaryLabel: 'Start Job' | 'Continue Job' | 'Review Job';
}

const SAMPLE_JOBS: JobListItem[] = [
  {
    serviceRecord: '2026-000001',
    customer: 'Acme Energy, LLC',
    lease: 'Northfield Lease',
    well: 'Northfield 06H',
    jobType: 'Produced Water Haul',
    group: 'current',
    jhaStatus: 'Not Started',
    ticketStatus: 'Locked',
    syncStatus: 'Saved on Phone',
    primaryLabel: 'Continue Job',
  },
  {
    serviceRecord: '2026-000002',
    customer: 'Acme Energy, LLC',
    lease: 'Northfield Lease',
    well: 'Northfield 114H',
    jobType: 'Produced Water Haul',
    group: 'next',
    jhaStatus: 'Not Started',
    ticketStatus: 'Locked',
    syncStatus: 'Saved on Phone',
    primaryLabel: 'Start Job',
  },
  {
    serviceRecord: '2026-000000',
    customer: 'Acme Energy, LLC',
    lease: 'Northfield Lease',
    well: 'Northfield 114H',
    jobType: 'Produced Water Haul',
    group: 'completed',
    jhaStatus: 'Complete',
    ticketStatus: 'Submitted',
    syncStatus: 'Synced',
    primaryLabel: 'Review Job',
  },
];

const GROUP_TITLE: Record<JobGroup, string> = {
  current: 'Current Job',
  next: 'Next Jobs',
  completed: 'Completed Jobs',
};

const GROUP_ORDER: readonly JobGroup[] = ['current', 'next', 'completed'];

/** Decide whether a job matches the active filter. */
function jobMatchesFilter(job: JobListItem, filter: JobsFilter): boolean {
  switch (filter) {
    case 'all':
      return true;
    case 'not-started':
      return job.jhaStatus === 'Not Started';
    case 'in-progress':
      return job.jhaStatus === 'In Progress' || job.ticketStatus === 'In Progress';
    case 'blocked':
      return job.jhaStatus === 'Blocked' || job.ticketStatus === 'Blocked';
    case 'completed':
      return job.group === 'completed';
    case 'pending-sync':
      return job.syncStatus === 'Pending Sync' || job.syncStatus === 'Saved on Phone';
    default:
      return true;
  }
}

export function JobsListScreen(props: {
  jobs?: JobListItem[];
  onOpenJob?: (serviceRecord: string) => void;
  onRefresh?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const jobs = props.jobs ?? SAMPLE_JOBS;
  const [filter, setFilter] = useState<JobsFilter>('all');

  const visible = jobs.filter((j) => jobMatchesFilter(j, filter));

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Jobs</Text>

      <View style={styles.filters}>
        {JOBS_FILTERS.map((f) => {
          const selected = f.key === filter;
          return (
            <Pressable
              key={f.key}
              testID={`jobs-filter-${f.key}`}
              onPress={() => setFilter(f.key)}
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

      {visible.length === 0 ? (
        <Card theme={t} title="No jobs match this filter">
          <Text style={[styles.body2, { color: t.textMuted }]}>
            Try the “All” filter, or pull in the latest from the Hub.
          </Text>
          <Button
            theme={t}
            variant="secondary"
            label="Refresh from Hub"
            onPress={() => props.onRefresh?.()}
            testID="jobs-refresh"
          />
        </Card>
      ) : (
        GROUP_ORDER.map((group) => {
          const groupJobs = visible.filter((j) => j.group === group);
          if (groupJobs.length === 0) return null;
          return (
            <View key={group} style={styles.section}>
              <Text style={[styles.h2, { color: t.text }]}>{GROUP_TITLE[group]}</Text>
              {groupJobs.map((job) => (
                <JobCard
                  key={job.serviceRecord}
                  job={job}
                  theme={t}
                  {...(props.onOpenJob !== undefined ? { onOpen: props.onOpenJob } : {})}
                />
              ))}
            </View>
          );
        })
      )}
    </View>
  );
}

function JobCard(props: { job: JobListItem; onOpen?: (sr: string) => void; theme: Theme }) {
  const t = props.theme;
  const job = props.job;
  return (
    <Card theme={t} testID={`job-card-${job.serviceRecord}`}>
      <Text style={[styles.srLine, { color: t.textMuted }]}>SR {job.serviceRecord}</Text>
      <Text style={[styles.cardTitle, { color: t.text }]}>{job.customer}</Text>
      <Text style={[styles.body2, { color: t.text }]}>{job.lease}</Text>
      <Text style={[styles.body2, { color: t.text }]}>{job.well}</Text>
      <Text style={[styles.jobType, { color: t.textMuted }]}>{job.jobType}</Text>

      <View style={styles.statusGrid}>
        <StatusRow label="JHA/JSA" value={job.jhaStatus} theme={t} />
        <StatusRow label="Field Ticket" value={job.ticketStatus} theme={t} />
        <StatusRow label="Sync" value={job.syncStatus} theme={t} />
      </View>

      <Button
        theme={t}
        label={job.primaryLabel}
        onPress={() => props.onOpen?.(job.serviceRecord)}
        testID={`job-open-${job.serviceRecord}`}
      />
    </Card>
  );
}

function StatusRow(props: { label: string; value: JobStatusLabel; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.statusRow}>
      <Text style={[styles.statusKey, { color: t.textMuted }]}>{props.label}</Text>
      <StatusBadge label={props.value} tone={statusTone(props.value)} />
    </View>
  );
}

/* ================================================================== *
 * 28. Job Overview — the job command center
 * ================================================================== */

export interface JobIdentity {
  serviceRecord: string;
  customer: string;
  lease: string;
  well: string;
  jobType: string;
  truck: string;
  trailer: string;
  destination: string;
}

const SAMPLE_IDENTITY: JobIdentity = {
  serviceRecord: '2026-000001',
  customer: 'Acme Energy, LLC',
  lease: 'Northfield Lease',
  well: 'Northfield 06H',
  jobType: 'Produced Water Haul',
  truck: 'Truck 7',
  trailer: 'Vacuum Trailer 19',
  destination: 'Falcon SWD #2',
};

export type JobFlowState = 'complete' | 'current' | 'locked';

export interface JobFlowStep {
  key: string;
  label: string;
  state: JobFlowState;
}

const FLOW_BADGE: Record<JobFlowState, { label: JobStatusLabel; tone: Tone }> = {
  complete: { label: 'Complete', tone: 'success' },
  current: { label: 'Required', tone: 'warning' },
  locked: { label: 'Locked', tone: 'neutral' },
};

const SAMPLE_FLOW: JobFlowStep[] = [
  { key: 'sops', label: 'Review Job SOPs', state: 'current' },
  { key: 'jha', label: 'Complete JHA/JSA', state: 'locked' },
  { key: 'ticket', label: 'Complete Field Ticket', state: 'locked' },
];

/** Job menu rows (the overflow menu). Each maps to a callback the host wires up. */
export type JobMenuKey =
  | 'details'
  | 'sops'
  | 'emergency'
  | 'directions'
  | 'dispatch'
  | 'evidence'
  | 'print'
  | 'stop-work';

const JOB_MENU: readonly { key: JobMenuKey; label: string; danger?: boolean }[] = [
  { key: 'details', label: 'Job Details' },
  { key: 'sops', label: 'Job SOPs' },
  { key: 'emergency', label: 'Emergency Info' },
  { key: 'directions', label: 'Directions' },
  { key: 'dispatch', label: 'Contact Dispatch' },
  { key: 'print', label: 'Print' },
  { key: 'stop-work', label: 'Stop Work / Report Concern', danger: true },
];

export function JobOverviewScreen(props: {
  job?: JobIdentity;
  flow?: JobFlowStep[];
  /** Driver-facing label for the single biggest next action. */
  primaryLabel?: 'Start JHA/JSA' | 'Start Field Ticket' | 'Review Job';
  onPrimary?: () => void;
  onStartWork?: () => void | Promise<void>;
  workStartStatus?: { label: string; tone: Tone };
  onAddEvidence?: () => void;
  onCaptureGps?: () => void;
  onAddReceipt?: () => void;
  onPrintTicket?: () => void;
  onEmergencyInfo?: () => void;
  onStopWork?: () => void;
  onMenu?: (key: JobMenuKey) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const job = props.job ?? SAMPLE_IDENTITY;
  const flow = props.flow ?? SAMPLE_FLOW;
  const primaryLabel = props.primaryLabel ?? 'Start JHA/JSA';

  // Supporting actions navigate to their real panels (Evidence / Receipt / Print); they are no
  // longer local-counter stubs. GPS is captured automatically in the background, not on a button.
  const [activeMenu, setActiveMenu] = useState<JobMenuKey | null>(null);

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Job Overview</Text>

      <Card theme={t} testID="job-overview-identity">
        <Text style={[styles.srLine, { color: t.textMuted }]}>SR {job.serviceRecord}</Text>
        <Text style={[styles.cardTitle, { color: t.text }]}>{job.customer}</Text>
        <Text style={[styles.body2, { color: t.text }]}>{job.lease}</Text>
        <Text style={[styles.body2, { color: t.text }]}>{job.well}</Text>
        <Text style={[styles.jobType, { color: t.textMuted }]}>{job.jobType}</Text>
        <View style={styles.divider} />
        <Text style={[styles.body2, { color: t.text }]}>
          {job.truck} · {job.trailer}
        </Text>
        <Text style={[styles.body2, { color: t.text }]}>Destination: {job.destination}</Text>
      </Card>

      <Card theme={t} tone="highlight" title="Required job flow" testID="job-flow">
        {flow.map((step, i) => (
          <View key={step.key} style={styles.flowRow} testID={`job-flow-${step.key}`}>
            <Text style={[styles.flowNum, { color: t.textMuted }]}>{i + 1}.</Text>
            <Text style={[styles.flowLabel, { color: t.text }]}>{step.label}</Text>
            <StatusBadge label={FLOW_BADGE[step.state].label} tone={FLOW_BADGE[step.state].tone} />
          </View>
        ))}
        <Button
          theme={t}
          label={primaryLabel}
          onPress={() => props.onPrimary?.()}
          testID="job-primary"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Start Work"
          onPress={() => props.onStartWork?.()}
          disabled={props.onStartWork === undefined}
          testID="job-start-work"
        />
        {props.workStartStatus !== undefined ? (
          <StatusBadge
            label={props.workStartStatus.label}
            tone={props.workStartStatus.tone}
            testID="job-work-start-status"
          />
        ) : null}
      </Card>

      <Card theme={t} title="Supporting actions">
        <Button
          theme={t}
          variant="secondary"
          label="Add Evidence"
          onPress={() => props.onAddEvidence?.()}
          testID="job-add-evidence"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Add Receipt"
          onPress={() => props.onAddReceipt?.()}
          testID="job-add-receipt"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Print Ticket"
          onPress={() => props.onPrintTicket?.()}
          testID="job-print-ticket"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Emergency Info"
          onPress={() => props.onEmergencyInfo?.()}
          testID="job-emergency-info"
        />
        <Button
          theme={t}
          variant="destructive"
          label="Stop Work / Report Concern"
          onPress={() => props.onStopWork?.()}
          testID="job-stop-work"
        />
        <Text style={[styles.meta, { color: t.textMuted }]} testID="job-gps-auto">
          GPS validation is captured from the Location panel when required.
        </Text>
      </Card>

      <Card theme={t} title="Job menu">
        {JOB_MENU.map((row) => {
          const active = row.key === activeMenu;
          return (
            <Pressable
              key={row.key}
              testID={`job-menu-${row.key}`}
              onPress={() => {
                setActiveMenu(row.key);
                props.onMenu?.(row.key);
              }}
              accessibilityRole="button"
              accessibilityState={{ selected: active }}
              accessibilityLabel={row.label}
              style={({ pressed }) => [
                styles.menuRow,
                { borderColor: active ? t.primary : t.border },
                active ? { backgroundColor: t.cardMuted } : null,
                pressed ? styles.menuRowPressed : null,
              ]}
            >
              <Text style={[styles.menuLabel, { color: row.danger === true ? t.danger : t.text }]}>
                {row.label}
              </Text>
              <Text style={[styles.menuChevron, { color: t.textMuted }]}>›</Text>
            </Pressable>
          );
        })}
      </Card>
    </View>
  );
}

/* ================================================================== *
 * 29. Job Details — full job sheet, driver-facing fields only
 * ================================================================== */

export interface JobDetails {
  serviceRecord: string;
  customer: string;
  lease: string;
  well: string;
  county: string;
  material: string;
  jobType: string;
  truck: string;
  trailer: string;
  driver: string;
  destination: string;
  orderedBy: string;
  dispatchNotes: string;
  customerNotes: string;
}

const SAMPLE_DETAILS: JobDetails = {
  serviceRecord: '2026-000001',
  customer: 'Acme Energy, LLC',
  lease: 'Northfield Lease',
  well: 'Northfield 06H',
  county: 'Reeves County, TX',
  material: 'Produced Water',
  jobType: 'Produced Water Haul',
  truck: 'Truck 7',
  trailer: 'Vacuum Trailer 19',
  driver: 'You',
  destination: 'Falcon SWD #2',
  orderedBy: 'Dispatch — Acme Oilfield',
  dispatchNotes: 'Load at the Northfield 06H tank battery. Gate code on the Emergency Info screen.',
  customerNotes: 'Check in with the company man before backing to the tanks.',
};

export function JobDetailsScreen(props: { details?: JobDetails; theme?: Theme }) {
  const t = useResolvedTheme(props.theme);
  const d = props.details ?? SAMPLE_DETAILS;

  const rows: { label: string; value: string }[] = [
    { label: 'Service Record', value: `SR ${d.serviceRecord}` },
    { label: 'Customer', value: d.customer },
    { label: 'Lease', value: d.lease },
    { label: 'Well', value: d.well },
    { label: 'County', value: d.county },
    { label: 'Material', value: d.material },
    { label: 'Job Type', value: d.jobType },
    { label: 'Truck', value: d.truck },
    { label: 'Trailer', value: d.trailer },
    { label: 'Driver', value: d.driver },
    { label: 'Destination / SWD', value: d.destination },
    { label: 'Ordered By', value: d.orderedBy },
  ];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Job Details</Text>

      <Card theme={t} title="Job information">
        {rows.map((r) => (
          <DetailRow key={r.label} label={r.label} value={r.value} theme={t} />
        ))}
      </Card>

      <Card theme={t} title="Dispatch Notes">
        <Text style={[styles.body2, { color: t.text }]}>{d.dispatchNotes}</Text>
      </Card>

      <Card theme={t} title="Customer Notes">
        <Text style={[styles.body2, { color: t.text }]}>{d.customerNotes}</Text>
      </Card>
    </View>
  );
}

function DetailRow(props: { label: string; value: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.detailRow} testID={`detail-${props.label}`}>
      <Text style={[styles.detailKey, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.detailValue, { color: t.text }]}>{props.value}</Text>
    </View>
  );
}

/* ================================================================== *
 * 30. Job SOPs — SOPs relevant to this job
 * ================================================================== */

export type SopSection = 'required' | 'recommended' | 'emergency' | 'site-rules';

export type SopAckStatus = 'Acknowledged' | 'Review Required' | 'Not Started';

export interface JobSopItem {
  key: string;
  title: string;
  role: string;
  availableOffline: boolean;
  status: SopAckStatus;
  section: SopSection;
}

const SOP_SECTION_TITLE: Record<SopSection, string> = {
  required: 'Required Before Work',
  recommended: 'Recommended for This Job',
  emergency: 'Emergency SOPs',
  'site-rules': 'Customer / Site Rules',
};

const SOP_SECTION_ORDER: readonly SopSection[] = [
  'required',
  'recommended',
  'emergency',
  'site-rules',
];

const SOP_ACK_TONE: Record<SopAckStatus, Tone> = {
  Acknowledged: 'success',
  'Review Required': 'warning',
  'Not Started': 'neutral',
};

const SAMPLE_SOPS: JobSopItem[] = [
  {
    key: 'loading',
    title: 'Vacuum Truck Loading and Unloading',
    role: 'Driver Role',
    availableOffline: true,
    status: 'Review Required',
    section: 'required',
  },
  {
    key: 'h2s',
    title: 'H2S Awareness and Response',
    role: 'Driver Role',
    availableOffline: true,
    status: 'Acknowledged',
    section: 'required',
  },
  {
    key: 'backing',
    title: 'Safe Backing and Spotting',
    role: 'Driver Role',
    availableOffline: true,
    status: 'Acknowledged',
    section: 'recommended',
  },
  {
    key: 'spill',
    title: 'Spill Response and Containment',
    role: 'Driver Role',
    availableOffline: true,
    status: 'Acknowledged',
    section: 'emergency',
  },
  {
    key: 'site',
    title: 'Acme Energy Site Access Rules',
    role: 'Site Rule',
    availableOffline: true,
    status: 'Review Required',
    section: 'site-rules',
  },
];

export function JobSopsScreen(props: {
  sops?: JobSopItem[];
  onOpenSop?: (key: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sops = props.sops ?? SAMPLE_SOPS;

  // Track which SOPs the driver has opened on this phone so a tap visibly flips
  // the status to "Acknowledged" even when no host callback is wired up.
  const [opened, setOpened] = useState<Record<string, boolean>>({});

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Job SOPs</Text>

      {SOP_SECTION_ORDER.map((section) => {
        const items = sops.filter((s) => s.section === section);
        if (items.length === 0) return null;
        return (
          <View key={section} style={styles.section}>
            <Text style={[styles.h2, { color: t.text }]}>{SOP_SECTION_TITLE[section]}</Text>
            {items.map((sop) => {
              const isOpened = opened[sop.key] === true;
              const status: SopAckStatus = isOpened ? 'Acknowledged' : sop.status;
              const reviewNeeded = status === 'Review Required';
              return (
                <Card theme={t} key={sop.key} testID={`sop-${sop.key}`}>
                  <Text style={[styles.cardTitle, { color: t.text }]}>{sop.title}</Text>
                  <Text style={[styles.jobType, { color: t.textMuted }]}>{sop.role}</Text>
                  {sop.availableOffline ? (
                    <Text style={[styles.meta, { color: t.textMuted }]}>Available Offline</Text>
                  ) : null}
                  <View style={styles.row}>
                    <Text style={[styles.statusKey, { color: t.textMuted }]}>Status</Text>
                    <StatusBadge label={status} tone={SOP_ACK_TONE[status]} />
                  </View>
                  <Button
                    theme={t}
                    variant={reviewNeeded ? 'primary' : 'secondary'}
                    label={reviewNeeded ? 'Review Required' : isOpened ? 'Opened' : 'Open SOP'}
                    onPress={() => {
                      setOpened((prev) => ({ ...prev, [sop.key]: true }));
                      props.onOpenSop?.(sop.key);
                    }}
                    testID={`sop-open-${sop.key}`}
                  />
                </Card>
              );
            })}
          </View>
        );
      })}
    </View>
  );
}

/* ================================================================== *
 * 31. Emergency Info — fast-access emergency details (maps to JHA/JSA)
 * ================================================================== */

export interface EmergencyInfo {
  emergencyContact: string;
  siteContact: string;
  customerSafetyContact: string;
  nearestHospital: string;
  musterPoint: string;
  spillResponseContact: string;
  h2sEmergencyContact: string;
  access911: string;
  gateCodes: string;
}

const SAMPLE_EMERGENCY: EmergencyInfo = {
  emergencyContact: 'Acme Oilfield Dispatch · (432) 555-0142',
  siteContact: 'Company Man — Northfield 06H · (432) 555-0188',
  customerSafetyContact: 'Acme Energy HSE · (432) 555-0107',
  nearestHospital: 'Pecos Valley Medical Center · 14 mi NE',
  musterPoint: 'North gate, by the lease entrance sign',
  spillResponseContact: 'Field Spill Response · (432) 555-0150',
  h2sEmergencyContact: 'Site H2S Safety · (432) 555-0199',
  access911: 'Give lease name “Northfield 06H” and the gate GPS to the 911 operator.',
  gateCodes: 'Main gate code 4417. Follow the caliche lease road 1.2 mi to the tank battery.',
};

export function EmergencyInfoScreen(props: {
  info?: EmergencyInfo;
  onCallEmergencyContact?: () => void;
  onCallDispatch?: () => void;
  onOpenDirections?: () => void;
  onViewEmergencySops?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const info = props.info ?? SAMPLE_EMERGENCY;

  // Inline confirmation for the placeholder actions (dialing / maps are wired
  // elsewhere) so each button gives visible feedback instead of a silent no-op.
  const [actionNote, setActionNote] = useState<string | null>(null);

  const rows: { label: string; value: string }[] = [
    { label: 'Emergency Contact', value: info.emergencyContact },
    { label: 'Site Contact / Company Man', value: info.siteContact },
    { label: 'Customer Safety Contact', value: info.customerSafetyContact },
    { label: 'Nearest Hospital / Clinic', value: info.nearestHospital },
    { label: 'Muster Point', value: info.musterPoint },
    { label: 'Spill Response Contact', value: info.spillResponseContact },
    { label: 'H2S Emergency Contact', value: info.h2sEmergencyContact },
    { label: '911 Access Instructions', value: info.access911 },
    { label: 'Gate Codes / Lease Road Directions', value: info.gateCodes },
  ];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Emergency Info</Text>

      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          In an emergency, stop work and make the area safe first, then use these contacts. This
          information comes from the job’s JHA/JSA emergency section.
        </Text>
      </Card>

      <Card theme={t} title="Emergency details">
        {rows.map((r) => (
          <DetailRow key={r.label} label={r.label} value={r.value} theme={t} />
        ))}
      </Card>

      <Card theme={t} title="Actions">
        <Button
          theme={t}
          label="Call Emergency Contact"
          onPress={() => {
            setActionNote('Calling emergency contact…');
            props.onCallEmergencyContact?.();
          }}
          testID="emergency-call-contact"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Call Dispatch"
          onPress={() => {
            setActionNote('Calling dispatch…');
            props.onCallDispatch?.();
          }}
          testID="emergency-call-dispatch"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Open Directions"
          onPress={() => {
            setActionNote('Opening directions…');
            props.onOpenDirections?.();
          }}
          testID="emergency-directions"
        />
        <Button
          theme={t}
          variant="secondary"
          label="View Emergency SOPs"
          onPress={() => {
            setActionNote('Opening emergency SOPs…');
            props.onViewEmergencySops?.();
          }}
          testID="emergency-sops"
        />
        {actionNote !== null ? (
          <Text style={[styles.meta, { color: t.info }]} testID="emergency-action-status">
            {actionNote}
          </Text>
        ) : null}
      </Card>
    </View>
  );
}

/* ================================================================== *
 * 32. Stop Work / Report Concern — stop-work authority made visible
 * ================================================================== */

export type StopWorkTrigger =
  | 'H2S Alarm'
  | 'Uncontrolled Leak or Spill'
  | 'Fire'
  | 'Lightning'
  | 'Heat Illness Symptoms'
  | 'Failed Equipment'
  | 'Unsafe Road Condition'
  | 'Missing PPE'
  | 'Unsafe Backing Condition'
  | 'Worker Concern'
  | 'Other';

const STOP_WORK_TRIGGERS: readonly StopWorkTrigger[] = [
  'H2S Alarm',
  'Uncontrolled Leak or Spill',
  'Fire',
  'Lightning',
  'Heat Illness Symptoms',
  'Failed Equipment',
  'Unsafe Road Condition',
  'Missing PPE',
  'Unsafe Backing Condition',
  'Worker Concern',
  'Other',
];

export function StopWorkScreen(props: {
  triggers?: readonly StopWorkTrigger[];
  /** Whether a GPS fix has already been captured for this report. */
  gpsCaptured?: boolean;
  gpsLabel?: string;
  /** Number of photos already attached to this report. */
  photoCount?: number;
  onAddPhoto?: () => void;
  onCaptureGps?: () => void;
  onReportConcern?: (report: {
    trigger: StopWorkTrigger;
    description: string;
    notifyDispatch: boolean;
  }) => void;
  onCallEmergencyContact?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const triggers = props.triggers ?? STOP_WORK_TRIGGERS;

  const [selected, setSelected] = useState<StopWorkTrigger | null>(null);
  const [description, setDescription] = useState('');
  const [notifyDispatch, setNotifyDispatch] = useState(true);
  // Self-managing evidence/GPS seeded from the optional props so taps visibly respond.
  const [gpsCaptured, setGpsCaptured] = useState(props.gpsCaptured ?? false);
  const [photoCount, setPhotoCount] = useState(props.photoCount ?? 0);
  const [emergencyNote, setEmergencyNote] = useState(false);

  const canReport = selected !== null;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Stop Work / Report Concern</Text>

      <Card theme={t} tone="highlight">
        <Text style={[styles.cardTitle, { color: t.text }]}>You have stop-work authority.</Text>
        <Text style={[styles.body2, { color: t.text }]}>
          If a job is unsafe, stop work and make the area safe first. Then report the concern below.
          These triggers come from the job’s JHA/JSA stop-work section.
        </Text>
        <Button
          theme={t}
          variant="destructive"
          label="Call Emergency Contact"
          onPress={() => {
            setEmergencyNote(true);
            props.onCallEmergencyContact?.();
          }}
          testID="stopwork-call-emergency"
        />
        {emergencyNote ? (
          <Text style={[styles.meta, { color: t.danger }]} testID="stopwork-call-emergency-status">
            Calling emergency contact…
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Concern Type">
        <View style={styles.triggerWrap}>
          {triggers.map((trigger) => {
            const isSelected = trigger === selected;
            return (
              <Pressable
                key={trigger}
                testID={`stopwork-trigger-${trigger}`}
                onPress={() => setSelected(trigger)}
                accessibilityRole="button"
                accessibilityState={{ selected: isSelected }}
                accessibilityLabel={trigger}
                style={[
                  styles.triggerChip,
                  { borderColor: isSelected ? t.danger : t.border },
                  isSelected ? { backgroundColor: t.danger } : null,
                ]}
              >
                <Text style={[styles.triggerText, { color: isSelected ? t.onPrimary : t.text }]}>
                  {trigger}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </Card>

      <Card theme={t} title="Description">
        <TextInput
          testID="stopwork-description"
          value={description}
          onChangeText={setDescription}
          multiline
          placeholder="Describe what you saw and what you did to make it safe."
          placeholderTextColor={t.textMuted}
          style={[
            styles.textArea,
            { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
          ]}
        />
      </Card>

      <Card theme={t} title="Evidence">
        <View style={styles.previewFrame}>
          <Text style={[styles.previewText, { color: t.textMuted }]}>
            {photoCount === 0
              ? 'No photo added yet.'
              : `${photoCount} photo${photoCount === 1 ? '' : 's'} added.`}
          </Text>
        </View>
        <Button
          theme={t}
          variant="secondary"
          label="Add Photo"
          onPress={() => {
            setPhotoCount((n) => n + 1);
            props.onAddPhoto?.();
          }}
          testID="stopwork-add-photo"
        />
        <View style={styles.row}>
          <Text style={[styles.statusKey, { color: t.textMuted }]}>GPS Capture</Text>
          <StatusBadge
            label={gpsCaptured ? 'Synced' : 'Not Started'}
            tone={gpsCaptured ? 'success' : 'neutral'}
          />
        </View>
        {gpsCaptured ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>
            {props.gpsLabel ?? 'Location captured on this phone'}
          </Text>
        ) : null}
        <Button
          theme={t}
          variant="secondary"
          label={gpsCaptured ? 'Recapture GPS' : 'GPS Capture'}
          onPress={() => {
            setGpsCaptured(true);
            props.onCaptureGps?.();
          }}
          testID="stopwork-capture-gps"
        />
      </Card>

      <Card theme={t} title="Notify Dispatch">
        <Pressable
          testID="stopwork-notify-toggle"
          onPress={() => setNotifyDispatch((v) => !v)}
          accessibilityRole="switch"
          accessibilityState={{ checked: notifyDispatch }}
          accessibilityLabel="Notify Dispatch"
          style={[styles.toggleRow, { borderColor: t.border }]}
        >
          <Text style={[styles.body2, { color: t.text }]}>Notify Dispatch right away</Text>
          <StatusBadge
            label={notifyDispatch ? 'In Progress' : 'Not Started'}
            tone={notifyDispatch ? 'info' : 'neutral'}
          />
        </Pressable>
      </Card>

      <Button
        theme={t}
        variant="destructive"
        label="Report Concern"
        disabled={!canReport}
        onPress={() => {
          if (selected === null) return;
          props.onReportConcern?.({ trigger: selected, description, notifyDispatch });
        }}
        testID="stopwork-report"
      />
      {!canReport ? (
        <Text style={[styles.meta, { color: t.textMuted }]}>Pick a concern type to report.</Text>
      ) : null}
    </View>
  );
}

/* ------------------------------------------------------------------ *
 * Styles
 * ------------------------------------------------------------------ */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  section: {
    gap: spacing.sm,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  h2: {
    fontSize: typeScale.heading,
    fontWeight: '700',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  meta: {
    fontSize: typeScale.label,
  },
  srLine: {
    fontSize: typeScale.label,
    fontWeight: '600',
    letterSpacing: 0.5,
  },
  cardTitle: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  jobType: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  divider: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: '#0000001A',
    marginVertical: spacing.xs,
  },
  // Filter / select chips — large, obvious tap targets for gloved thumbs (>=48px).
  filters: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  chip: {
    minHeight: 48,
    borderWidth: 1,
    borderRadius: 24,
    paddingHorizontal: 16,
    justifyContent: 'center',
  },
  chipText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  // Job-card status block
  statusGrid: {
    gap: spacing.xs,
    paddingVertical: spacing.xs,
  },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  statusKey: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  // Required flow rows
  flowRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingVertical: 6,
  },
  flowNum: {
    fontSize: typeScale.body,
    fontWeight: '700',
    width: 22,
  },
  flowLabel: {
    flex: 1,
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  // Job menu
  menuRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 48,
    paddingHorizontal: spacing.sm,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 8,
  },
  menuRowPressed: {
    opacity: 0.7,
  },
  menuLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  menuChevron: {
    fontSize: typeScale.heading,
    fontWeight: '700',
  },
  // Detail rows
  detailRow: {
    paddingVertical: 6,
    gap: 2,
  },
  detailKey: {
    fontSize: typeScale.caption,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
  },
  detailValue: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  // Stop-work triggers
  triggerWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  triggerChip: {
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 12,
    minHeight: 48,
    justifyContent: 'center',
  },
  triggerText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  textArea: {
    minHeight: 96,
    borderWidth: 1,
    borderRadius: 8,
    padding: spacing.sm,
    fontSize: typeScale.body,
    textAlignVertical: 'top',
  },
  previewFrame: {
    minHeight: 96,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: '#0000002A',
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.md,
  },
  previewText: {
    fontSize: typeScale.label,
  },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 48,
    paddingHorizontal: spacing.sm,
    borderWidth: 1,
    borderRadius: 8,
  },
});
