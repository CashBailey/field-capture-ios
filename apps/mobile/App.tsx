/**
 * App shell: every screen state is a member of a finite union — locked (with the reason Hub
 * gave), unlocked, signed-out, or boot-failed. Hub calls underneath are wall-clock-bounded, so
 * "Checking…" always resolves into one of these states; there is no unbounded spinner anywhere.
 *
 * Once signed in, the field runtime is a plain-JS bottom-tab shell (Day / Jobs / SOPs / Sync / More
 * per GUI Master §2) that mounts the built screens — deliberately NOT a navigation/router stack,
 * because those need native modules the current dev build lacks; a state-driven shell loads live
 * from Metro with no rebuild. Driver-facing chrome only — env labels, hub URLs, and backend strings
 * never appear in the header (GUI Master §20); they live under More.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  AppState,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  StatusBar,
  Text,
  TextInput,
  View,
} from 'react-native';

import { appEnv, hubUrl } from './src/config/env';
import { nativeAppVersion } from './src/config/nativeConfig';
import { callDispatch } from './src/config/contacts';
import { captureEvidenceImage, captureValidationGps } from './src/adapters/device';
import {
  Pt210PrinterTransport,
  createPt210SignatureBitmapTest,
  normalizePt210NativeError,
  type Pt210Status,
} from './src/adapters/printer';
import { resetLocalDatabase } from './src/data';
import { fieldwork } from '@fieldcapture/contracts';
import { randomUuid } from './src/platform/random';

import {
  AppHeader,
  Button,
  Card,
  Logo,
  ThemeProvider,
  spacing,
  theme,
  typeScale,
  useTheme,
  type HeaderChip,
  type SignatureValue,
  type Tone,
} from './src/design';
import type {
  FieldSessionResult,
  FieldWorkGate,
  HubAssignment,
  SrSyncState,
  TicketCaptureMethod,
  UserProfile,
} from './src/domain';
import {
  applyOfflinePolicyToGate,
  buildSignatureRecord,
  jhaJsaForm,
  postTripDvirForm,
  preTripDvirForm,
  signatureBytes,
} from './src/domain';
import {
  classifyBootFailure,
  subscribeForegroundSync,
  wireAppRuntime,
  type AppRuntime,
  type BootFailure,
  type WorkflowActionResult,
} from './src/runtime';
import {
  buildWorkdayTimeline,
  CaptureEvidenceScreen,
  DayDashboardScreen,
  FieldWorkflowScreen,
  LocationValidationScreen,
  Pt210DiagnosticScreen,
  PrintQueueScreen,
  ReceiptCaptureScreen,
  TicketCaptureScreen,
  type CaptureEvidenceDevice,
} from './src/screens';
import {
  RequiredDriverSopsScreen,
  SopAcknowledgementScreen,
  SopReaderScreen,
  SopSearchScreen,
} from './src/screens/SopExtraScreens';
import {
  PendingSyncItemsScreen,
  SyncCompleteScreen,
  SyncFailedItemsScreen,
  SyncHomeScreen,
  SyncItemDetailScreen,
  type SyncItem,
  type SyncOverallState,
} from './src/screens/SyncScreens';
import {
  EmergencyInfoScreen,
  JobDetailsScreen,
  JobOverviewScreen,
  JobSopsScreen,
  JobsListScreen,
  StopWorkScreen,
  type JobGroup,
  type JobIdentity,
  type JobListItem,
  type JobStatusLabel,
} from './src/screens/JobScreens';
import {
  AccountScreen,
  ContactDispatchScreen,
  HelpSupportScreen,
  MoreHomeScreen,
  PrinterSettingsScreen,
  SignOutConfirmScreen,
  TextSizeScreen,
  ThemeScreen,
  type TextSizeChoice,
} from './src/screens/MoreScreens';
import {
  AdminDashboardScreen,
  AdminModeLockScreen,
  EnvironmentDetailsScreen,
  LogsExportScreen,
  MechanicDefectResolutionScreen,
  PrinterDiagnosticsScreen,
  SupervisorDefectReviewScreen,
  SupervisorOverrideScreen,
  SyncDiagnosticsScreen,
  type EnvironmentInfo,
} from './src/screens/AdminScreens';
import {
  FirstRunPermissionsScreen,
  OfflineSavedWorkScreen,
  SessionExpiredScreen,
  SignInHelpScreen,
} from './src/screens/UnauthScreens';
import {
  CameraCaptureScreen,
  JobCompleteReviewScreen,
  JobEvidenceScreen,
  PhotoReviewScreen,
  PrintTicketScreen,
  ReceiptCaptureScreen as EvidenceReceiptCaptureScreen,
  ReceiptFormScreen,
  SignatureCaptureScreen,
  evidenceRouteForMenuKey,
} from './src/screens/EvidenceScreens';
import {
  DefectDetailScreen,
  PreTripCompleteScreen,
  PreTripOverviewScreen,
  PreTripReviewScreen,
  PreTripSectionScreen,
  PreTripSignatureScreen,
  type InspectionSummary,
} from './src/screens/PreTripScreens';
import {
  EndDayReviewScreen,
  PostTripCompleteScreen,
  PostTripOverviewScreen,
  PostTripReviewScreen,
  PostTripSectionScreen,
  PostTripSignatureScreen,
} from './src/screens/PostTripScreens';
import {
  JhaCompleteScreen,
  JhaEmergencyInfoScreen,
  JhaHazardsScreen,
  JhaJobAndSiteScreen,
  JhaJobStepsScreen,
  JhaOverviewScreen,
  JhaPpeScreen,
  JhaPreJobSafetyScreen,
  JhaReviewScreen,
  JhaSignaturesScreen,
  JhaStopWorkScreen,
} from './src/screens/JhaScreens';

/** UUIDs for locally-authored work (ticket/receipt drafts, location evidence). */
const identity = { generateUuid: randomUuid };

/** App version for the More screen (from the native bundle). */
const appVersion = nativeAppVersion;

const captureEvidenceDevice: CaptureEvidenceDevice = async ({ source }) => {
  if (source !== 'camera' && source !== 'import') return null;
  return captureEvidenceImage(source);
};

/** Result of a wizard's "submit" — drives the inline confirmation + whether to advance. */
type SubmitResult = { ok: boolean; message: string };

/**
 * Shown when signature capture/persist throws (disk full, permission, I/O) rather than returning a
 * status. The signature is not finalized and the form is not submitted; the inline message keeps the
 * button alive so the driver can retry. (Spec Error Handling: capture failure → saved-locally, no
 * partial submit.)
 */
const signatureCaptureFailure: SubmitResult = {
  ok: false,
  message: 'Saved on this phone — could not finalize the signature. Try again.',
};

/** Outcome of persisting a captured signature as a blob + building its SignatureRecord. */
type SignatureRecordResult =
  | { status: 'ok'; record: fieldwork.SignatureRecord }
  | { status: 'locked'; reason: string };

type SignatureSubmitPayload = {
  signature: SignatureValue;
  signerName: string;
  signerRole?: string;
};

// The durable JHA/DVIR record builders live in src/domain/fieldForms (jhaJsaForm,
// preTripDvirForm, postTripDvirForm) so they are unit-tested for completability —
// a form missing its signature can never be completed or submitted.

/** Map a workflow save/submit result to the wizard's inline confirmation. */
function workflowSubmitResult(res: WorkflowActionResult<unknown>, okMessage: string): SubmitResult {
  switch (res.status) {
    case 'ok':
      return { ok: true, message: okMessage };
    case 'locked':
      return { ok: false, message: `Field work is locked: ${res.reason}.` };
    case 'invalid':
      return { ok: false, message: res.errors.join(', ') };
    case 'frozen':
      return { ok: false, message: `Already ${res.recordStatus} — nothing to resubmit.` };
    default:
      return { ok: false, message: 'Could not submit. Your work is saved on this phone.' };
  }
}

/** Map a cached Hub assignment to the driver-facing Jobs-list item (no UUIDs/hashes). */
function wellsLabel(a: HubAssignment): string {
  const names = (a.details?.wells ?? []).map((w) => w.name).filter((n) => n.length > 0);
  return names.length > 0 ? names.join(', ') : 'Well';
}

function srSyncLabel(state: SrSyncState | undefined): JobStatusLabel {
  switch (state) {
    case 'needs-review':
      return 'Needs Review';
    case 'needs-sync':
      return 'Pending Sync';
    case 'synced':
      return 'Synced';
    default:
      return 'Saved on Phone';
  }
}

function toJobListItem(a: HubAssignment, sync: SrSyncState | undefined): JobListItem {
  const d = a.details;
  const status = d?.status;
  const group: JobGroup =
    status === 'completed' ? 'completed' : status === 'in_progress' ? 'current' : 'next';
  const hasLocalWork = sync !== undefined && sync !== 'no-local-work';
  return {
    serviceRecord: d?.requestNo ?? a.serviceRequestId,
    customer: d?.customer?.name ?? 'Customer',
    lease: d?.lease?.name ?? 'Lease',
    well: wellsLabel(a),
    jobType: d?.jobType?.name ?? 'Job',
    group,
    jhaStatus: 'Not Started',
    ticketStatus: 'Not Started',
    syncStatus: srSyncLabel(sync),
    primaryLabel: hasLocalWork ? 'Continue Job' : 'Start Job',
  };
}

function toJobIdentity(a: HubAssignment | undefined): JobIdentity {
  const d = a?.details;
  return {
    serviceRecord: d?.requestNo ?? a?.serviceRequestId ?? '—',
    customer: d?.customer?.name ?? 'Customer',
    lease: d?.lease?.name ?? 'Lease',
    well: a !== undefined ? wellsLabel(a) : 'Well',
    jobType: d?.jobType?.name ?? 'Job',
    truck: d?.vehicle?.name ?? 'Unassigned',
    trailer: d?.trailer?.name ?? 'Unassigned',
    destination: d?.disposalSite?.name ?? 'Disposal site',
  };
}

