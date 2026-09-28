/**
 * Admin / Protected & non-driver pages (GUI Master §16 / screens 84–92).
 *
 * These are the ONLY screens permitted to surface technical detail, and only AFTER the Admin lock
 * (screen 84) is unlocked. Diagnostics are for supervisors and support, never the everyday driver.
 *
 * Even here we keep driver-facing hygiene: we never render UUIDs, hashes, raw payloads, queue/ack
 * internals, JSON, or storage-engine internals as free-form text in driver flows. The few "technical"
 * fields that this section is allowed to show (env name, hub URL, app version, build, storage engine,
 * device id, last sync — screen 88) are rendered as plain labelled rows, supplied by the host as
 * already-formatted display strings. This file is purely presentational: it imports only the design
 * kit + react-native primitives and drives everything from local prop interfaces + callbacks.
 *
 * Screens:
 *   84 AdminModeLockScreen            85 AdminDashboardScreen        86 PrinterDiagnosticsScreen
 *   87 SyncDiagnosticsScreen          88 EnvironmentDetailsScreen    89 LogsExportScreen
 *   90 SupervisorDefectReviewScreen   91 MechanicDefectResolutionScreen
 *   92 SupervisorOverrideScreen
 */
import { useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import {
  Button,
  Card,
  StatusBadge,
  sizing,
  spacing,
  typeScale,
  useResolvedTheme,
  type Theme,
  type Tone,
} from '../design';

/* ------------------------------------------------------------------------------------------------ *
 * Shared status vocabulary (GUI Master §20). Only these labels may appear as statuses.
 * ------------------------------------------------------------------------------------------------ */

type StatusLabel =
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
  | 'Complete'
  | 'Failed'
  | 'Offline Mode'
  | 'Punched In'
  | 'Punched Out';

const STATUS_TONE: Record<StatusLabel, Tone> = {
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
  Failed: 'danger',
  'Offline Mode': 'warning',
  'Punched In': 'success',
  'Punched Out': 'neutral',
};

/* ------------------------------------------------------------------------------------------------ *
 * Small local building blocks (presentational only).
 * ------------------------------------------------------------------------------------------------ */

/** A labelled key/value row for diagnostics + environment detail. Value is a display string. */
function DetailRow(props: { label: string; value: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.detailRow}>
      <Text style={[styles.detailLabel, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.detailValue, { color: t.text }]} numberOfLines={2}>
        {props.value}
      </Text>
    </View>
  );
}

/** Section header inside a screen body. */
function ScreenTitle(props: { title: string; subtitle?: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.titleBlock}>
      <Text style={[styles.h1, { color: t.text }]}>{props.title}</Text>
      {props.subtitle !== undefined ? (
        <Text style={[styles.subtitle, { color: t.textMuted }]}>{props.subtitle}</Text>
      ) : null}
    </View>
  );
}

/** A simple inline confirm row used for destructive actions (no native Modal dep). */
function ConfirmInline(props: {
  prompt: string;
  confirmLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
  theme: Theme;
}) {
  const t = props.theme;
  return (
    <View style={[styles.confirmBox, { borderColor: t.danger, backgroundColor: t.highlight }]}>
      <Text style={[styles.body2, { color: t.text }]}>{props.prompt}</Text>
      <Button
        theme={t}
        variant="destructive"
        label={props.confirmLabel}
        onPress={props.onConfirm}
      />
      <Button theme={t} variant="secondary" label="Cancel" onPress={props.onCancel} />
    </View>
  );
}

/** A bordered placeholder frame (signature pad / capture area). Real capture is wired elsewhere. */
function PlaceholderFrame(props: { caption: string; captured: boolean; theme: Theme }) {
  const t = props.theme;
  return (
    <View
      style={[
        styles.frame,
        { borderColor: props.captured ? t.success : t.border, backgroundColor: t.cardMuted },
      ]}
      accessibilityRole="image"
      accessibilityLabel={props.caption}
    >
      <Text style={[styles.frameText, { color: props.captured ? t.success : t.textMuted }]}>
        {props.captured ? 'Signature captured' : props.caption}
      </Text>
    </View>
  );
}

/* ================================================================================================ *
 * 84. Admin Mode Lock
 * ================================================================================================ */