function formatLastHubContactLabel(lastHubContactAtMs: number | null | undefined): string {
  if (lastHubContactAtMs === undefined || lastHubContactAtMs === null) return 'Never';
  return new Date(lastHubContactAtMs).toLocaleString();
}

type BootState =
  | { phase: 'starting' }
  | { phase: 'ready'; runtime: AppRuntime }
  | { phase: 'failed'; failure: BootFailure };

export default function App() {
  return (
    <ThemeProvider>
      <AppRoot />
    </ThemeProvider>
  );
}

function AppRoot() {
  const t = useTheme();
  const [boot, setBoot] = useState<BootState>({ phase: 'starting' });
  const [authNeeded, setAuthNeeded] = useState(false);
  // A previously-valid session that died mid-shift (retry engine signalled auth) → Session Expired,
  // distinct from a never-signed-in cold start.
  const [sessionExpired, setSessionExpired] = useState(false);
  const [resetArmed, setResetArmed] = useState(false);
  const [bootAttempt, setBootAttempt] = useState(0);

  useEffect(() => {
    let cancelled = false;
    wireAppRuntime({
      onAuthRequired: () => {
        setAuthNeeded(true);
        setSessionExpired(true);
      },
    }).then(
      (runtime) => {
        if (!cancelled) setBoot({ phase: 'ready', runtime });
      },
      (error: unknown) => {
        // Visible, classified failure — never a guess, never an auto-wipe. classifyBootFailure
        // distinguishes a missing Hub URL (HubConfigError) from a DB key mismatch (the only
        // resettable case) from any other error, with a plain-language message for each.
        if (!cancelled) {
          setBoot({ phase: 'failed', failure: classifyBootFailure(error) });
        }
      },
    );
    return () => {
      cancelled = true;
    };
  }, [bootAttempt]);

  if (boot.phase === 'ready') {
    return (
      <FieldSessionShell
        runtime={boot.runtime}
        authNeeded={authNeeded}
        sessionExpired={sessionExpired}
        onAuthNeeded={(needed) => {
          setAuthNeeded(needed);
          if (!needed) setSessionExpired(false);
        }}
      />
    );
  }

  // Splash / boot — branded, no technical details (GUI Master §1). The DB-key-mismatch reset is the
  // one exception that must stay explicit and double-confirmed.
  return (
    <View style={[styles.splash, { backgroundColor: t.background }]}>
      <Logo size={96} ring />
      <Text style={[styles.brand, { color: t.text }]}>Field Capture</Text>
      {boot.phase === 'starting' && (
        <Text style={[styles.splashMeta, { color: t.textMuted }]}>Opening saved work…</Text>
      )}
      {boot.phase === 'failed' && (
        <View
          style={[styles.splashCard, { backgroundColor: t.card, borderColor: t.border }]}
          testID="boot-failed"
        >
          <Text
            style={[styles.error, { color: t.danger }]}
            testID={`boot-failed-${boot.failure.reason}`}
          >
            {boot.failure.message}
          </Text>
          {boot.failure.canReset && (
            <Button
              variant="destructive"
              label={
                resetArmed
                  ? 'Tap again to CONFIRM reset — unsynced work will be lost'
                  : 'Reset local data…'
              }
              onPress={() => {
                if (!resetArmed) {
                  setResetArmed(true);
                  return;
                }
                resetLocalDatabase();
                setResetArmed(false);
                setBoot({ phase: 'starting' });
                setBootAttempt((n) => n + 1);
              }}
            />
          )}
        </View>
      )}
      <StatusBar barStyle="dark-content" />
    </View>
  );
}

type RefreshState =
  | { status: 'idle' }
  | { status: 'checking' } // bounded: the Hub client times out at 15s and resolves to a state
  | { status: 'done'; result: FieldSessionResult }
  /** A local-device exception escaped (keystore, SQLite). Visible, retryable — never a spinner. */
  | { status: 'failed'; message: string };

type Tab = 'day' | 'jobs' | 'sops' | 'sync' | 'more';
type WorkPanel =
  | 'detail'
  | 'jha'
  | 'evidence'
  | 'jobdetails'
  | 'jobsops'
  | 'emergency'
  | 'stopwork'
  | 'forms'
  | 'ticket'
  | 'receipt'
  | 'capture'
  | 'location'
  | 'print';

const JOB_SUB_FLOWS: readonly WorkPanel[] = [
  'jha',
  'evidence',
  'jobdetails',
  'jobsops',
  'emergency',
  'stopwork',
];

const TABS: readonly { key: Tab; label: string }[] = [
  { key: 'day', label: 'Day' },
  { key: 'jobs', label: 'Jobs' },
  { key: 'sops', label: 'SOPs' },
  { key: 'sync', label: 'Sync' },
  { key: 'more', label: 'More' },
];

const WORK_PANELS: readonly { key: WorkPanel; label: string }[] = [
  { key: 'detail', label: 'Details' },
  { key: 'forms', label: 'Safety' },
  { key: 'ticket', label: 'Ticket' },
  { key: 'receipt', label: 'Receipt' },
  { key: 'capture', label: 'Evidence' },
  { key: 'location', label: 'Location' },
  { key: 'print', label: 'Print' },
];

function titleCaseToken(value: string): string {
  return value
    .split(/[-_\s]+/)
    .filter((part) => part.length > 0)
    .map((part) => part[0]!.toUpperCase() + part.slice(1).toLowerCase())
    .join(' ');
}

function profileDisplayName(
  profile: UserProfile | null,
  fallbackUsername: string,
): string | undefined {
  return (
    profile?.displayName ??
    profile?.username ??
    (fallbackUsername.trim().length > 0 ? fallbackUsername.trim() : undefined)
  );
}

function profileRole(profile: UserProfile | null): string | undefined {
  return (
    profile?.title ??
    (profile?.accessProfile !== undefined ? titleCaseToken(profile.accessProfile) : undefined)
  );
}

function FieldSessionShell(props: {
  runtime: AppRuntime;
  authNeeded: boolean;
  sessionExpired: boolean;
  onAuthNeeded: (needed: boolean) => void;
}) {
  const { controller, durability, field } = props.runtime;
  const t = useTheme();
  const [refresh, setRefresh] = useState<RefreshState>({ status: 'idle' });
  const [fieldGate, setFieldGate] = useState<FieldWorkGate>(() => field.gate.get());
  const [tab, setTab] = useState<Tab>('day');
  const [jobView, setJobView] = useState<'list' | 'work'>('list');
  const [workPanel, setWorkPanel] = useState<WorkPanel>('detail');
  const [selectedSrId, setSelectedSrId] = useState<string | undefined>(undefined);
  const [workStartStatus, setWorkStartStatus] = useState<{ label: string; tone: Tone } | undefined>(
    undefined,
  );
  // Only the setter is used: bumping it forces a re-render so the store-derived summaries below
  // recompute after a save/delete/refresh. The value itself is never read.
  const [, setRevision] = useState(0);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const [loginMessage, setLoginMessage] = useState<string | null>(null);
  const [manualSyncing, setManualSyncing] = useState(false);
  const { onAuthNeeded } = props;
  const alive = useRef(true);
  const bump = () => setRevision((n) => n + 1);

  useEffect(() => {
    // On a foreground return, AppController.onForeground re-validates the session (a silent refresh
    // resumes any runner that paused for auth while backgrounded — e.g. an overnight token expiry)
    // and then kicks the sync + upload drivers so queued evidence drains promptly (connectivity is
    // usually back and RN may have throttled the background timer). `controller` is created once at
    // boot, so this effect runs a single subscribe/cleanup.
    const unsubscribeForeground = subscribeForegroundSync(
      AppState,
      () => void controller.onForeground(),
      AppState.currentState,
    );
    return () => {
      // Stop the foreground event source FIRST, then tear down the controller.
      unsubscribeForeground();
      controller.stop();
      alive.current = false;
    };
  }, [controller]);

  useEffect(() => {
    let cancelled = false;
    controller.currentUserProfile().then((profile) => {
      if (!cancelled && alive.current) setUserProfile(profile);
    });
    return () => {
      cancelled = true;
    };
  }, [controller]);

  const doRefresh = useCallback(async () => {
    setRefresh({ status: 'checking' });
    try {
      const result = await controller.refreshSession(); // Hub failures resolve to locked states
      if (!alive.current) return;
      const gate = applyOfflinePolicyToGate({
        previousGate: field.gate.get(),
        nextGate: result.gate,
        offlinePolicy: controller.offlinePolicy(),
      });
      const effectiveResult = gate === result.gate ? result : { ...result, gate };
      field.gate.set(gate);
      setFieldGate(gate);
      setRefresh({ status: 'done', result: effectiveResult });
      onAuthNeeded(gate.state === 'locked' && gate.reason === 'auth-failed');
      setRevision((n) => n + 1);
    } catch (error) {
      // Local-device failures (SQLite write, keystore) are the only throws left — they must land
      // in a visible state too. No infinite "Checking Hub".
      if (!alive.current) return;
      setRefresh({ status: 'failed', message: String(error) });
    }
  }, [controller, field, onAuthNeeded]);

  useEffect(() => {
    // Deferred a tick: the first refresh must not set state synchronously inside the effect.
    const timer = setTimeout(() => void doRefresh(), 0);
    return () => clearTimeout(timer);
  }, [doRefresh]);

  const doManualSync = useCallback(async () => {
    setManualSyncing(true);
    try {
      await doRefresh();
      // This revalidates/resumes any auth-paused runners, then kicks both V2 sync and blob upload.
      await controller.onForeground();
      if (alive.current) bump();
    } finally {
      if (alive.current) setManualSyncing(false);
    }
  }, [controller, doRefresh]);

  const doLogin = useCallback(async () => {
    setLoginMessage(null);
    try {
      const result = await controller.login({ username, password });
      if (!alive.current) return;
      if (result.status === 'signed-in') {
        setPassword('');
        setUserProfile(await controller.currentUserProfile());
        onAuthNeeded(false);
        await doRefresh();
        return;
      }
      setLoginMessage(
        result.status === 'invalid-credentials'
          ? `Sign-in rejected${result.detail !== undefined ? `: ${result.detail}` : ''}`
          : `Hub unavailable (${result.reason}) — try again`,
      );
    } catch (error) {
      if (!alive.current) return;
      setLoginMessage(`Sign-in failed on this device: ${String(error)}`);
    }
  }, [controller, username, password, onAuthNeeded, doRefresh]);

  // Derived each render from the durable stores (cheap synchronous reads). bump() forces the
  // recompute after a save/delete/refresh so the inbox state and Sync Center stay truthful.
  const assignments = props.runtime.assignmentStore.listAssignments();
  const driverName = profileDisplayName(userProfile, username);
  const driverRole = profileRole(userProfile);
  const employeeId =
    fieldGate.state === 'unlocked' &&
    typeof fieldGate.employeeId === 'string' &&
    fieldGate.employeeId.length > 0
      ? fieldGate.employeeId
      : userProfile?.employeeId;
  const syncStateById = controller.srSyncStateById();
  const needsReviewCount = [...syncStateById.values()].filter((s) => s === 'needs-review').length;
  const pendingSyncItems: SyncItem[] = assignments
    .filter((a) => syncStateById.get(a.serviceRequestId) === 'needs-sync')
    .map((a) => ({
      key: a.serviceRequestId,
      label: `Field ticket · SR ${a.details?.requestNo ?? a.serviceRequestId}`,
      status: 'Pending Sync',
    }));
  const draftCount =
    props.runtime.draftStore.list().length + props.runtime.receiptStore.list().length;
  const syncSummary = controller.syncCenterSummary(draftCount);
  const offlinePolicyState = props.runtime.offlinePolicyStore.getState();
  const effectiveSrId = selectedSrId ?? assignments[0]?.serviceRequestId ?? 'sr-1';
  const selectedAssignment = assignments.find((a) => a.serviceRequestId === effectiveSrId);
  // The SR's human request number IS the ticket id (item 1); the job type gates the flowback
  // customer-signature rule (item 6); the saved draft's captureMethod gates the hybrid ticket-photo
  // rule (item 5). All derived here so the screens stay dumb.
  const selectedRequestNo = selectedAssignment?.details?.requestNo;
  const selectedJobType = selectedAssignment?.details?.jobType?.name;
  const selectedCaptureMethod = props.runtime.draftStore
    .list()
    .find((d) => d.serviceRequestId === effectiveSrId)?.captureMethod;

  const openSr = (serviceRequestId: string) => {
    setSelectedSrId(serviceRequestId);
    setWorkStartStatus(undefined);
    setWorkPanel('detail');
    setJobView('work');
    setTab('jobs');
  };

  // The Jobs list yields the driver-facing record number (e.g. 2026-000001), never the internal id —
  // resolve it back to the assignment's serviceRequestId before opening.
  const openJobByRecord = (record: string) => {
    const match = assignments.find((a) => (a.details?.requestNo ?? a.serviceRequestId) === record);
    openSr(match?.serviceRequestId ?? record);
  };

  const submitCurrentDraft = async () => {
    const draft = props.runtime.draftStore.list().find((d) => d.serviceRequestId === effectiveSrId);
    if (draft === undefined) return { status: 'draft-missing' };
    return controller.submitNewTicket({
      serviceRequestId: draft.serviceRequestId,
      ticketNo: draft.ticketNo,
      quantityBbl: draft.quantityBbl,
      disposalTicketNo: draft.disposalTicketNo,
    });
  };

  const vehicleRef = selectedAssignment?.details?.vehicle?.name ?? 'vehicle';

  const startWork = () => {
    const actorRef =
      fieldGate.state === 'unlocked' &&
      typeof fieldGate.employeeId === 'string' &&
      fieldGate.employeeId.length > 0
        ? fieldGate.employeeId
        : username;
    const result = field.workStart.startWork({
      serviceRequestId: effectiveSrId,
      actorRef,
    });
    if (result.status === 'ok') {
      setWorkStartStatus({ label: 'Work start saved', tone: 'success' });
      bump();
      return;
    }
    if (result.status === 'locked') {
      setWorkStartStatus({ label: `Locked: ${result.reason}`, tone: 'warning' });
      return;
    }
    setWorkStartStatus({ label: result.errors.join(', '), tone: 'danger' });
  };

  // Wizard completions persist REAL records via the same services the functional panels use:
  // saving + completing + submitting a durable form/ticket so the outcome shows up in Sync.
  //
  // The driver's drawn signature is captured as a durable blob (CaptureFlow) and wrapped in a
  // SignatureRecord (signer identity, UTC timestamp, certification text, consent, device/audit)
  // before the form is built — a form can never be completed without its real signature.
  const persistSignature = async (
    serviceRequestId: string,
    certificationText: string,
    payload: SignatureSubmitPayload,
  ): Promise<SignatureRecordResult> => {
    const result = await field.capture.capture({
      bytes: signatureBytes(payload.signature),
      mimeType: 'application/octet-stream',
      source: 'signature-pad',
      attachmentKind: 'signature',
      parentType: 'sr',
      parentId: serviceRequestId,
    });
    if (result.status === 'locked') return { status: 'locked', reason: result.reason };
    const record = buildSignatureRecord({
      blobId: result.record.blobId,
      signerName: payload.signerName,
      ...(username.length > 0 && payload.signerRole === 'Driver' ? { signerUserId: username } : {}),
      ...(payload.signerRole !== undefined ? { signerRole: payload.signerRole } : {}),
      signedAtUtc: new Date().toISOString(),
      certificationText,
      deviceInstanceId: field.deviceInstanceId,
      appVersion: appVersion ?? 'unknown',
    });
    return { status: 'ok', record };
  };
  const submitPreTripInspection = async (payload: {
    signature: SignatureValue;
    signerName: string;
  }): Promise<SubmitResult> => {
    try {
      const sig = await persistSignature(
        effectiveSrId,
        fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT,
        payload,
      );
      if (sig.status === 'locked')
        return { ok: false, message: `Field work is locked: ${sig.reason}.` };
      const form = preTripDvirForm(effectiveSrId, vehicleRef, sig.record);
      field.workflow.saveDraft(form);
      const completed = field.workflow.completeForm(form.formId);
      if (completed.status !== 'ok') {
        bump();
        return workflowSubmitResult(completed, '');
      }
      const res = field.workflow.submitForm(form.formId);
      bump();
      return workflowSubmitResult(res, 'Pre-trip inspection completed and saved on this phone.');
    } catch {
      // Capture/persist threw (disk full, permission, I/O): nothing was completed or submitted —
      // surface a saved-locally message so the button never looks dead and no partial submit occurs.
      return signatureCaptureFailure;
    }
  };
  const submitPostTripInspection = async (payload: {
    signature: SignatureValue;
    signerName: string;
  }): Promise<SubmitResult> => {
    try {
      const sig = await persistSignature(
        effectiveSrId,
        fieldwork.DVIR_POSTTRIP_CERTIFICATION_TEXT,
        payload,
      );
      if (sig.status === 'locked')
        return { ok: false, message: `Field work is locked: ${sig.reason}.` };
      const form = postTripDvirForm(effectiveSrId, vehicleRef, sig.record);
      field.workflow.saveDraft(form);
      const completed = field.workflow.completeForm(form.formId);
      if (completed.status !== 'ok') {
        bump();
        return workflowSubmitResult(completed, '');
      }
      const res = field.workflow.submitForm(form.formId);
      bump();
      return workflowSubmitResult(res, 'Post-trip inspection completed and saved on this phone.');
    } catch {
      // Capture/persist threw: leave a draft, no partial submit, surface a saved-locally message.
      return signatureCaptureFailure;
    }
  };
  const submitJhaForm = async (payload: {
    signatures: SignatureSubmitPayload[];
  }): Promise<SubmitResult> => {
    if (payload.signatures.length === 0) return { ok: false, message: 'A signature is required.' };
    try {
      const records: fieldwork.SignatureRecord[] = [];
      for (const signature of payload.signatures) {
        const sig = await persistSignature(
          effectiveSrId,
          fieldwork.JHA_CERTIFICATION_TEXT,
          signature,
        );
        if (sig.status === 'locked')
          return { ok: false, message: `Field work is locked: ${sig.reason}.` };
        records.push(sig.record);
      }
      const form = jhaJsaForm(effectiveSrId, records);
      field.workflow.saveDraft(form);
      const completed = field.workflow.completeForm(form.formId);
      if (completed.status !== 'ok') {
        bump();
        return workflowSubmitResult(completed, '');
      }
      const res = field.workflow.submitForm(form.formId);
      bump();
      return workflowSubmitResult(res, 'JHA/JSA completed and saved on this phone.');
    } catch {
      // Capture/persist threw: leave a draft, no partial submit, surface a saved-locally message.
      return signatureCaptureFailure;
    }
  };
  // Unauthenticated: a dedicated Sign In screen, no bottom navigation (GUI Master §2).
  if (props.authNeeded) {
    return (
      <SignInView
        username={username}
        password={password}
        message={loginMessage}
        expired={props.sessionExpired}
        onUsername={setUsername}
        onPassword={setPassword}
        onSubmit={() => void doLogin()}
      />
    );
  }

  // Status strip: show only what matters (GUI Master §3) — never env/hub/backend strings.
  const chips: HeaderChip[] = [];
  if (fieldGate.state === 'unlocked') chips.push({ label: 'Punched In', tone: 'success' });
  else if (fieldGate.state === 'locked' && fieldGate.reason === 'hub-unreachable')
    chips.push({ label: 'Offline Mode', tone: 'warning' });
  else if (fieldGate.state === 'locked' && fieldGate.reason === 'not-clocked-in')
    chips.push({ label: 'Not Punched In', tone: 'warning' });
  // Generic outbox (safety-form events etc.) that are owed to the Hub, on top of ticket evidence.
  const formOutboxPending = props.runtime.outbox
    .list()
    .filter((i) => i.state === 'pending' || i.state === 'in-flight').length;
  const pendingSync =
    syncSummary.counts['waiting-to-sync'] +
    syncSummary.counts['waiting-on-you'] +
    formOutboxPending;
  if (pendingSync > 0) chips.push({ label: `${pendingSync} Pending Sync`, tone: 'info' });
  const vehicleName = selectedAssignment?.details?.vehicle?.name;
  if (vehicleName !== undefined && vehicleName.length > 0)
    chips.push({ label: vehicleName, tone: 'neutral' });

  const dayStatusDetail =
    fieldGate.state === 'locked' && fieldGate.reason === 'hub-unreachable'
      ? 'Hub unreachable — your saved work is safe on this phone and will sync later.'
      : fieldGate.state === 'locked' && fieldGate.reason === 'bad-hub-response'
        ? 'The Hub answered unexpectedly. Try again in a moment.'
        : undefined;

  const syncLastHubContactLabel =
    refresh.status === 'checking'
      ? 'Checking now…'
      : refresh.status === 'failed'
        ? `Last attempt failed on this device · ${formatLastHubContactLabel(
            offlinePolicyState.lastHubContactAtMs,
          )}`
        : formatLastHubContactLabel(offlinePolicyState.lastHubContactAtMs);

  return (
    <View style={[styles.shell, { backgroundColor: t.background }]}>
      <AppHeader chips={chips} />
      <View
        style={[styles.tabBar, { backgroundColor: t.card, borderBottomColor: t.border }]}
        testID="tab-bar"
      >
        {TABS.map((tabDef) => {
          const selected = tab === tabDef.key;
          return (
            <Pressable
              key={tabDef.key}
              testID={`tab-${tabDef.key}`}
              onPress={() => {
                setTab(tabDef.key);
                if (tabDef.key === 'jobs') setJobView('list');
              }}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={styles.tabItem}
            >
              <Text style={[styles.tabLabel, { color: selected ? t.primary : t.textMuted }]}>
                {tabDef.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {refresh.status === 'checking' && (
        <Text style={[styles.headerMeta, { color: t.textMuted }]}>Checking Hub…</Text>
      )}

      <ScrollView
        style={[styles.body, { backgroundColor: t.background }]}
        contentContainerStyle={styles.bodyInner}
      >
        {tab === 'day' && (
          <DayTab
            punchedIn={fieldGate.state === 'unlocked'}
            {...(fieldGate.state === 'unlocked' && typeof fieldGate.clockedInSince === 'string'
              ? { clockedInSince: fieldGate.clockedInSince }
              : {})}
            {...(dayStatusDetail !== undefined ? { statusDetail: dayStatusDetail } : {})}
            jobsCount={assignments.length}
            needsReview={needsReviewCount}
            pendingSync={pendingSync}
            checking={refresh.status === 'checking'}
            onOpenJobs={() => setTab('jobs')}
            onRefresh={() => void doRefresh()}
            onSubmitPreTrip={submitPreTripInspection}
            onSubmitPostTrip={submitPostTripInspection}
            {...(driverName !== undefined ? { driverName } : {})}
          />
        )}

        {tab === 'jobs' && jobView === 'list' && (
          <JobsListScreen
            jobs={assignments.map((a) => toJobListItem(a, syncStateById.get(a.serviceRequestId)))}
            onOpenJob={openJobByRecord}
            onRefresh={() => void doRefresh()}
          />
        )}

        {tab === 'jobs' && jobView === 'work' && (
          <View style={styles.gap}>
            <Pressable
              testID="job-back"
              onPress={() => setJobView('list')}
              accessibilityRole="button"
            >
              <Text style={styles.backLink}>‹ All jobs</Text>
            </Pressable>
            {!JOB_SUB_FLOWS.includes(workPanel) && (
              <View style={styles.panelTabs}>
                {WORK_PANELS.map((p) => {
                  const selected = workPanel === p.key;
                  return (
                    <Pressable
                      key={p.key}
                      testID={`work-panel-${p.key}`}
                      onPress={() => setWorkPanel(p.key)}
                      accessibilityRole="button"
                      accessibilityState={{ selected }}
                      style={[styles.chip, selected ? styles.chipSelected : null]}
                    >
                      <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                        {p.label}
                      </Text>
                    </Pressable>
                  );
                })}
              </View>
            )}
            {workPanel === 'detail' && (
              <JobOverviewScreen
                job={toJobIdentity(selectedAssignment)}
                primaryLabel="Start JHA/JSA"
                onPrimary={() => setWorkPanel('jha')}
                onStartWork={startWork}
                workStartStatus={workStartStatus}
                onAddEvidence={() => setWorkPanel('capture')}
                onCaptureGps={() => setWorkPanel('location')}
                onAddReceipt={() => setWorkPanel('receipt')}
                onPrintTicket={() => setWorkPanel('print')}
                onEmergencyInfo={() => setWorkPanel('emergency')}
                onStopWork={() => setWorkPanel('stopwork')}
                onMenu={(key) => {
                  if (key === 'details') setWorkPanel('jobdetails');
                  else if (key === 'sops') setWorkPanel('jobsops');
                  else if (key === 'emergency') setWorkPanel('emergency');
                  else if (key === 'stop-work') setWorkPanel('stopwork');
                  else if (key === 'evidence') setWorkPanel('capture');
                  else if (key === 'print') setWorkPanel('print');
                  else if (key === 'directions') {
                    const dest = toJobIdentity(selectedAssignment).destination;
                    void Linking.openURL(
                      `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(dest)}`,
                    );
                  } else if (key === 'dispatch') callDispatch();
                }}
              />
            )}
            {(workPanel === 'jobdetails' ||
              workPanel === 'jobsops' ||
              workPanel === 'emergency' ||
              workPanel === 'stopwork') && (
              <View style={styles.gap}>
                <Pressable
                  testID="jobsub-back"
                  onPress={() => setWorkPanel('detail')}
                  accessibilityRole="button"
                >
                  <Text style={styles.backLink}>‹ Back to job</Text>
                </Pressable>
                {workPanel === 'jobdetails' && <JobDetailsScreen />}
                {workPanel === 'jobsops' && <JobSopsScreen />}
                {workPanel === 'emergency' && <EmergencyInfoScreen />}
                {workPanel === 'stopwork' && <StopWorkScreen />}
              </View>
            )}
            {workPanel === 'jha' && (
              <JhaFlow
                onExit={() => setWorkPanel('detail')}
                onStartFieldTicket={() => setWorkPanel('ticket')}
                onSubmit={submitJhaForm}
                {...(driverName !== undefined ? { driverName } : {})}
              />
            )}
            {workPanel === 'evidence' && (
              <EvidenceFlow
                onExit={() => setWorkPanel('detail')}
                {...(selectedCaptureMethod !== undefined
                  ? { captureMethod: selectedCaptureMethod }
                  : {})}
                {...(selectedJobType !== undefined ? { jobType: selectedJobType } : {})}
              />
            )}
            {workPanel === 'forms' && (
              <FieldWorkflowScreen
                gate={fieldGate}
                workflow={field.workflow}
                forms={field.forms}
                serviceRequestId={effectiveSrId}
                onSubmitTicket={submitCurrentDraft}
              />
            )}
            {workPanel === 'ticket' && (
              <TicketCaptureScreen
                draftStore={props.runtime.draftStore}
                serviceRequestId={effectiveSrId}
                {...(selectedRequestNo !== undefined ? { requestNo: selectedRequestNo } : {})}
                {...(driverName !== undefined ? { driverName } : {})}
                gate={fieldGate}
                identity={identity}
                onSaved={bump}
                onDeleted={bump}
              />
            )}
            {workPanel === 'receipt' && (
              <ReceiptCaptureScreen
                receiptStore={props.runtime.receiptStore}
                serviceRequestId={effectiveSrId}
                gate={fieldGate}
                identity={identity}
                onSaved={bump}
                onDeleted={bump}
              />
            )}
            {workPanel === 'capture' && (
              <CaptureEvidenceScreen
                capture={field.capture}
                uploads={field.uploadEngine}
                blobs={field.blobs}
                parentType="field-ticket"
                parentId={effectiveSrId}
                linkOutcome={field.linkOutcome}
                captureDevice={captureEvidenceDevice}
              />
            )}
            {workPanel === 'location' && (
              <LocationValidationScreen
                locationStore={props.runtime.locationStore}
                serviceRequestId={effectiveSrId}
                gate={fieldGate}
                captureGps={captureValidationGps}
                identity={identity}
                onSaved={(evidence) => {
                  field.locationEvidenceSync.enqueue(evidence);
                  bump();
                }}
              />
            )}
            {workPanel === 'print' && (
              <View style={styles.gap}>
                <PrintQueueScreen runtime={field.printRuntime} queue={field.printQueue} />
                <Pt210DiagnosticScreen />
              </View>
            )}
          </View>
        )}

        {tab === 'sops' && <SopsTab />}

        {tab === 'sync' && (
          <SyncTab
            pendingCount={pendingSync}
            failedCount={syncSummary.counts['rejected-by-hub']}
            syncedCount={syncSummary.counts['accepted-by-hub']}
            offline={fieldGate.state === 'locked' && fieldGate.reason === 'hub-unreachable'}
            lastSyncedAt={syncLastHubContactLabel}
            syncing={refresh.status === 'checking' || manualSyncing}
            pendingItems={pendingSyncItems}
            onSyncNow={() => void doManualSync()}
          />
        )}

        {tab === 'more' && (
          <MoreTab
            punchedIn={fieldGate.state === 'unlocked'}
            onOpenSops={() => setTab('sops')}
            syncSummary={
              pendingSync === 0
                ? 'All work is saved and up to date.'
                : `${pendingSync} item${pendingSync === 1 ? '' : 's'} waiting to sync. Your work is safe on this phone.`
            }
            syncTone={pendingSync === 0 ? 'success' : 'warning'}
            {...(driverName !== undefined ? { driverName } : {})}
            {...(driverRole !== undefined ? { driverRole } : {})}
            {...(userProfile?.department !== undefined
              ? { department: userProfile.department }
              : {})}
            {...(employeeId !== undefined ? { employeeId } : {})}
            {...(userProfile?.phone !== undefined ? { phone: userProfile.phone } : {})}
            {...(userProfile?.assignedYard !== undefined
              ? { assignedYard: userProfile.assignedYard }
              : {})}
            {...(userProfile?.defaultTruck !== undefined
              ? { defaultTruck: userProfile.defaultTruck }
              : {})}
            {...(userProfile?.defaultTrailer !== undefined
              ? { defaultTrailer: userProfile.defaultTrailer }
              : {})}
            envInfo={{
              hubEnvironment: appEnv,
              hubUrl: hubUrl ?? 'not configured',
              appVersion: appVersion ?? '—',
              build: 'development',
              storageEngine: durability,
              deviceId: 'This device',
              lastSync: syncLastHubContactLabel,
            }}
            onSignOut={async () => {
              await controller.logout();
              setUserProfile(null);
              onAuthNeeded(true);
              bump();
            }}
          />
        )}
      </ScrollView>
      <StatusBar barStyle="dark-content" />
    </View>
  );
}

type SignInAux = 'none' | 'help' | 'offline' | 'permissions' | 'sops';

export function SignInView(props: {
  username: string;
  password: string;
  message: string | null;
  expired?: boolean;
  onUsername: (v: string) => void;
  onPassword: (v: string) => void;
  onSubmit: () => void;
}) {
  const t = useTheme();
  const [aux, setAux] = useState<SignInAux>('none');
  const [expiredDismissed, setExpiredDismissed] = useState(false);
  const home = () => setAux('none');

  // Session Expired (GUI Master §5 screen 6) — shown when a previously-valid session died.
  if (props.expired === true && !expiredDismissed) {
    return (
      <View style={[styles.signInScreen, { backgroundColor: t.background }]}>
        <ScrollView contentContainerStyle={styles.signInBody}>
          <SessionExpiredScreen onSignInAgain={() => setExpiredDismissed(true)} />
        </ScrollView>
        <StatusBar barStyle="dark-content" />
      </View>
    );
  }

  if (aux !== 'none') {
    return (
      <View style={[styles.signInScreen, { backgroundColor: t.background }]}>
        <ScrollView contentContainerStyle={styles.signInBody}>
          <Pressable testID="signin-aux-back" onPress={home} accessibilityRole="button">
            <Text style={styles.backLink}>‹ Back to sign in</Text>
          </Pressable>
          {aux === 'help' && <SignInHelpScreen onBack={home} />}
          {aux === 'offline' && <OfflineSavedWorkScreen onContinue={home} onRetry={home} />}
          {aux === 'permissions' && <FirstRunPermissionsScreen onFinish={home} />}
          {aux === 'sops' && <SopBrowser />}
        </ScrollView>
        <StatusBar barStyle="dark-content" />
      </View>
    );
  }

  return (
    <View style={[styles.signInScreen, { backgroundColor: t.background }]}>
      <ScrollView contentContainerStyle={styles.signInBody}>
        <View style={styles.signInBrand}>
          <Logo size={88} ring />
          <Text style={[styles.brand, { color: t.text }]}>Field Capture</Text>
          <Text style={[styles.signInSub, { color: t.textMuted }]}>
            Driver companion for field work
          </Text>
        </View>
        <Card theme={t} title="Sign in" testID="login-form">
          <Text style={[styles.fieldLabel, { color: t.text }]}>Driver ID</Text>
          <TextInput
            style={[
              styles.input,
              { color: t.text, borderColor: t.border, backgroundColor: t.card },
            ]}
            placeholder="Driver ID"
            placeholderTextColor={t.textMuted}
            autoCapitalize="none"
            autoCorrect={false}
            value={props.username}
            onChangeText={props.onUsername}
            accessibilityLabel="Driver ID"
          />
          <Text style={[styles.fieldLabel, { color: t.text }]}>Password</Text>
          <TextInput
            style={[
              styles.input,
              { color: t.text, borderColor: t.border, backgroundColor: t.card },
            ]}
            placeholder="Password"
            placeholderTextColor={t.textMuted}
            secureTextEntry
            value={props.password}
            onChangeText={props.onPassword}
            accessibilityLabel="Password"
          />
          <Button theme={t} label="Sign In" onPress={props.onSubmit} />
          {props.message !== null ? (
            <Text style={[styles.error, { color: t.danger }]}>{props.message}</Text>
          ) : null}
          <Button
            variant="secondary"
            label="Help signing in"
            onPress={() => setAux('help')}
            testID="signin-help"
          />
          <Button
            variant="secondary"
            label="View saved offline work"
            onPress={() => setAux('offline')}
            testID="signin-offline"
          />
          <Button
            variant="secondary"
            label="View SOPs"
            onPress={() => setAux('sops')}
            testID="signin-sops"
          />
          <Button
            variant="secondary"
            label="Set up permissions"
            onPress={() => setAux('permissions')}
            testID="signin-permissions"
          />
          <Text style={[styles.reassure, { color: t.textMuted }]}>
            Saved work on this phone stays safe.
          </Text>
        </Card>
      </ScrollView>
      <StatusBar barStyle="dark-content" />
    </View>
  );
}

type EvidenceView =
  | 'gallery'
  | 'camera'
  | 'photo'
  | 'receipt'
  | 'receiptform'
  | 'signature'
  | 'print'
  | 'complete';

const EVIDENCE_VIEWS: readonly { key: EvidenceView; label: string }[] = [
  { key: 'gallery', label: 'Evidence' },
  { key: 'camera', label: 'Camera' },
  { key: 'photo', label: 'Photo' },
  { key: 'receipt', label: 'Receipt' },
  { key: 'receiptform', label: 'Receipt Form' },
  { key: 'signature', label: 'Signature' },
  { key: 'print', label: 'Print' },
  { key: 'complete', label: 'Job Complete' },
];

/**
 * Evidence flow (GUI Master §12 / screens 53–61) — the per-job evidence surfaces: gallery, camera,
 * photo review, receipt + receipt form, signature, print ticket, job-complete review. GPS is NOT a
 * manual step here (item 7): location evidence is captured automatically by the geofence machinery
 * (the Location work panel / LocationValidationScreen), so the driver-facing GPS step is removed.
 * The add-evidence menu is contextual — Ticket Photo only for hybrid tickets, Customer Signature
 * only for flowback jobs. Capture surfaces are dep-free placeholders (the real capture is the
 * functional Evidence panel).
 */
function EvidenceFlow(props: {
  onExit: () => void;
  captureMethod?: TicketCaptureMethod;
  jobType?: string;
}) {
  const [v, setV] = useState<EvidenceView>('gallery');
  return (
    <View style={styles.gap}>
      <Pressable testID="evidence-flow-back" onPress={props.onExit} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Back to job</Text>
      </Pressable>
      <View style={styles.panelTabs}>
        {EVIDENCE_VIEWS.map((e) => {
          const selected = v === e.key;
          return (
            <Pressable
              key={e.key}
              testID={`evidence-${e.key}`}
              onPress={() => setV(e.key)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={[styles.chip, selected ? styles.chipSelected : null]}
            >
              <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                {e.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {v === 'gallery' && (
        <JobEvidenceScreen
          {...(props.captureMethod !== undefined ? { captureMethod: props.captureMethod } : {})}
          {...(props.jobType !== undefined ? { jobType: props.jobType } : {})}
          onAddEvidence={(key) => setV(evidenceRouteForMenuKey(key))}
          onAddPhoto={() => setV('camera')}
        />
      )}
      {v === 'camera' && (
        <CameraCaptureScreen onCapture={() => setV('photo')} onCancel={() => setV('gallery')} />
      )}
      {v === 'photo' && (
        <PhotoReviewScreen
          onUsePhoto={() => setV('gallery')}
          onRetake={() => setV('camera')}
          onDelete={() => setV('gallery')}
        />
      )}
      {v === 'receipt' && (
        <EvidenceReceiptCaptureScreen
          onCaptureReceipt={() => setV('receiptform')}
          onChooseFromPhotos={() => setV('receiptform')}
          onSkipPhoto={() => setV('receiptform')}
        />
      )}
      {v === 'receiptform' && (
        <ReceiptFormScreen onAddPhoto={() => setV('receipt')} onSave={() => setV('gallery')} />
      )}
      {v === 'signature' && <SignatureCaptureScreen onSave={() => setV('gallery')} />}
      {v === 'print' && <PrintTicketScreen />}
      {v === 'complete' && <JobCompleteReviewScreen />}
    </View>
  );
}

/** Driver Pre-Trip DVIR flow (GUI Master §7 / screens 12–17). */
function PreTripFlow(props: {
  onExit: () => void;
  onDone: () => void;
  onSubmit: (payload: { signature: SignatureValue; signerName: string }) => Promise<SubmitResult>;
  driverName?: string;
}) {
  const [r, setR] = useState<
    'overview' | 'section' | 'defect' | 'review' | 'signature' | 'complete'
  >('overview');
  const [msg, setMsg] = useState<SubmitResult | null>(null);
  // The driver's real, entered inspection — drives Review counts and the Complete defect summary.
  const [summary, setSummary] = useState<InspectionSummary | null>(null);
  const back = () =>
    r === 'overview' ? props.onExit() : r === 'defect' ? setR('section') : setR('overview');
  const defectCount = summary?.defectCount ?? 0;
  return (
    <View style={styles.gap}>
      <Pressable testID="pretrip-back" onPress={back} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Back</Text>
      </Pressable>
      {msg !== null ? (
        <Text style={msg.ok ? styles.flowOk : styles.error}>{msg.message}</Text>
      ) : null}
      {r === 'overview' && <PreTripOverviewScreen onBeginInspection={() => setR('section')} />}
      {r === 'section' && (
        <PreTripSectionScreen
          onOpenDefect={() => setR('defect')}
          onContinue={(s) => {
            setSummary(s);
            setR('review');
          }}
        />
      )}
      {r === 'defect' && (
        <DefectDetailScreen onSaveDefect={() => setR('section')} onCancel={() => setR('section')} />
      )}
      {r === 'review' && (
        <PreTripReviewScreen
          onContinueToSignature={() => setR('signature')}
          {...(summary !== null
            ? {
                truckChecked: summary.truckChecked,
                truckTotal: summary.truckTotal,
                trailerChecked: summary.trailerChecked,
                trailerTotal: summary.trailerTotal,
                defectCount: summary.defectCount,
              }
            : {})}
        />
      )}
      {r === 'signature' && (
        <PreTripSignatureScreen
          certificationText={fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT}
          {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
          onCompletePreTrip={(payload) => {
            void props
              .onSubmit(payload)
              .then((result) => {
                setMsg(result);
                if (result.ok) setR('complete');
              })
              .catch(() => setMsg(signatureCaptureFailure));
          }}
        />
      )}
      {r === 'complete' && (
        <PreTripCompleteScreen
          hasDefects={defectCount > 0}
          defectCount={defectCount}
          onStartNextJob={props.onDone}
        />
      )}
    </View>
  );
}

/** End Day + Post-Trip DVIR flow (GUI Master §8 / screens 18–23). */
function PostTripFlow(props: {
  onExit: () => void;
  onPunchOut: () => void;
  onSubmit: (payload: { signature: SignatureValue; signerName: string }) => Promise<SubmitResult>;
  driverName?: string;
}) {
  const [r, setR] = useState<
    'endday' | 'overview' | 'section' | 'review' | 'signature' | 'complete'
  >('endday');
  const [msg, setMsg] = useState<SubmitResult | null>(null);
  const back = () => (r === 'endday' ? props.onExit() : setR('endday'));
  return (
    <View style={styles.gap}>
      <Pressable testID="posttrip-back" onPress={back} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Back</Text>
      </Pressable>
      {msg !== null ? (
        <Text style={msg.ok ? styles.flowOk : styles.error}>{msg.message}</Text>
      ) : null}
      {r === 'endday' && (
        <EndDayReviewScreen
          onStartPostTrip={() => setR('overview')}
          onContactDispatch={callDispatch}
        />
      )}
      {r === 'overview' && <PostTripOverviewScreen onBegin={() => setR('section')} />}
      {r === 'section' && <PostTripSectionScreen onContinue={() => setR('review')} />}
      {r === 'review' && <PostTripReviewScreen onContinue={() => setR('signature')} />}
      {r === 'signature' && (
        <PostTripSignatureScreen
          certificationText={fieldwork.DVIR_POSTTRIP_CERTIFICATION_TEXT}
          {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
          onComplete={(payload) => {
            void props
              .onSubmit(payload)
              .then((result) => {
                setMsg(result);
                if (result.ok) setR('complete');
              })
              .catch(() => setMsg(signatureCaptureFailure));
          }}
        />
      )}
      {r === 'complete' && <PostTripCompleteScreen onPunchOut={props.onPunchOut} />}
    </View>
  );
}

type DayRoute = 'home' | 'pretrip' | 'posttrip';

/**
 * Day tab (GUI Master §6–8) — the Day Dashboard plus the in-app inspection flows it launches
 * (Pre-Trip, End Day / Post-Trip). Punching in/out is NOT here: it happens only at the physical
 * Field Time Terminal, so the dashboard shows punch status read-only and offers no punch button.
 */
function DayTab(props: {
  punchedIn: boolean;
  clockedInSince?: string;
  statusDetail?: string;
  jobsCount: number;
  needsReview: number;
  pendingSync: number;
  checking: boolean;
  onOpenJobs: () => void;
  onRefresh: () => void;
  onSubmitPreTrip: (payload: {
    signature: SignatureValue;
    signerName: string;
  }) => Promise<SubmitResult>;
  onSubmitPostTrip: (payload: {
    signature: SignatureValue;
    signerName: string;
  }) => Promise<SubmitResult>;
  driverName?: string;
}) {
  const [route, setRoute] = useState<DayRoute>('home');
  if (route === 'pretrip')
    return (
      <PreTripFlow
        onExit={() => setRoute('home')}
        onDone={props.onOpenJobs}
        onSubmit={props.onSubmitPreTrip}
        {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
      />
    );
  if (route === 'posttrip')
    return (
      <PostTripFlow
        onExit={() => setRoute('home')}
        onPunchOut={() => setRoute('home')}
        onSubmit={props.onSubmitPostTrip}
        {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
      />
    );
  // Punching is terminal-only: inspections unlock only once the Hub clock gate says punched-in, and
  // when not punched in the primary action re-checks status with the Hub rather than offering a punch.
  return (
    <DayDashboardScreen
      punchedIn={props.punchedIn}
      {...(props.clockedInSince !== undefined ? { clockedInSince: props.clockedInSince } : {})}
      {...(props.statusDetail !== undefined ? { statusDetail: props.statusDetail } : {})}
      jobsCount={props.jobsCount}
      needsReview={props.needsReview}
      pendingSync={props.pendingSync}
      timeline={buildWorkdayTimeline({ punchedIn: props.punchedIn, jobsCount: props.jobsCount })}
      checking={props.checking}
      primaryLabel={props.punchedIn ? 'Open Jobs' : 'Check Punch-In Status'}
      onPrimary={props.punchedIn ? props.onOpenJobs : props.onRefresh}
      onOpenJobs={props.onOpenJobs}
      onRefresh={props.onRefresh}
      {...(props.punchedIn ? { onStartPreTrip: () => setRoute('pretrip') } : {})}
      {...(props.punchedIn ? { onStartPostTrip: () => setRoute('posttrip') } : {})}
    />
  );
}

/**
 * JHA/JSA flow (GUI Master §10 / screens 33–43) — the per-job safety review as an 11-step guided
 * wizard reached from Job Overview. A shared back link steps backward (or exits to the job at the
 * first step); Complete hands off to the Field Ticket flow.
 */
function JhaFlow(props: {
  onExit: () => void;
  onStartFieldTicket: () => void;
  onSubmit: (payload: { signatures: SignatureSubmitPayload[] }) => Promise<SubmitResult>;
  driverName?: string;
}) {
  const [step, setStep] = useState(0);
  const [msg, setMsg] = useState<SubmitResult | null>(null);
  // The signatures captured on the Signatures screen (driver first) — held until the Review screen
  // commits, which is when the durable JHA record is actually built and submitted.
  const [signatures, setSignatures] = useState<SignatureSubmitPayload[]>([]);
  const next = () => setStep((s) => s + 1);
  const back = () => (step === 0 ? props.onExit() : setStep((s) => s - 1));
  return (
    <View style={styles.gap}>
      <Pressable testID="jha-back" onPress={back} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Back</Text>
      </Pressable>
      {msg !== null ? (
        <Text style={msg.ok ? styles.flowOk : styles.error}>{msg.message}</Text>
      ) : null}
      {step === 0 && <JhaOverviewScreen onBegin={next} />}
      {step === 1 && <JhaJobAndSiteScreen onNext={next} />}
      {step === 2 && <JhaEmergencyInfoScreen onNext={next} />}
      {step === 3 && <JhaPreJobSafetyScreen onNext={next} />}
      {step === 4 && <JhaPpeScreen onNext={next} />}
      {step === 5 && <JhaHazardsScreen onNext={next} />}
      {step === 6 && <JhaJobStepsScreen onNext={next} />}
      {step === 7 && <JhaStopWorkScreen onAcknowledge={next} />}
      {step === 8 && (
        <JhaSignaturesScreen
          certificationText={fieldwork.JHA_CERTIFICATION_TEXT}
          onContinue={(payload) => {
            setSignatures(payload.signatures);
            next();
          }}
          {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
        />
      )}
      {step === 9 && (
        <JhaReviewScreen
          onComplete={() => {
            void props
              .onSubmit({ signatures })
              .then((r) => {
                setMsg(r);
                if (r.ok) setStep(10);
              })
              .catch(() => setMsg(signatureCaptureFailure));
          }}
        />
      )}
      {step === 10 && <JhaCompleteScreen onStartFieldTicket={props.onStartFieldTicket} />}
    </View>
  );
}

type SopRoute = 'list' | 'search' | 'reader' | 'ack';

/**
 * SOP browser (GUI Master §13/§22) — SOPs are just SOPs: ONE plain list (no "Emergency" category;
 * emergency procedures live in the same list), with Search, the SOP Reader, and Acknowledgement.
 * It is intentionally auth-free so required safety procedures can be read from the sign-in screen.
 */
function SopBrowser() {
  const [route, setRoute] = useState<SopRoute>('list');
  const openReader = () => setRoute('reader');
  if (route === 'list' || route === 'search') {
    const searching = route === 'search';
    return (
      <View style={styles.gap}>
        <Button
          variant="secondary"
          label={searching ? '‹ Browse all SOPs' : 'Search SOPs'}
          onPress={() => setRoute(searching ? 'list' : 'search')}
          testID="sop-search-toggle"
        />
        {searching ? (
          <SopSearchScreen onOpenSop={openReader} />
        ) : (
          <RequiredDriverSopsScreen title="SOPs" onOpenSop={openReader} />
        )}
      </View>
    );
  }
  return (
    <View style={styles.gap}>
      <Pressable testID="sop-back" onPress={() => setRoute('list')} accessibilityRole="button">
        <Text style={styles.backLink}>‹ SOPs</Text>
      </Pressable>
      {route === 'reader' && (
        <SopReaderScreen
          onAcknowledge={() => setRoute('ack')}
          onBackToJob={() => setRoute('list')}
        />
      )}
      {route === 'ack' && (
        <SopAcknowledgementScreen
          onAcknowledge={() => setRoute('list')}
          onCancel={() => setRoute('reader')}
        />
      )}
    </View>
  );
}

function SopsTab() {
  return <SopBrowser />;
}

type SyncRoute = 'home' | 'pending' | 'failed' | 'detail' | 'complete';

/**
 * Sync tab (GUI Master §14) — plain-English saved/synced status. Home shows the real outbox rollup
 * (pending / failed / synced counts from the durable stores); View Pending / View Failed drill into
 * the item lists. No payloads, queues, acks, or server versions (§20).
 */
function SyncTab(props: {
  pendingCount: number;
  failedCount: number;
  syncedCount: number;
  offline: boolean;
  lastSyncedAt: string;
  syncing: boolean;
  pendingItems: readonly SyncItem[];
  onSyncNow: () => void;
}) {
  const [route, setRoute] = useState<SyncRoute>('home');
  const overall: SyncOverallState = props.offline
    ? 'Offline Mode'
    : props.failedCount > 0
      ? 'Sync Failed'
      : props.pendingCount > 0
        ? 'Pending Sync'
        : props.syncedCount > 0
          ? 'All Work Synced'
          : 'Saved on Phone';
  if (route === 'home') {
    return (
      <SyncHomeScreen
        overallState={overall}
        pendingCount={props.pendingCount}
        failedCount={props.failedCount}
        syncedCount={props.syncedCount}
        lastSyncedAt={props.lastSyncedAt}
        syncing={props.syncing}
        onSyncNow={props.onSyncNow}
        onViewPending={() => setRoute('pending')}
        onViewFailed={() => setRoute('failed')}
      />
    );
  }
  return (
    <View style={styles.gap}>
      <Pressable testID="sync-back" onPress={() => setRoute('home')} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Sync</Text>
      </Pressable>
      {route === 'pending' && (
        <PendingSyncItemsScreen
          items={props.pendingItems}
          syncing={props.syncing}
          onSyncNow={props.onSyncNow}
          onOpenItem={() => setRoute('detail')}
        />
      )}
      {route === 'failed' && (
        <SyncFailedItemsScreen
          items={[]}
          onRetry={() => undefined}
          onViewDetails={() => setRoute('detail')}
          onContactSupport={() => undefined}
        />
      )}
      {route === 'detail' && (
        <View style={styles.gap}>
          <SyncItemDetailScreen />
          <Button label="Mark as synced" variant="secondary" onPress={() => setRoute('complete')} />
        </View>
      )}
      {route === 'complete' && <SyncCompleteScreen onDone={() => setRoute('home')} />}
    </View>
  );
}

type AdminRoute =
  | 'lock'
  | 'dash'
  | 'environment'
  | 'sync'
  | 'printer'
  | 'logs'
  | 'supervisor'
  | 'mechanic'
  | 'override';

/**
 * Admin Mode (GUI Master §16 / screens 84–92) — the protected, non-driver area: PIN lock →
 * dashboard → diagnostics (environment, sync, printer, logs) and the supervisor/mechanic defect
 * chain. This is the ONLY place technical detail is shown, and only after the lock. Diagnostic
 * actions are presentational here; the real device actions wire in as those slices land.
 */
function AdminFlow(props: { envInfo: EnvironmentInfo; onExit: () => void }) {
  const [r, setR] = useState<AdminRoute>('lock');
  if (r === 'lock') {
    return (
      <View style={styles.gap}>
        <Pressable testID="admin-exit" onPress={props.onExit} accessibilityRole="button">
          <Text style={styles.backLink}>‹ Back</Text>
        </Pressable>
        {/* Dev convenience: any PIN unlocks. Real PIN/role gating is Hub-side. */}
        <AdminModeLockScreen onUnlock={() => setR('dash')} onCancel={props.onExit} />
      </View>
    );
  }
  if (r === 'dash') {
    return (
      <View style={styles.gap}>
        <Pressable testID="admin-lock" onPress={() => setR('lock')} accessibilityRole="button">
          <Text style={styles.backLink}>‹ Lock</Text>
        </Pressable>
        <AdminDashboardScreen
          onLockAdmin={props.onExit}
          onOpenSection={(key) => {
            if (key === 'sync') setR('sync');
            else if (key === 'printer') setR('printer');
            else if (key === 'logs') setR('logs');
            else if (key === 'role') setR('supervisor');
            else setR('environment');
          }}
        />
      </View>
    );
  }
  return (
    <View style={styles.gap}>
      <Pressable testID="admin-back" onPress={() => setR('dash')} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Admin</Text>
      </Pressable>
      {r === 'environment' && <EnvironmentDetailsScreen environment={props.envInfo} />}
      {r === 'sync' && <SyncDiagnosticsScreen />}
      {r === 'printer' && <PrinterDiagnosticsScreen />}
      {r === 'logs' && <LogsExportScreen />}
      {r === 'supervisor' && <SupervisorDefectReviewScreen onDecision={() => setR('mechanic')} />}
      {r === 'mechanic' && <MechanicDefectResolutionScreen onSelect={() => setR('override')} />}
      {r === 'override' && <SupervisorOverrideScreen onApply={() => setR('dash')} />}
    </View>
  );
}

type MoreRoute =
  | 'home'
  | 'account'
  | 'language'
  | 'theme'
  | 'textsize'
  | 'printer'
  | 'help'
  | 'contact'
  | 'signout'
  | 'adminlock';

const DEFAULT_PRINTER_NAME = 'PT-210';

type PrinterUiState = {
  name: string;
  connected: boolean;
  connectionMessage: string;
  actionMessage: string | undefined;
  actionTone: Tone;
  reconnecting: boolean;
  printing: boolean;
};

function defaultPrinterUiState(): PrinterUiState {
  return {
    name: DEFAULT_PRINTER_NAME,
    connected: false,
    connectionMessage:
      'Printer not connected. Reconnect when you are near it to print field tickets.',
    actionMessage: undefined,
    actionTone: 'info',
    reconnecting: false,
    printing: false,
  };
}

function printerIsReady(status: Pt210Status): boolean {
  return status.connected && status.ready;
}

function printerName(status: Pt210Status, fallback = DEFAULT_PRINTER_NAME): string {
  return status.deviceName ?? fallback;
}

function printerConnectionMessage(name: string, connected: boolean): string {
  return connected
    ? `${name} is connected and ready for field tickets.`
    : 'Printer not connected. Reconnect when you are near it to print field tickets.';
}

function printerStatusActionMessage(
  status: Pt210Status,
  readyMessage: string | undefined,
): string | undefined {
  if (readyMessage === undefined) return undefined;
  if (printerIsReady(status)) return readyMessage;
  const name = printerName(status);
  if (status.connected) return `${name} is connected but not ready to print yet.`;
  return status.message ?? 'Printer is not connected yet.';
}

/**
 * More tab (GUI Master §15/§16) — a self-contained settings stack: home menu → the nine settings
 * sub-pages, plus the Admin lock that gates Environment Details (where the technical hub/env info
 * lives, per §20 it never appears on driver screens). Settings selections are local for now; sign-
 * out routes to the real controller logout and preserves unsynced work.
 */
function MoreTab(props: {
  onSignOut: () => void | Promise<void>;
  onOpenSops: () => void;
  punchedIn: boolean;
  syncSummary: string;
  syncTone: Tone;
  driverName?: string;
  driverRole?: string;
  department?: string;
  employeeId?: string;
  phone?: string;
  assignedYard?: string;
  defaultTruck?: string;
  defaultTrailer?: string;
  envInfo: EnvironmentInfo;
}) {
  const [route, setRoute] = useState<MoreRoute>('home');
  const [textSize, setTextSize] = useState<TextSizeChoice>('default');
  const [highContrast, setHighContrast] = useState(false);
  const [reduceMotion, setReduceMotion] = useState(false);
  const printerTransportRef = useRef<Pt210PrinterTransport | null>(null);
  const [printerUi, setPrinterUi] = useState<PrinterUiState>(() => defaultPrinterUiState());

  const printerTransport = useCallback(() => {
    printerTransportRef.current ??= new Pt210PrinterTransport();
    return printerTransportRef.current;
  }, []);

  const applyPrinterStatus = useCallback((status: Pt210Status, actionMessage?: string): boolean => {
    const connected = printerIsReady(status);
    const name = printerName(status);
    setPrinterUi((prev) => ({
      ...prev,
      name,
      connected,
      connectionMessage: printerConnectionMessage(name, connected),
      actionMessage: printerStatusActionMessage(status, actionMessage),
      actionTone: connected ? 'success' : 'warning',
    }));
    return connected;
  }, []);

  const refreshPrinterStatus = useCallback(async () => {
    try {
      const status = await printerTransport().status({ timeoutMs: 3_000 });
      applyPrinterStatus(status);
    } catch (error) {
      const normalized = normalizePt210NativeError(error);
      setPrinterUi((prev) => ({
        ...prev,
        connected: false,
        connectionMessage: printerConnectionMessage(prev.name, false),
        actionMessage:
          normalized.code === 'printer-not-implemented'
            ? 'This app build does not include PT-210 printing.'
            : normalized.message,
        actionTone: 'warning',
      }));
    }
  }, [applyPrinterStatus, printerTransport]);

  const connectPrinterToPt210 = useCallback(async (): Promise<boolean> => {
    setPrinterUi((prev) => ({
      ...prev,
      reconnecting: true,
      actionMessage: 'Looking for your printer…',
      actionTone: 'info',
    }));

    try {
      const transport = printerTransport();
      try {
        const current = await transport.status({ timeoutMs: 3_000 });
        if (applyPrinterStatus(current, `${printerName(current)} is already connected.`)) {
          return true;
        }
      } catch {
        // Continue into reconnect/discovery. The final catch below surfaces actionable failures.
      }

      try {
        const reconnected = await transport.reconnect({ timeoutMs: 10_000 });
        if (applyPrinterStatus(reconnected, `Connected to ${printerName(reconnected)}.`)) {
          return true;
        }
      } catch {
        // A fresh app launch has no prior device id, so fall back to discovery.
      }

      const found = await transport.discover({ timeoutMs: 10_000, includeUnpaired: true });
      const device = found[0];
      if (device === undefined) {
        setPrinterUi((prev) => ({
          ...prev,
          connected: false,
          connectionMessage: printerConnectionMessage(prev.name, false),
          actionMessage: 'No PT-210 printer found nearby. Make sure it is on and near this phone.',
          actionTone: 'warning',
        }));
        return false;
      }

      await transport.connect(device.deviceId);
      const connected = await transport.status({ timeoutMs: 3_000 });
      const ready = printerIsReady(connected);
      const name = printerName(connected, device.name);
      setPrinterUi((prev) => ({
        ...prev,
        name,
        connected: ready,
        connectionMessage: printerConnectionMessage(name, ready),
        actionMessage: ready ? `Connected to ${name}.` : `${name} was found but is not ready yet.`,
        actionTone: ready ? 'success' : 'warning',
      }));
      return ready;
    } catch (error) {
      const normalized = normalizePt210NativeError(error);
      setPrinterUi((prev) => ({
        ...prev,
        connected: false,
        connectionMessage: printerConnectionMessage(prev.name, false),
        actionMessage:
          normalized.code === 'printer-not-implemented'
            ? 'This app build does not include PT-210 printing.'
            : normalized.message,
        actionTone: 'danger',
      }));
      return false;
    } finally {
      setPrinterUi((prev) => ({ ...prev, reconnecting: false }));
    }
  }, [applyPrinterStatus, printerTransport]);

  const printPrinterTestPage = useCallback(async () => {
    setPrinterUi((prev) => ({
      ...prev,
      printing: true,
      actionMessage: 'Printing test page…',
      actionTone: 'info',
    }));
    try {
      const transport = printerTransport();
      if (!transport.isConnected()) {
        const connected = await connectPrinterToPt210();
        if (!connected) return;
      }
      await transport.writeBytes(createPt210SignatureBitmapTest());
      try {
        const status = await transport.status({ timeoutMs: 3_000 });
        applyPrinterStatus(status, 'Test page sent to printer.');
      } catch {
        setPrinterUi((prev) => ({
          ...prev,
          connected: true,
          connectionMessage: printerConnectionMessage(prev.name, true),
          actionMessage: 'Test page sent to printer.',
          actionTone: 'success',
        }));
      }
    } catch (error) {
      const normalized = normalizePt210NativeError(error);
      setPrinterUi((prev) => ({
        ...prev,
        actionMessage: normalized.message,
        actionTone: 'danger',
      }));
    } finally {
      setPrinterUi((prev) => ({ ...prev, printing: false }));
    }
  }, [applyPrinterStatus, connectPrinterToPt210, printerTransport]);

  const reconnectPrinter = useCallback(async () => {
    await connectPrinterToPt210();
  }, [connectPrinterToPt210]);

  useEffect(() => {
    if (route !== 'printer') return;
    refreshPrinterStatus().catch(() => undefined);
  }, [refreshPrinterStatus, route]);

  if (route === 'home') {
    return (
      <MoreHomeScreen
        syncSummary={props.syncSummary}
        syncTone={props.syncTone}
        {...(props.driverName !== undefined ? { driverName: props.driverName } : {})}
        {...(props.driverRole !== undefined ? { driverRole: props.driverRole } : {})}
        {...(props.department !== undefined ? { company: props.department } : {})}
        onOpenAccount={() => setRoute('account')}
        onOpenTheme={() => setRoute('theme')}
        onOpenTextSize={() => setRoute('textsize')}
        onOpenPrinter={() => setRoute('printer')}
        onOpenHelp={() => setRoute('help')}
        onOpenContactDispatch={() => setRoute('contact')}
        onOpenAdminMode={() => setRoute('adminlock')}
        onSignOut={() => setRoute('signout')}
      />
    );
  }
  if (route === 'adminlock') {
    return <AdminFlow envInfo={props.envInfo} onExit={() => setRoute('home')} />;
  }
  return (
    <View style={styles.gap}>
      <Pressable testID="more-back" onPress={() => setRoute('home')} accessibilityRole="button">
        <Text style={styles.backLink}>‹ Back</Text>
      </Pressable>
      {route === 'account' && (
        <AccountScreen
          {...(props.driverName !== undefined ? { name: props.driverName } : {})}
          {...(props.driverRole !== undefined ? { role: props.driverRole } : {})}
          {...(props.employeeId !== undefined ? { employeeId: props.employeeId } : {})}
          {...(props.phone !== undefined ? { phone: props.phone } : {})}
          {...(props.assignedYard !== undefined ? { assignedYard: props.assignedYard } : {})}
          {...(props.defaultTruck !== undefined ? { defaultTruck: props.defaultTruck } : {})}
          {...(props.defaultTrailer !== undefined ? { defaultTrailer: props.defaultTrailer } : {})}
        />
      )}
      {route === 'theme' && <ThemeScreen />}
      {route === 'textsize' && (
        <TextSizeScreen
          selectedSize={textSize}
          highContrast={highContrast}
          reduceMotion={reduceMotion}
          onSelectSize={setTextSize}
          onToggleHighContrast={setHighContrast}
          onToggleReduceMotion={setReduceMotion}
        />
      )}
      {route === 'printer' && (
        <PrinterSettingsScreen
          printerName={printerUi.name}
          connected={printerUi.connected}
          connectionMessage={printerUi.connectionMessage}
          reconnecting={printerUi.reconnecting}
          printing={printerUi.printing}
          {...(printerUi.actionMessage !== undefined
            ? { actionMessage: printerUi.actionMessage, actionTone: printerUi.actionTone }
            : {})}
          onReconnect={reconnectPrinter}
          onPrintTestPage={printPrinterTestPage}
        />
      )}
      {route === 'help' && (
        <HelpSupportScreen
          onViewSops={props.onOpenSops}
          onEmergencyContacts={() => setRoute('contact')}
        />
      )}
      {route === 'contact' && <ContactDispatchScreen />}
      {route === 'signout' && (
        <SignOutConfirmScreen
          punchedIn={props.punchedIn}
          onCancel={() => setRoute('home')}
          onConfirmSignOut={() => void props.onSignOut()}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  splash: {
    flex: 1,
    backgroundColor: theme.background,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.md,
    padding: spacing.xl,
  },
  splashCard: {
    alignSelf: 'stretch',
    gap: spacing.md,
    marginTop: spacing.md,
  },
  splashMeta: {
    fontSize: typeScale.body,
    color: theme.textMuted,
  },
  brand: {
    fontSize: typeScale.title,
    fontWeight: '800',
    color: theme.text,
  },
  shell: {
    flex: 1,
    backgroundColor: theme.background,
    paddingTop: 44, // status-bar inset (no safe-area native module in this build)
  },
  headerMeta: {
    fontSize: typeScale.caption,
    color: theme.textMuted,
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.xs,
  },
  body: {
    flex: 1,
  },
  bodyInner: {
    padding: spacing.lg,
    gap: spacing.md,
    paddingBottom: spacing.xl,
  },
  gap: {
    gap: spacing.md,
  },
  tabH1: {
    fontSize: typeScale.title,
    fontWeight: '800',
    color: theme.text,
  },
  tabBody: {
    fontSize: typeScale.body,
    lineHeight: 23,
    color: theme.text,
  },
  backLink: {
    fontSize: typeScale.body,
    color: theme.primary,
    fontWeight: '700',
  },
  panelTabs: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
    alignItems: 'center',
  },
  chip: {
    minHeight: 32,
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.card,
  },
  chipSelected: {
    backgroundColor: theme.primary,
    borderColor: theme.primary,
  },
  chipText: {
    fontSize: typeScale.label,
    color: theme.textMuted,
    fontWeight: '600',
  },
  chipTextSelected: {
    color: theme.onPrimary,
  },
  tabBar: {
    flexDirection: 'row',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
    backgroundColor: theme.card,
  },
  tabItem: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 14,
  },
  tabLabel: {
    fontSize: typeScale.label,
    color: theme.textMuted,
    fontWeight: '600',
  },
  tabLabelActive: {
    color: theme.primary,
    fontWeight: '800',
  },
  // Sign In
  signInScreen: {
    flex: 1,
    backgroundColor: theme.background,
    paddingTop: 44,
  },
  signInBody: {
    padding: spacing.xl,
    gap: spacing.xl,
    justifyContent: 'center',
    flexGrow: 1,
  },
  signInBrand: {
    alignItems: 'center',
    gap: spacing.sm,
  },
  signInSub: {
    fontSize: typeScale.body,
    color: theme.textMuted,
  },
  fieldLabel: {
    fontSize: typeScale.label,
    color: theme.textMuted,
    fontWeight: '600',
  },
  input: {
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 12,
    fontSize: typeScale.body,
    color: theme.text,
    backgroundColor: theme.card,
  },
  reassure: {
    fontSize: typeScale.caption,
    color: theme.textMuted,
  },
  // Gate
  error: {
    fontSize: typeScale.label,
    color: theme.danger,
  },
  flowOk: {
    fontSize: typeScale.label,
    color: theme.success,
    fontWeight: '700',
  },
});