export function AdminModeLockScreen(props: {
  /** Set when a previous unlock attempt was wrong, so we can show driver-safe guidance. */
  errorMessage?: string;
  pending?: boolean;
  onUnlock: (pin: string) => void;
  onCancel: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [pin, setPin] = useState('');
  const canSubmit = pin.trim().length >= 4 && props.pending !== true;

  return (
    <View style={styles.body}>
      <ScreenTitle theme={t} title="Admin Mode" />
      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          Diagnostics are for supervisors and support only.
        </Text>
      </Card>

      <Card theme={t} title="Admin PIN">
        <TextInput
          testID="admin-pin"
          value={pin}
          onChangeText={setPin}
          style={[styles.input, { borderColor: t.border, color: t.text }]}
          placeholder="Enter Admin PIN"
          placeholderTextColor={t.textMuted}
          keyboardType="number-pad"
          secureTextEntry
          accessibilityLabel="Admin PIN"
        />
        {props.errorMessage !== undefined ? (
          <Text style={[styles.errorText, { color: t.danger }]}>{props.errorMessage}</Text>
        ) : null}
        <Button
          theme={t}
          label={props.pending === true ? 'Checking…' : 'Unlock Admin Mode'}
          onPress={() => props.onUnlock(pin.trim())}
          disabled={!canSubmit}
          testID="admin-unlock"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Cancel"
          onPress={props.onCancel}
          testID="admin-cancel"
        />
      </Card>
    </View>
  );
}

/* ================================================================================================ *
 * 85. Admin Dashboard
 * ================================================================================================ */

export type AdminSectionKey =
  | 'environment'
  | 'device'
  | 'sync'
  | 'printer'
  | 'storage'
  | 'logs'
  | 'role';

export interface AdminSectionSummary {
  key: AdminSectionKey;
  /** Short summary line for the section (a display string supplied by the host). */
  detail: string;
  /** Optional status badge for the section. */
  status?: StatusLabel;
}

const ADMIN_SECTIONS: Record<AdminSectionKey, { title: string; nav: string }> = {
  environment: { title: 'Environment', nav: 'Open environment details' },
  device: { title: 'Device', nav: 'Open device info' },
  sync: { title: 'Sync Queue', nav: 'Open sync diagnostics' },
  printer: { title: 'Printer', nav: 'Open printer diagnostics' },
  storage: { title: 'Local Storage', nav: 'Open local storage' },
  logs: { title: 'Logs', nav: 'Open logs' },
  role: { title: 'User Role', nav: 'View role' },
};

const ADMIN_ORDER: readonly AdminSectionKey[] = [
  'environment',
  'device',
  'sync',
  'printer',
  'storage',
  'logs',
  'role',
];

export function AdminDashboardScreen(props: {
  sections?: AdminSectionSummary[];
  onOpenSection: (key: AdminSectionKey) => void;
  onLockAdmin: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const byKey = new Map<AdminSectionKey, AdminSectionSummary>(
    (props.sections ?? DEFAULT_ADMIN_SECTIONS).map((s) => [s.key, s]),
  );

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Admin Dashboard"
        subtitle="Technical details are visible because Admin Mode is unlocked."
      />
      {ADMIN_ORDER.map((key) => {
        const section = byKey.get(key);
        const meta = ADMIN_SECTIONS[key];
        const detail = section?.detail ?? '—';
        const status = section?.status;
        return (
          <Card theme={t} title={meta.title} key={key} testID={`admin-section-${key}`}>
            {status !== undefined ? (
              <StatusBadge label={status} tone={STATUS_TONE[status]} />
            ) : null}
            <Text style={[styles.body2, { color: t.text }]}>{detail}</Text>
            <Button
              theme={t}
              variant="secondary"
              label={meta.nav}
              onPress={() => props.onOpenSection(key)}
              testID={`admin-open-${key}`}
            />
          </Card>
        );
      })}

      <Button
        theme={t}
        variant="secondary"
        label="Lock Admin Mode"
        onPress={props.onLockAdmin}
        testID="admin-lock"
      />
    </View>
  );
}

const DEFAULT_ADMIN_SECTIONS: AdminSectionSummary[] = [
  { key: 'environment', detail: 'Production Hub · app up to date', status: 'Synced' },
  { key: 'device', detail: 'Truck 7 phone · battery healthy', status: 'In Progress' },
  { key: 'sync', detail: 'No items waiting to sync', status: 'Synced' },
  { key: 'printer', detail: 'Receipt printer connected', status: 'Complete' },
  { key: 'storage', detail: 'Plenty of space for offline work', status: 'Saved on Phone' },
  { key: 'logs', detail: 'Diagnostic logs available to export', status: 'Not Started' },
  { key: 'role', detail: 'Driver · Alex Ramirez', status: 'Punched In' },
];

/* ================================================================================================ *
 * 86. Printer Diagnostics
 * ================================================================================================ */

export type PrinterAction =
  | 'discover'
  | 'connect'
  | 'reconnect'
  | 'disconnect'
  | 'test-receipt'
  | 'status'
  | 'run-queue'
  | 'purge';

const PRINTER_ACTIONS: readonly { key: PrinterAction; label: string; destructive?: boolean }[] = [
  { key: 'discover', label: 'Discover Printer' },
  { key: 'connect', label: 'Connect' },
  { key: 'reconnect', label: 'Reconnect' },
  { key: 'disconnect', label: 'Disconnect' },
  { key: 'test-receipt', label: 'Test Receipt' },
  { key: 'status', label: 'Status' },
  { key: 'run-queue', label: 'Run Queue' },
  { key: 'purge', label: 'Purge Synced Print Jobs', destructive: true },
];

/** Plain-English feedback line for a tapped printer action (visible response, no real effect yet). */
const PRINTER_FEEDBACK: Record<PrinterAction, string> = {
  discover: 'Looking for nearby printers…',
  connect: 'Connecting to printer…',
  reconnect: 'Reconnecting to printer…',
  disconnect: 'Disconnected from printer',
  'test-receipt': 'Test receipt sent to printer',
  status: 'Checked printer status',
  'run-queue': 'Running print queue…',
  purge: 'Purged synced print jobs from this phone',
};

export function PrinterDiagnosticsScreen(props: {
  /** Connection status (driver-safe label). */
  connectionStatus?: StatusLabel;
  /** Friendly printer name, e.g. "Receipt printer · Truck 7". */
  printerName?: string;
  /** Plain-English last-result line for the most recent action. */
  lastResult?: string;
  /** Count of receipts waiting to print. */
  pendingPrintJobs?: number;
  busy?: boolean;
  onAction?: (action: PrinterAction) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [confirmPurge, setConfirmPurge] = useState(false);
  const [feedback, setFeedback] = useState<string | undefined>(undefined);
  const status = props.connectionStatus ?? 'Not Started';
  const name = props.printerName ?? 'Receipt printer · Truck 7';
  const pending = props.pendingPrintJobs ?? 0;

  const runAction = (action: PrinterAction) => {
    setFeedback(PRINTER_FEEDBACK[action]);
    props.onAction?.(action);
  };

  return (
    <View style={styles.body}>
      <ScreenTitle theme={t} title="Printer Diagnostics" />
      <Card theme={t} title={name}>
        <StatusBadge label={status} tone={STATUS_TONE[status]} testID="printer-status" />
        <Text style={[styles.body2, { color: t.text }]}>
          {pending === 0
            ? 'No receipts waiting to print.'
            : `${pending} receipt${pending === 1 ? '' : 's'} waiting to print.`}
        </Text>
        {props.lastResult !== undefined ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>{props.lastResult}</Text>
        ) : null}
        {feedback !== undefined ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="printer-feedback">
            {feedback}
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Actions">
        {PRINTER_ACTIONS.map((a) =>
          a.destructive === true ? null : (
            <Button
              theme={t}
              key={a.key}
              variant="secondary"
              label={a.label}
              disabled={props.busy === true}
              onPress={() => runAction(a.key)}
              testID={`printer-${a.key}`}
            />
          ),
        )}
      </Card>

      <Card theme={t} title="Maintenance">
        {confirmPurge ? (
          <ConfirmInline
            theme={t}
            prompt="Purge synced print jobs from this phone? Already-printed receipts stay in Ops Hub."
            confirmLabel="Purge Synced Print Jobs"
            onConfirm={() => {
              setConfirmPurge(false);
              runAction('purge');
            }}
            onCancel={() => setConfirmPurge(false)}
          />
        ) : (
          <Button
            theme={t}
            variant="destructive"
            label="Purge Synced Print Jobs"
            disabled={props.busy === true}
            onPress={() => setConfirmPurge(true)}
            testID="printer-purge"
          />
        )}
      </Card>
    </View>
  );
}

/* ================================================================================================ *
 * 87. Sync Diagnostics
 * ================================================================================================ */

export type SyncAction =
  | 'view-queue'
  | 'retry'
  | 'export-summary'
  | 'sync-ack'
  | 'purge-synced'
  | 'view-failed';

const SYNC_ACTIONS: readonly { key: SyncAction; label: string; destructive?: boolean }[] = [
  { key: 'view-queue', label: 'View Queue' },
  { key: 'retry', label: 'Retry Queue' },
  { key: 'export-summary', label: 'Export Queue Summary' },
  { key: 'sync-ack', label: 'Sync Ack' },
  { key: 'view-failed', label: 'View Failed Payload Summary' },
  { key: 'purge-synced', label: 'Purge Synced', destructive: true },
];

/** Plain-English feedback line for a tapped sync action (visible response, no real effect yet). */
const SYNC_FEEDBACK: Record<SyncAction, string> = {
  'view-queue': 'Opened the sync queue',
  retry: 'Retrying queued items…',
  'export-summary': 'Queue summary exported',
  'sync-ack': 'Sent acknowledgements…',
  'purge-synced': 'Purged synced items from this phone',
  'view-failed': 'Opened the failed payload summary',
};

export function SyncDiagnosticsScreen(props: {
  /** Counts shown as plain numbers — never raw payloads. */
  pending?: number;
  failed?: number;
  synced?: number;
  status?: StatusLabel;
  lastResult?: string;
  busy?: boolean;
  onAction?: (action: SyncAction) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [confirmPurge, setConfirmPurge] = useState(false);
  const [feedback, setFeedback] = useState<string | undefined>(undefined);
  const pending = props.pending ?? 0;
  const failed = props.failed ?? 0;
  const synced = props.synced ?? 0;
  const status = props.status ?? (failed > 0 ? 'Failed' : pending > 0 ? 'Pending Sync' : 'Synced');

  const runAction = (action: SyncAction) => {
    setFeedback(SYNC_FEEDBACK[action]);
    props.onAction?.(action);
  };

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Sync Diagnostics"
        subtitle="Summaries only — full sensitive payloads stay hidden unless support needs them."
      />
      <Card theme={t} title="Queue">
        <StatusBadge label={status} tone={STATUS_TONE[status]} testID="sync-status" />
        <DetailRow theme={t} label="Waiting to sync" value={String(pending)} />
        <DetailRow theme={t} label="Failed" value={String(failed)} />
        <DetailRow theme={t} label="Synced" value={String(synced)} />
        {props.lastResult !== undefined ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>{props.lastResult}</Text>
        ) : null}
        {feedback !== undefined ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="sync-feedback">
            {feedback}
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Actions">
        {SYNC_ACTIONS.map((a) =>
          a.destructive === true ? null : (
            <Button
              theme={t}
              key={a.key}
              variant="secondary"
              label={a.label}
              disabled={props.busy === true}
              onPress={() => runAction(a.key)}
              testID={`sync-${a.key}`}
            />
          ),
        )}
      </Card>

      <Card theme={t} title="Maintenance">
        {confirmPurge ? (
          <ConfirmInline
            theme={t}
            prompt="Purge synced items from this phone? Synced work is already saved in Ops Hub."
            confirmLabel="Purge Synced"
            onConfirm={() => {
              setConfirmPurge(false);
              runAction('purge-synced');
            }}
            onCancel={() => setConfirmPurge(false)}
          />
        ) : (
          <Button
            theme={t}
            variant="destructive"
            label="Purge Synced"
            disabled={props.busy === true}
            onPress={() => setConfirmPurge(true)}
            testID="sync-purge"
          />
        )}
      </Card>
    </View>
  );
}

/* ================================================================================================ *
 * 88. Environment Details
 * ================================================================================================ */

export interface EnvironmentInfo {
  /** All fields are pre-formatted display strings supplied by the host (never raw/unsafe values). */
  hubEnvironment: string;
  hubUrl: string;
  appVersion: string;
  build: string;
  storageEngine: string;
  deviceId: string;
  lastSync: string;
}

const DEFAULT_ENVIRONMENT: EnvironmentInfo = {
  hubEnvironment: 'Production',
  hubUrl: 'hub.example.com',
  appVersion: '1.0.0',
  build: '100',
  storageEngine: 'On-device secure store',
  deviceId: 'Truck 7 phone',
  lastSync: 'Today, 9:42 AM',
};

export function EnvironmentDetailsScreen(props: {
  environment?: EnvironmentInfo;
  onCopy?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const env = props.environment ?? DEFAULT_ENVIRONMENT;
  const [copied, setCopied] = useState(false);

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Environment Details"
        subtitle="Visible only in Admin Mode, for support."
      />
      <Card theme={t} title="Connection">
        <DetailRow theme={t} label="Hub Environment" value={env.hubEnvironment} />
        <DetailRow theme={t} label="Hub URL" value={env.hubUrl} />
        <DetailRow theme={t} label="Last Sync" value={env.lastSync} />
      </Card>
      <Card theme={t} title="App">
        <DetailRow theme={t} label="App Version" value={env.appVersion} />
        <DetailRow theme={t} label="Build" value={env.build} />
        <DetailRow theme={t} label="Storage Engine" value={env.storageEngine} />
      </Card>
      <Card theme={t} title="Device">
        <DetailRow theme={t} label="Device ID" value={env.deviceId} />
      </Card>
      <Button
        theme={t}
        variant="secondary"
        label="Copy for Support"
        onPress={() => {
          setCopied(true);
          props.onCopy?.();
        }}
        testID="env-copy"
      />
      {copied ? (
        <Text style={[styles.feedback, { color: t.success }]} testID="env-copy-feedback">
          Copied details for support
        </Text>
      ) : null}
    </View>
  );
}

/* ================================================================================================ *
 * 89. Logs / Export
 * ================================================================================================ */

export type LogAction = 'export' | 'send-support' | 'clear';

/** Plain-English feedback line for a tapped log action (visible response, no real effect yet). */
const LOG_FEEDBACK: Record<LogAction, string> = {
  export: 'Logs exported',
  'send-support': 'Sent to support',
  clear: 'Local logs cleared from this phone',
};

export function LogsExportScreen(props: {
  /** Count of log entries held on this phone (a plain number, no contents shown). */
  entryCount?: number;
  lastResult?: string;
  busy?: boolean;
  onAction?: (action: LogAction) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [confirmClear, setConfirmClear] = useState(false);
  const [feedback, setFeedback] = useState<string | undefined>(undefined);
  const count = props.entryCount ?? 0;

  const runAction = (action: LogAction) => {
    setFeedback(LOG_FEEDBACK[action]);
    props.onAction?.(action);
  };

  return (
    <View style={styles.body}>
      <ScreenTitle theme={t} title="Logs / Export" />
      <Card theme={t} title="Diagnostic logs">
        <Text style={[styles.body2, { color: t.text }]}>
          {count === 0
            ? 'No diagnostic logs are stored on this phone.'
            : `${count} diagnostic ${count === 1 ? 'entry is' : 'entries are'} stored on this phone.`}
        </Text>
        {props.lastResult !== undefined ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>{props.lastResult}</Text>
        ) : null}
        {feedback !== undefined ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="logs-feedback">
            {feedback}
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Actions">
        <Button
          theme={t}
          variant="secondary"
          label="Export Logs"
          disabled={props.busy === true}
          onPress={() => runAction('export')}
          testID="logs-export"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Send to Support"
          disabled={props.busy === true}
          onPress={() => runAction('send-support')}
          testID="logs-send"
        />
      </Card>

      <Card theme={t} title="Maintenance">
        {confirmClear ? (
          <ConfirmInline
            theme={t}
            prompt="Clear local logs from this phone? This cannot be undone. Export or send to support first if you may need them."
            confirmLabel="Clear Local Logs"
            onConfirm={() => {
              setConfirmClear(false);
              runAction('clear');
            }}
            onCancel={() => setConfirmClear(false)}
          />
        ) : (
          <Button
            theme={t}
            variant="destructive"
            label="Clear Local Logs"
            disabled={props.busy === true}
            onPress={() => setConfirmClear(true)}
            testID="logs-clear"
          />
        )}
      </Card>
    </View>
  );
}

/* ================================================================================================ *
 * 90. Supervisor Defect Review
 * ================================================================================================ */

export type DefectReviewDecision = 'approve' | 'out-of-service' | 'request-mechanic';

export interface DefectReviewInfo {
  truck: string;
  trailer: string;
  driver: string;
  /** Inspection kind, e.g. "Pre-Trip" / "Post-Trip". */
  inspection: string;
  defectCount: number;
  photoCount: number;
  remarks: string;
  status?: StatusLabel;
}

const DEFAULT_DEFECT_REVIEW: DefectReviewInfo = {
  truck: 'Truck 7',
  trailer: 'Vacuum Trailer 19',
  driver: 'Alex Ramirez',
  inspection: 'Pre-Trip',
  defectCount: 2,
  photoCount: 1,
  remarks: 'Left rear marker light intermittent. Slack adjuster within limits but noted.',
  status: 'Needs Review',
};

export function SupervisorDefectReviewScreen(props: {
  review?: DefectReviewInfo;
  busy?: boolean;
  onDecision: (decision: DefectReviewDecision) => void;
  onViewPhotos?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const r = props.review ?? DEFAULT_DEFECT_REVIEW;
  const status = r.status ?? 'Needs Review';
  const [confirmOos, setConfirmOos] = useState(false);
  const [photosOpened, setPhotosOpened] = useState(false);

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Defect Review"
        subtitle="Review driver-reported DVIR defects."
      />
      <Card theme={t} title={`${r.truck} · ${r.trailer}`}>
        <StatusBadge label={status} tone={STATUS_TONE[status]} testID="defect-status" />
        <DetailRow theme={t} label="Driver" value={r.driver} />
        <DetailRow theme={t} label="Inspection" value={r.inspection} />
        <DetailRow theme={t} label="Defects" value={String(r.defectCount)} />
        <DetailRow theme={t} label="Photos" value={String(r.photoCount)} />
      </Card>

      <Card theme={t} title="Remarks">
        <Text style={[styles.body2, { color: t.text }]}>{r.remarks}</Text>
        <Button
          theme={t}
          variant="secondary"
          label={`View Photos (${r.photoCount})`}
          onPress={() => {
            setPhotosOpened(true);
            props.onViewPhotos?.();
          }}
          disabled={r.photoCount === 0}
          testID="defect-view-photos"
        />
        {photosOpened ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="defect-photos-feedback">
            {`Opened ${r.photoCount} photo${r.photoCount === 1 ? '' : 's'}`}
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Decision">
        <Button
          theme={t}
          label="Approve Safe to Operate"
          disabled={props.busy === true}
          onPress={() => props.onDecision('approve')}
          testID="defect-approve"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Request Mechanic Review"
          disabled={props.busy === true}
          onPress={() => props.onDecision('request-mechanic')}
          testID="defect-request-mechanic"
        />
        {confirmOos ? (
          <ConfirmInline
            theme={t}
            prompt={`Mark ${r.truck} out of service? The driver will be blocked from operating it until cleared.`}
            confirmLabel="Mark Out of Service"
            onConfirm={() => {
              setConfirmOos(false);
              props.onDecision('out-of-service');
            }}
            onCancel={() => setConfirmOos(false)}
          />
        ) : (
          <Button
            theme={t}
            variant="destructive"
            label="Mark Out of Service"
            disabled={props.busy === true}
            onPress={() => setConfirmOos(true)}
            testID="defect-out-of-service"
          />
        )}
      </Card>
    </View>
  );
}

/* ================================================================================================ *
 * 91. Mechanic Defect Resolution
 * ================================================================================================ */

export type MechanicResolution = 'corrected' | 'no-correction-needed' | 'out-of-service';

const MECHANIC_RESOLUTIONS: readonly { key: MechanicResolution; label: string }[] = [
  { key: 'corrected', label: 'Defects Corrected' },
  {
    key: 'no-correction-needed',
    label: 'Defects Need Not Be Corrected for Safe Operation',
  },
  { key: 'out-of-service', label: 'Out of Service' },
];

export function MechanicDefectResolutionScreen(props: {
  truck?: string;
  trailer?: string;
  defectCount?: number;
  /** Already-captured mechanic signature flag (real capture wired elsewhere). */
  signatureCaptured?: boolean;
  busy?: boolean;
  onSelect: (resolution: MechanicResolution) => void;
  onCaptureSignature?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const truck = props.truck ?? 'Truck 7';
  const trailer = props.trailer ?? 'Vacuum Trailer 19';
  const defectCount = props.defectCount ?? 2;
  const [selected, setSelected] = useState<MechanicResolution | undefined>(undefined);
  const [captured, setCaptured] = useState(props.signatureCaptured ?? false);
  const canSubmit = selected !== undefined && captured && props.busy !== true;

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Defect Resolution"
        subtitle="Mechanic resolution and correction language."
      />
      <Card theme={t} title={`${truck} · ${trailer}`}>
        <DetailRow theme={t} label="Defects" value={String(defectCount)} />
      </Card>

      <Card theme={t} title="Resolution">
        {MECHANIC_RESOLUTIONS.map((r) => {
          const isSelected = r.key === selected;
          return (
            <Pressable
              key={r.key}
              testID={`mechanic-${r.key}`}
              onPress={() => setSelected(r.key)}
              accessibilityRole="radio"
              accessibilityState={{ selected: isSelected }}
              style={[
                styles.option,
                { borderColor: isSelected ? t.primary : t.border },
                isSelected ? { backgroundColor: t.highlight } : null,
              ]}
            >
              <Text style={[styles.optionText, { color: t.text }]}>{r.label}</Text>
              {isSelected ? (
                <StatusBadge label="In Progress" tone={STATUS_TONE['In Progress']} />
              ) : null}
            </Pressable>
          );
        })}
      </Card>

      <Card theme={t} title="Mechanic signature">
        <PlaceholderFrame theme={t} captured={captured} caption="Sign to certify this resolution" />
        <Button
          theme={t}
          variant="secondary"
          label={captured ? 'Re-sign' : 'Sign'}
          onPress={() => {
            setCaptured(true);
            props.onCaptureSignature?.();
          }}
          testID="mechanic-sign"
        />
        {captured ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="mechanic-sign-feedback">
            Signature captured
          </Text>
        ) : null}
      </Card>

      <Button
        theme={t}
        label="Submit Resolution"
        disabled={!canSubmit}
        onPress={() => {
          if (selected !== undefined) props.onSelect(selected);
        }}
        testID="mechanic-submit"
      />
    </View>
  );
}

/* ================================================================================================ *
 * 92. Supervisor Override
 * ================================================================================================ */

export type OverrideKind =
  | 'allow-job-after-review'
  | 'allow-punch-out-pending'
  | 'unlock-ticket'
  | 'return-ticket';

const OVERRIDE_KINDS: readonly { key: OverrideKind; label: string }[] = [
  { key: 'allow-job-after-review', label: 'Allow job work after defect review' },
  { key: 'allow-punch-out-pending', label: 'Allow punch out with pending issue' },
  { key: 'unlock-ticket', label: 'Unlock ticket for correction' },
  { key: 'return-ticket', label: 'Return ticket to driver' },
];

export interface OverrideAuditEntry {
  /** Plain-English audit line, e.g. "Unlock ticket — J. Doe — Today 9:42 AM". */
  summary: string;
}

export function SupervisorOverrideScreen(props: {
  /** Pre-formatted timestamp the override will be stamped with. */
  timestamp?: string;
  signatureCaptured?: boolean;
  /** Recent audit-log lines (display strings only). */
  auditLog?: OverrideAuditEntry[];
  busy?: boolean;
  onApply: (input: { kind: OverrideKind; reason: string }) => void;
  onCaptureSignature?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [kind, setKind] = useState<OverrideKind | undefined>(undefined);
  const [reason, setReason] = useState('');
  const [confirm, setConfirm] = useState(false);
  const [captured, setCaptured] = useState(props.signatureCaptured ?? false);
  const timestamp = props.timestamp ?? 'Now';
  const audit = props.auditLog ?? [];
  const canApply =
    kind !== undefined && reason.trim().length >= 4 && captured && props.busy !== true;

  return (
    <View style={styles.body}>
      <ScreenTitle
        theme={t}
        title="Supervisor Override"
        subtitle="Controlled override for blocked states. Every override is signed and logged."
      />

      <Card theme={t} title="Override">
        {OVERRIDE_KINDS.map((o) => {
          const isSelected = o.key === kind;
          return (
            <Pressable
              key={o.key}
              testID={`override-${o.key}`}
              onPress={() => setKind(o.key)}
              accessibilityRole="radio"
              accessibilityState={{ selected: isSelected }}
              style={[
                styles.option,
                { borderColor: isSelected ? t.primary : t.border },
                isSelected ? { backgroundColor: t.highlight } : null,
              ]}
            >
              <Text style={[styles.optionText, { color: t.text }]}>{o.label}</Text>
            </Pressable>
          );
        })}
      </Card>

      <Card theme={t} title="Reason">
        <TextInput
          testID="override-reason"
          value={reason}
          onChangeText={setReason}
          style={[styles.input, styles.inputMultiline, { borderColor: t.border, color: t.text }]}
          placeholder="Why is this override needed?"
          placeholderTextColor={t.textMuted}
          multiline
          accessibilityLabel="Override reason"
        />
      </Card>

      <Card theme={t} title="Supervisor signature">
        <PlaceholderFrame theme={t} captured={captured} caption="Sign to authorize this override" />
        <Button
          theme={t}
          variant="secondary"
          label={captured ? 'Re-sign' : 'Sign'}
          onPress={() => {
            setCaptured(true);
            props.onCaptureSignature?.();
          }}
          testID="override-sign"
        />
        {captured ? (
          <Text style={[styles.feedback, { color: t.success }]} testID="override-sign-feedback">
            Signature captured
          </Text>
        ) : null}
        <DetailRow theme={t} label="Timestamp" value={timestamp} />
      </Card>

      <Card theme={t} title="Audit log">
        {audit.length === 0 ? (
          <Text style={[styles.body2, { color: t.textMuted }]}>
            No overrides recorded for this item yet.
          </Text>
        ) : (
          audit.map((entry, i) => (
            <Text
              key={`${i}-${entry.summary}`}
              style={[styles.meta, { color: t.textMuted }]}
              testID={`override-audit-${i}`}
            >
              {entry.summary}
            </Text>
          ))
        )}
      </Card>

      {confirm ? (
        <ConfirmInline
          theme={t}
          prompt="Apply this override? It will be signed, timestamped, and recorded in the audit log."
          confirmLabel="Apply Override"
          onConfirm={() => {
            setConfirm(false);
            if (kind !== undefined) props.onApply({ kind, reason: reason.trim() });
          }}
          onCancel={() => setConfirm(false)}
        />
      ) : (
        <Button
          theme={t}
          label="Apply Override"
          disabled={!canApply}
          onPress={() => setConfirm(true)}
          testID="override-apply"
        />
      )}
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ *
 * Styles
 * ------------------------------------------------------------------------------------------------ */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  titleBlock: {
    gap: spacing.xs,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  subtitle: {
    fontSize: typeScale.label,
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  meta: {
    fontSize: typeScale.label,
  },
  feedback: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  errorText: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  detailRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-start',
    gap: spacing.md,
    paddingVertical: 4,
  },
  detailLabel: {
    fontSize: typeScale.label,
    flexShrink: 0,
  },
  detailValue: {
    fontSize: typeScale.label,
    fontWeight: '700',
    flexShrink: 1,
    textAlign: 'right',
  },
  input: {
    minHeight: sizing.minTouchTarget,
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    fontSize: typeScale.body,
  },
  inputMultiline: {
    minHeight: 96,
    textAlignVertical: 'top',
  },
  confirmBox: {
    borderWidth: 1,
    borderRadius: sizing.cardRadius,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  frame: {
    minHeight: 96,
    borderWidth: 1,
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.lg,
  },
  frameText: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  option: {
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    minHeight: sizing.minTouchTarget,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.sm,
  },
  optionText: {
    fontSize: typeScale.body,
    fontWeight: '600',
    flexShrink: 1,
  },
});
