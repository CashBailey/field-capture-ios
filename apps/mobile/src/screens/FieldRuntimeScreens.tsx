import { fieldwork, printer, sync } from '@fieldcapture/contracts';
import { useState, useMemo } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import {
  createPt210SignatureBitmapTest,
  createPt210TestReceipt,
  loadPt210NativeBinding,
  normalizePt210NativeError,
  type Pt210DiscoveredDevice,
  type Pt210NativeBinding,
} from '../adapters/printer';
import {
  SignatureField,
  StatusBadge,
  type SignatureValue,
  type Tone,
  useTheme,
  type Theme,
} from '../design';
import {
  filterAssignments,
  rankTodayAssignments,
  INBOX_FILTERS,
  INBOX_FILTER_LABELS,
  SR_SYNC_STATE_LABELS,
  RECEIPT_TYPES,
  SYNC_CENTER_LABELS,
  SYNC_CENTER_ORDER,
  TICKET_CAPTURE_METHODS,
  fieldWorkGateLockReason,
  signatureBytes,
  type BlobUploadStore,
  type FieldFormStore,
  type FieldTicketDraft,
  type FieldTicketDraftStore,
  type FieldTicketDetail,
  type FieldTicketTimes,
  type FtIn,
  type GaugeReading,
  type TankGauge,
  type TicketLineItem,
  type FieldWorkGate,
  type TicketCaptureMethod,
  type HubAssignment,
  type InboxFilter,
  type LocationEvidenceStore,
  type ReceiptDraft,
  type ReceiptDraftStore,
  type ReceiptType,
  type SrSyncState,
  type SyncCenterSummary,
} from '../domain';
import type {
  CaptureFlow,
  CaptureSource,
  FieldWorkflowService,
  PrintRuntime,
  UploadEngine,
} from '../runtime';

type Message = { kind: 'ok' | 'warn' | 'error'; text: string } | null;

function ids(value: string): string[] {
  return value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function formatWorkflowResult(
  result:
    | ReturnType<FieldWorkflowService['saveDraft']>
    | ReturnType<FieldWorkflowService['completeForm']>
    | ReturnType<FieldWorkflowService['submitForm']>,
  ok: string,
): Message {
  if (result.status === 'ok') return { kind: 'ok', text: ok };
  if (result.status === 'locked') return { kind: 'warn', text: `Locked: ${result.reason}` };
  if (result.status === 'invalid') return { kind: 'error', text: result.errors.join(', ') };
  if (result.status === 'frozen') return { kind: 'warn', text: `Frozen: ${result.recordStatus}` };
  return { kind: 'error', text: `Missing form ${result.formId}` };
}

function ActionButton(props: {
  testID: string;
  label: string;
  onPress: () => void | Promise<void>;
}) {
  const { styles } = useFieldStyles();
  return (
    <Pressable testID={props.testID} style={styles.button} onPress={props.onPress}>
      <Text style={styles.buttonText}>{props.label}</Text>
    </Pressable>
  );
}

function MessageLine({ message }: { message: Message }) {
  const { styles } = useFieldStyles();
  if (message === null) return null;
  const style =
    message.kind === 'ok' ? styles.ok : message.kind === 'warn' ? styles.warn : styles.error;
  return (
    <Text style={style} testID="runtime-message">
      {message.text}
    </Text>
  );
}

function gateLabel(gate: FieldWorkGate): string {
  return gate.state === 'unlocked'
    ? 'Field work unlocked'
    : `Field work locked: ${fieldWorkGateLockReason(gate)}`;
}

function fieldValue(value: string | undefined): string {
  return value === undefined || value.length === 0 ? 'unknown' : value;
}

const WORKFLOW_STEP_LABELS: Record<fieldwork.WorkflowStepType, string> = {
  pre_trip_dvir: 'pre-trip DVIR',
  jha: 'JHA/JSA per SR',
  post_trip_dvir: 'post-trip DVIR',
};

/** Map an SR status to a badge tone (spec 8.6). Color reinforces; the StatusBadge label carries it. */
function assignmentStatusTone(status: string): Tone {
  switch (status) {
    case 'assigned':
    case 'in_progress':
      return 'info';
    case 'on_hold':
      return 'warning';
    case 'completed':
      return 'success';
    case 'cancelled':
      return 'danger';
    default:
      return 'neutral';
  }
}

function workflowLabel(assignment: HubAssignment): string {
  const req = assignment.details?.workflowRequirements;
  if (req === undefined) return 'Workflow none configured';
  const labels = req.requiredSteps.map((step) => WORKFLOW_STEP_LABELS[step]);
  return labels.length === 0 ? 'Workflow none configured' : `Workflow ${labels.join(', ')}`;
}

export function AssignmentDetailScreen(props: {
  assignment?: HubAssignment;
  syncState?: SrSyncState;
}) {
  const { styles } = useFieldStyles();
  const assignment = props.assignment;
  if (assignment === undefined) {
    return (
      <View style={styles.section} testID="assignment-detail">
        <Text style={styles.heading}>Assignment</Text>
        <Text style={styles.warn}>No assignment selected</Text>
      </View>
    );
  }
  const details = assignment.details;
  const wellNames = details?.wells?.map((well) => well.name).join(', ');
  const srNo = details?.requestNo ?? assignment.serviceRequestId;
  const status = details?.status ?? 'unknown';
  return (
    <View style={styles.section} testID="assignment-detail">
      <View style={styles.row}>
        <Text style={styles.heading}>{`SR ${srNo}`}</Text>
        <StatusBadge label={status} tone={assignmentStatusTone(status)} testID="detail-status" />
      </View>
      {props.syncState !== undefined ? (
        <Text style={styles[SR_SYNC_STATE_STYLE[props.syncState]]} testID="detail-sync">
          {`Sync: ${SR_SYNC_STATE_LABELS[props.syncState]}`}
        </Text>
      ) : null}
      <Text style={styles.meta}>{`Customer ${fieldValue(details?.customer?.name)}`}</Text>
      <Text style={styles.meta}>{`Lease ${fieldValue(details?.lease?.name)}`}</Text>
      <Text style={styles.meta}>{`Wells ${fieldValue(wellNames)}`}</Text>
      <Text style={styles.meta}>{`Material ${fieldValue(details?.material)}`}</Text>
      <Text style={styles.meta}>{`Disposal ${fieldValue(details?.disposalSite?.name)}`}</Text>
      <Text style={styles.meta}>{`Vehicle ${fieldValue(details?.vehicle?.name)}`}</Text>
      <Text style={styles.meta}>{`Trailer ${fieldValue(details?.trailer?.name)}`}</Text>
      <Text style={styles.meta}>{`Job type ${fieldValue(details?.jobType?.name)}`}</Text>
      <Text style={styles.meta}>{workflowLabel(assignment)}</Text>
      <Text style={styles.meta}>
        {`Snapshot ${assignment.snapshotHash} · Server version ${
          assignment.latestServerVersion ?? 'unknown'
        }`}
      </Text>
    </View>
  );
}

// Per-SR sync state → which existing text style conveys urgency (text label always present, so
// this is never color-alone — spec 8.6).
const SR_SYNC_STATE_STYLE: Record<SrSyncState, 'ok' | 'warn' | 'error' | 'meta'> = {
  'no-local-work': 'meta',
  synced: 'ok',
  'needs-sync': 'warn',
  'needs-review': 'error',
};

function AssignmentCard(props: {
  assignment: HubAssignment;
  syncState: SrSyncState;
  onPress?: () => void;
}) {
  const { styles } = useFieldStyles();
  const { assignment, syncState } = props;
  const d = assignment.details;
  const srNo = d?.requestNo ?? assignment.serviceRequestId;
  const wells = d?.wells?.map((well) => well.name).join(', ');
  const status = d?.status ?? 'unknown';
  return (
    <Pressable
      testID={`assignment-card-${assignment.serviceRequestId}`}
      style={styles.card}
      onPress={props.onPress}
      disabled={props.onPress === undefined}
      accessibilityRole="button"
      accessibilityLabel={`Service request ${srNo}, status ${status}, ${SR_SYNC_STATE_LABELS[syncState]}`}
    >
      <View style={styles.row}>
        <Text style={styles.heading}>{`SR ${srNo}`}</Text>
        <StatusBadge
          label={status}
          tone={assignmentStatusTone(status)}
          testID={`status-${assignment.serviceRequestId}`}
        />
      </View>
      <Text style={styles.meta}>{`Customer ${fieldValue(d?.customer?.name)}`}</Text>
      <Text style={styles.meta}>{`Lease ${fieldValue(d?.lease?.name)}`}</Text>
      <Text style={styles.meta}>{`Wells ${fieldValue(wells)}`}</Text>
      <Text style={styles.meta}>{`Material ${fieldValue(d?.material)}`}</Text>
      <Text style={styles.meta}>{`Disposal ${fieldValue(d?.disposalSite?.name)}`}</Text>
      <Text style={styles.meta}>{`Vehicle ${fieldValue(d?.vehicle?.name)}`}</Text>
      <Text style={styles.meta}>{`Trailer ${fieldValue(d?.trailer?.name)}`}</Text>
      <Text style={styles.meta}>{workflowLabel(assignment)}</Text>
      <Text
        style={styles[SR_SYNC_STATE_STYLE[syncState]]}
        testID={`sync-${assignment.serviceRequestId}`}
      >
        {`Last sync: ${SR_SYNC_STATE_LABELS[syncState]}`}
      </Text>
    </Pressable>
  );
}

export function AssignmentInboxScreen(props: {
  assignments: HubAssignment[];
  syncStateById: ReadonlyMap<string, SrSyncState>;
  selectedFilter: InboxFilter;
  onSelectFilter: (filter: InboxFilter) => void;
  onSelectAssignment?: (serviceRequestId: string) => void;
}) {
  const { styles } = useFieldStyles();
  const filtered = filterAssignments(props.assignments, props.syncStateById, props.selectedFilter);
  return (
    <View style={styles.section} testID="assignment-inbox">
      <Text style={styles.heading}>Assignments</Text>
      <View style={styles.row}>
        {INBOX_FILTERS.map((filter) => {
          const count = filterAssignments(props.assignments, props.syncStateById, filter).length;
          const selected = filter === props.selectedFilter;
          return (
            <Pressable
              key={filter}
              testID={`filter-${filter}`}
              onPress={() => props.onSelectFilter(filter)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              accessibilityLabel={`${INBOX_FILTER_LABELS[filter]} filter, ${count} ${
                count === 1 ? 'assignment' : 'assignments'
              }`}
              style={[styles.chip, selected ? styles.chipSelected : null]}
            >
              <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                {`${INBOX_FILTER_LABELS[filter]} (${count})`}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {filtered.length === 0 ? (
        <Text style={styles.warn} testID="inbox-empty">
          No assignments in this view
        </Text>
      ) : (
        filtered.map((assignment) => (
          <AssignmentCard
            key={assignment.serviceRequestId}
            assignment={assignment}
            syncState={props.syncStateById.get(assignment.serviceRequestId) ?? 'no-local-work'}
            onPress={
              props.onSelectAssignment
                ? () => props.onSelectAssignment?.(assignment.serviceRequestId)
                : undefined
            }
          />
        ))
      )}
    </View>
  );
}

/**
 * Today dashboard (spec 7.4): the day's work as a priority ladder — office-review needs first,
 * then work owed to Hub, then in-progress / assigned / on-hold — with a one-line summary. Reuses
 * the SRs-tab AssignmentCard so a tap opens the same detail. Pure ranking lives in the domain.
 */
export function TodayScreen(props: {
  assignments: HubAssignment[];
  syncStateById: ReadonlyMap<string, SrSyncState>;
  onSelectAssignment?: (serviceRequestId: string) => void;
}) {
  const { styles } = useFieldStyles();
  const ranked = rankTodayAssignments(props.assignments, props.syncStateById);
  const countBy = (state: SrSyncState) =>
    ranked.filter((a) => props.syncStateById.get(a.serviceRequestId) === state).length;
  const needsReview = countBy('needs-review');
  const needsSync = countBy('needs-sync');
  const summary =
    `${ranked.length} ${ranked.length === 1 ? 'assignment' : 'assignments'}` +
    (needsReview > 0 ? ` · ${needsReview} need review` : '') +
    (needsSync > 0 ? ` · ${needsSync} need sync` : '');
  return (
    <View style={styles.section} testID="today">
      <Text style={styles.heading}>Today</Text>
      <Text style={styles.meta} testID="today-summary">
        {summary}
      </Text>
      {ranked.length === 0 ? (
        <Text style={styles.warn} testID="today-empty">
          No assignments today
        </Text>
      ) : (
        ranked.map((assignment) => (
          <AssignmentCard
            key={assignment.serviceRequestId}
            assignment={assignment}
            syncState={props.syncStateById.get(assignment.serviceRequestId) ?? 'no-local-work'}
            onPress={
              props.onSelectAssignment
                ? () => props.onSelectAssignment?.(assignment.serviceRequestId)
                : undefined
            }
          />
        ))
      )}
    </View>
  );
}

/**
 * Author/edit the field-ticket draft for one SR (spec 7.10). Until now the durable `draftStore`
 * was write-dead in the UI — only tests wrote drafts; this is the seam that makes the local
 * author→submit loop real. Fields map 1:1 to the V1 submit payload (ticket_no / quantity_bbl /
 * disposal_ticket_no). One editable draft per SR: an existing draft loads on mount; Save upserts
 * it; Delete removes it. The clock gate blocks authoring just like every other field action.
 */
/**
 * One tank's gauge fields as editable strings (RN inputs are strings; parsed to numbers on save).
 * Mirrors the paper ticket's two side-by-side tank panels.
 */
type TankForm = {
  label: string;
  locationTime: string;
  barrelsPulled: string;
  bTotalFt: string;
  bTotalIn: string;
  bWaterFt: string;
  bWaterIn: string;
  bCondFt: string;
  bCondIn: string;
  eTotalFt: string;
  eTotalIn: string;
  eWaterFt: string;
  eWaterIn: string;
  eCondFt: string;
  eCondIn: string;
  wpFt: string;
  wpIn: string;
};
type LineForm = { description: string; qty: string };

const numToStr = (n?: number): string => (n === undefined ? '' : String(n));
const strToNum = (v: string): number | undefined => {
  const n = Number(v);
  return v.trim() !== '' && Number.isFinite(n) ? n : undefined;
};
const ftInFrom = (ft: string, inch: string): FtIn | undefined => {
  const f = strToNum(ft);
  const i = strToNum(inch);
  if (f === undefined && i === undefined) return undefined;
  return { ...(f !== undefined ? { ft: f } : {}), ...(i !== undefined ? { inches: i } : {}) };
};
const readingFrom = (form: TankForm, p: 'b' | 'e'): GaugeReading | undefined => {
  const total = ftInFrom(form[`${p}TotalFt`], form[`${p}TotalIn`]);
  const water = ftInFrom(form[`${p}WaterFt`], form[`${p}WaterIn`]);
  const condensate = ftInFrom(form[`${p}CondFt`], form[`${p}CondIn`]);
  if (total === undefined && water === undefined && condensate === undefined) return undefined;
  return {
    ...(total !== undefined ? { total } : {}),
    ...(water !== undefined ? { water } : {}),
    ...(condensate !== undefined ? { condensate } : {}),
  };
};
function emptyTankForm(label: string): TankForm {
  return {
    label,
    locationTime: '',
    barrelsPulled: '',
    bTotalFt: '',
    bTotalIn: '',
    bWaterFt: '',
    bWaterIn: '',
    bCondFt: '',
    bCondIn: '',
    eTotalFt: '',
    eTotalIn: '',
    eWaterFt: '',
    eWaterIn: '',
    eCondFt: '',
    eCondIn: '',
    wpFt: '',
    wpIn: '',
  };
}
function tankToForm(g: TankGauge | undefined, fallbackLabel: string): TankForm {
  if (g === undefined) return emptyTankForm(fallbackLabel);
  return {
    label: g.label ?? fallbackLabel,
    locationTime: g.locationTime ?? '',
    barrelsPulled: numToStr(g.barrelsPulled),
    bTotalFt: numToStr(g.beginning?.total?.ft),
    bTotalIn: numToStr(g.beginning?.total?.inches),
    bWaterFt: numToStr(g.beginning?.water?.ft),
    bWaterIn: numToStr(g.beginning?.water?.inches),
    bCondFt: numToStr(g.beginning?.condensate?.ft),
    bCondIn: numToStr(g.beginning?.condensate?.inches),
    eTotalFt: numToStr(g.ending?.total?.ft),
    eTotalIn: numToStr(g.ending?.total?.inches),
    eWaterFt: numToStr(g.ending?.water?.ft),
    eWaterIn: numToStr(g.ending?.water?.inches),
    eCondFt: numToStr(g.ending?.condensate?.ft),
    eCondIn: numToStr(g.ending?.condensate?.inches),
    wpFt: numToStr(g.waterPulled?.ft),
    wpIn: numToStr(g.waterPulled?.inches),
  };
}
/**
 * Returns undefined unless the driver entered actual readings — a default/typed label or location
 * time ALONE is not data (otherwise the seeded "Truck"/"Trailer" labels would emit empty tanks).
 */
function formToTank(form: TankForm): TankGauge | undefined {
  const beginning = readingFrom(form, 'b');
  const ending = readingFrom(form, 'e');
  const waterPulled = ftInFrom(form.wpFt, form.wpIn);
  const barrelsPulled = strToNum(form.barrelsPulled);
  if (
    beginning === undefined &&
    ending === undefined &&
    waterPulled === undefined &&
    barrelsPulled === undefined
  ) {
    return undefined;
  }
  const label = form.label.trim();
  const locationTime = form.locationTime.trim();
  return {
    ...(label !== '' ? { label } : {}),
    ...(locationTime !== '' ? { locationTime } : {}),
    ...(beginning !== undefined ? { beginning } : {}),
    ...(ending !== undefined ? { ending } : {}),
    ...(waterPulled !== undefined ? { waterPulled } : {}),
    ...(barrelsPulled !== undefined ? { barrelsPulled } : {}),
  };
}

/** Assemble the full paper-ticket detail from the form state; undefined when nothing was entered. */
function buildTicketDetail(s: {
  rigNo: string;
  yardArrival: string;
  timeIn: string;
  timeOut: string;
  tank0: TankForm;
  tank1: TankForm;
  lines: LineForm[];
}): FieldTicketDetail | undefined {
  const rigNo = s.rigNo.trim();
  const times: FieldTicketTimes = {
    ...(s.yardArrival.trim() !== '' ? { yardArrival: s.yardArrival.trim() } : {}),
    ...(s.timeIn.trim() !== '' ? { timeIn: s.timeIn.trim() } : {}),
    ...(s.timeOut.trim() !== '' ? { timeOut: s.timeOut.trim() } : {}),
  };
  const tanks = [formToTank(s.tank0), formToTank(s.tank1)].filter(
    (tk): tk is TankGauge => tk !== undefined,
  );
  const lineItems: TicketLineItem[] = s.lines
    .map((l) => ({ description: l.description.trim(), qty: strToNum(l.qty) }))
    .filter((l) => l.description !== '')
    .map((l) => ({ description: l.description, ...(l.qty !== undefined ? { qty: l.qty } : {}) }));
  const detail: FieldTicketDetail = {
    ...(rigNo !== '' ? { rigNo } : {}),
    ...(Object.keys(times).length > 0 ? { times } : {}),
    ...(tanks.length > 0 ? { tanks } : {}),
    ...(lineItems.length > 0 ? { lineItems } : {}),
  };
  return Object.keys(detail).length > 0 ? detail : undefined;
}

/** One tank panel — beginning + ending gauges (total/water/condensate ft+in), water pulled, barrels. */
function TankPanel(props: {
  title: string;
  idPrefix: string;
  form: TankForm;
  onChange: (form: TankForm) => void;
}) {
  const { styles, t } = useFieldStyles();
  const set = (key: keyof TankForm) => (val: string) =>
    props.onChange({ ...props.form, [key]: val });
  const field = (key: keyof TankForm, placeholder: string, numeric: boolean) => (
    <TextInput
      placeholderTextColor={t.textMuted}
      testID={`${props.idPrefix}-${key}`}
      style={[styles.input, { flex: 1, marginBottom: 0 }]}
      value={props.form[key]}
      onChangeText={set(key)}
      placeholder={placeholder}
      {...(numeric ? { keyboardType: 'numeric' as const } : {})}
      accessibilityLabel={`${props.title} ${placeholder}`}
    />
  );
  const gauge = (label: string, ftKey: keyof TankForm, inKey: keyof TankForm) => (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 }}>
      <Text style={[styles.meta, { flex: 1 }]}>{label}</Text>
      {field(ftKey, 'ft', true)}
      {field(inKey, 'in', true)}
    </View>
  );
  return (
    <View style={styles.card} testID={`${props.idPrefix}-panel`}>
      <Text style={styles.heading}>{props.title}</Text>
      {field('label', 'Tank', false)}
      <View style={{ height: 6 }} />
      {field('locationTime', 'Location time', false)}
      <Text style={[styles.meta, { marginTop: 8 }]}>Beginning gauge</Text>
      {gauge('Total', 'bTotalFt', 'bTotalIn')}
      {gauge('Water', 'bWaterFt', 'bWaterIn')}
      {gauge('Condensate', 'bCondFt', 'bCondIn')}
      <Text style={[styles.meta, { marginTop: 8 }]}>Ending gauge</Text>
      {gauge('Total', 'eTotalFt', 'eTotalIn')}
      {gauge('Water', 'eWaterFt', 'eWaterIn')}
      {gauge('Condensate', 'eCondFt', 'eCondIn')}
      {gauge('Water pulled', 'wpFt', 'wpIn')}
      <View style={{ height: 6 }} />
      {field('barrelsPulled', 'Barrels pulled', true)}
    </View>
  );
}

export function TicketCaptureScreen(props: {
  draftStore: FieldTicketDraftStore;
  serviceRequestId: string;
  /**
   * The SR's human-readable request number (e.g. "2026-000001"). The ticket IS the SR — its id is
   * the SR number, not a manually-typed value. Falls back to the internal serviceRequestId only
   * when the assignment has not yet provided a requestNo.
   */
  requestNo?: string;
  /**
   * The authenticated driver's identity (Driver ID / username). The driver is never a visible,
   * editable field — it is the signed-in account, threaded through to populate the draft.
   */
  driverName?: string;
  gate?: FieldWorkGate;
  identity: { generateUuid: () => string };
  now?: () => Date;
  onSaved?: (draft: FieldTicketDraft) => void;
  onDeleted?: () => void;
}) {
  const { styles, t } = useFieldStyles();
  const now = props.now ?? (() => new Date());
  // SR number IS the ticket number (item 1). The driver never types a ticket id; it is derived
  // from the SR's human request number, falling back to the internal id only until one arrives.
  const ticketNo = props.requestNo ?? props.serviceRequestId;
  const existing = props.draftStore
    .list()
    .find((draft) => draft.serviceRequestId === props.serviceRequestId);
  const [quantity, setQuantity] = useState(existing ? String(existing.quantityBbl) : '');
  const [disposalTicketNo, setDisposalTicketNo] = useState(existing?.disposalTicketNo ?? '');
  const [truck, setTruck] = useState(existing?.truck ?? '');
  const [trailer, setTrailer] = useState(existing?.trailer ?? '');
  const [notes, setNotes] = useState(existing?.notes ?? '');
  const [captureMethod, setCaptureMethod] = useState<TicketCaptureMethod>(
    existing?.captureMethod ?? 'digital',
  );
  const [draftId, setDraftId] = useState<string | undefined>(existing?.id);
  const [createdAt, setCreatedAt] = useState<string | undefined>(existing?.createdAt);
  // Full paper-ticket detail (gauges, times, rig #, line items).
  const [rigNo, setRigNo] = useState(existing?.detail?.rigNo ?? '');
  const [yardArrival, setYardArrival] = useState(existing?.detail?.times?.yardArrival ?? '');
  const [timeIn, setTimeIn] = useState(existing?.detail?.times?.timeIn ?? '');
  const [timeOut, setTimeOut] = useState(existing?.detail?.times?.timeOut ?? '');
  const [tank0, setTank0] = useState<TankForm>(() =>
    tankToForm(existing?.detail?.tanks?.[0], 'Truck'),
  );
  const [tank1, setTank1] = useState<TankForm>(() =>
    tankToForm(existing?.detail?.tanks?.[1], 'Trailer'),
  );
  const [lines, setLines] = useState<LineForm[]>(() =>
    existing?.detail?.lineItems !== undefined && existing.detail.lineItems.length > 0
      ? existing.detail.lineItems.map((li) => ({
          description: li.description,
          qty: numToStr(li.qty),
        }))
      : [{ description: '', qty: '' }],
  );
  const [message, setMessage] = useState<Message>(null);

  const locked = props.gate !== undefined && props.gate.state === 'locked';

  const save = () => {
    if (locked && props.gate?.state === 'locked') {
      setMessage({
        kind: 'warn',
        text: `Field work is locked: ${fieldWorkGateLockReason(props.gate)}`,
      });
      return;
    }
    const qty = Number(quantity);
    if (!Number.isFinite(qty) || qty < 0) {
      setMessage({ kind: 'error', text: 'Quantity must be a non-negative number' });
      return;
    }
    const id = draftId ?? props.identity.generateUuid();
    const at = now().toISOString();
    // The driver = the authenticated account; populated from the session, never a visible field.
    const driver = props.driverName?.trim();
    const detail = buildTicketDetail({ rigNo, yardArrival, timeIn, timeOut, tank0, tank1, lines });
    const draft: FieldTicketDraft = {
      id,
      serviceRequestId: props.serviceRequestId,
      // Keep ticketNo populated for the submit/contract path — it is the SR number.
      ticketNo: ticketNo.trim(),
      quantityBbl: qty,
      disposalTicketNo: disposalTicketNo.trim(),
      ...(truck.trim() !== '' ? { truck: truck.trim() } : {}),
      ...(trailer.trim() !== '' ? { trailer: trailer.trim() } : {}),
      ...(driver !== undefined && driver !== '' ? { driver } : {}),
      ...(notes.trim() !== '' ? { notes: notes.trim() } : {}),
      captureMethod,
      ...(detail !== undefined ? { detail } : {}),
      createdAt: createdAt ?? at,
      updatedAt: at,
    };
    props.draftStore.save(draft);
    setDraftId(id);
    setCreatedAt(draft.createdAt);
    setMessage({ kind: 'ok', text: 'Ticket draft saved' });
    props.onSaved?.(draft);
  };

  const remove = () => {
    if (draftId === undefined) return;
    props.draftStore.delete(draftId);
    setDraftId(undefined);
    setCreatedAt(undefined);
    setQuantity('');
    setDisposalTicketNo('');
    setTruck('');
    setTrailer('');
    setNotes('');
    setCaptureMethod('digital');
    setRigNo('');
    setYardArrival('');
    setTimeIn('');
    setTimeOut('');
    setTank0(emptyTankForm('Truck'));
    setTank1(emptyTankForm('Trailer'));
    setLines([{ description: '', qty: '' }]);
    setMessage({ kind: 'ok', text: 'Draft deleted' });
    props.onDeleted?.();
  };

  return (
    <View style={styles.section} testID="ticket-capture">
      <Text style={styles.heading}>{`Field ticket · SR ${ticketNo}`}</Text>
      <Text style={styles.meta} testID="ticket-no">{`Ticket ${ticketNo}`}</Text>
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-qty-input"
        style={styles.input}
        value={quantity}
        onChangeText={setQuantity}
        placeholder="Quantity (bbl)"
        keyboardType="numeric"
        accessibilityLabel="Quantity in barrels"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-disposal-input"
        style={styles.input}
        value={disposalTicketNo}
        onChangeText={setDisposalTicketNo}
        placeholder="Disposal ticket number"
        accessibilityLabel="Disposal ticket number"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-truck-input"
        style={styles.input}
        value={truck}
        onChangeText={setTruck}
        placeholder="Truck"
        accessibilityLabel="Truck"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-trailer-input"
        style={styles.input}
        value={trailer}
        onChangeText={setTrailer}
        placeholder="Trailer"
        accessibilityLabel="Trailer"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-notes-input"
        style={styles.input}
        value={notes}
        onChangeText={setNotes}
        placeholder="Notes"
        accessibilityLabel="Notes"
      />

      <Text style={[styles.meta, { marginTop: 8 }]}>Times &amp; rig</Text>
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-rig-input"
        style={styles.input}
        value={rigNo}
        onChangeText={setRigNo}
        placeholder="Rig #"
        accessibilityLabel="Rig number"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-yard-input"
        style={styles.input}
        value={yardArrival}
        onChangeText={setYardArrival}
        placeholder="Yard arrival time"
        accessibilityLabel="Yard arrival time"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-timein-input"
        style={styles.input}
        value={timeIn}
        onChangeText={setTimeIn}
        placeholder="Time in"
        accessibilityLabel="Time in"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="ticket-timeout-input"
        style={styles.input}
        value={timeOut}
        onChangeText={setTimeOut}
        placeholder="Time out"
        accessibilityLabel="Time out"
      />

      <TankPanel title="Tank 1 — truck" idPrefix="ticket-tank0" form={tank0} onChange={setTank0} />
      <TankPanel
        title="Tank 2 — trailer"
        idPrefix="ticket-tank1"
        form={tank1}
        onChange={setTank1}
      />

      <Text style={[styles.heading, { marginTop: 8 }]}>Line items</Text>
      {lines.map((line, idx) => (
        <View
          key={`line-${idx}`}
          style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 }}
        >
          <TextInput
            placeholderTextColor={t.textMuted}
            testID={`ticket-line-desc-${idx}`}
            style={[styles.input, { flex: 2, marginBottom: 0 }]}
            value={line.description}
            onChangeText={(v) =>
              setLines((prev) => prev.map((l, i) => (i === idx ? { ...l, description: v } : l)))
            }
            placeholder="Description"
            accessibilityLabel={`Line ${idx + 1} description`}
          />
          <TextInput
            placeholderTextColor={t.textMuted}
            testID={`ticket-line-qty-${idx}`}
            style={[styles.input, { flex: 1, marginBottom: 0 }]}
            value={line.qty}
            onChangeText={(v) =>
              setLines((prev) => prev.map((l, i) => (i === idx ? { ...l, qty: v } : l)))
            }
            placeholder="Qty"
            keyboardType="numeric"
            accessibilityLabel={`Line ${idx + 1} quantity`}
          />
          {lines.length > 1 ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={`Remove line ${idx + 1}`}
              testID={`ticket-line-remove-${idx}`}
              onPress={() => setLines((prev) => prev.filter((_, i) => i !== idx))}
              style={styles.chip}
            >
              <Text style={styles.chipText}>Remove</Text>
            </Pressable>
          ) : null}
        </View>
      ))}
      <View style={styles.row}>
        <ActionButton
          testID="ticket-line-add"
          label="Add line"
          onPress={() => setLines((prev) => [...prev, { description: '', qty: '' }])}
        />
      </View>
      <Text style={[styles.meta, { marginTop: 4 }]}>Rate &amp; total are priced by the Hub.</Text>

      <View style={styles.row}>
        {TICKET_CAPTURE_METHODS.map((method) => {
          const selected = method === captureMethod;
          return (
            <Pressable
              key={method}
              testID={`ticket-capture-${method}`}
              onPress={() => setCaptureMethod(method)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              accessibilityLabel={`Capture method ${method}`}
              style={[styles.chip, selected ? styles.chipSelected : null]}
            >
              <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                {method}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <View style={styles.row}>
        <ActionButton testID="ticket-save" label="Save draft" onPress={save} />
        {draftId !== undefined ? (
          <ActionButton testID="ticket-delete" label="Delete draft" onPress={remove} />
        ) : null}
      </View>
      <MessageLine message={message} />
    </View>
  );
}

/**
 * Author/edit the receipt draft for one SR (spec 7.10) — the receipt half of the ticket+receipt
 * package. Mirrors `TicketCaptureScreen`: an existing receipt loads on mount, Save upserts, Delete
 * removes; the clock gate blocks authoring. Receipt photos attach separately via the `receipt-photo`
 * capture kind. One receipt per (SR, ticket) for now.
 */
export function ReceiptCaptureScreen(props: {
  receiptStore: ReceiptDraftStore;
  serviceRequestId: string;
  gate?: FieldWorkGate;
  identity: { generateUuid: () => string };
  now?: () => Date;
  ticketDraftId?: string;
  onSaved?: (draft: ReceiptDraft) => void;
  onDeleted?: () => void;
}) {
  const { styles, t } = useFieldStyles();
  const now = props.now ?? (() => new Date());
  const existing = props.receiptStore
    .list()
    .find((draft) => draft.serviceRequestId === props.serviceRequestId);
  const [receiptType, setReceiptType] = useState<ReceiptType>(existing?.receiptType ?? 'disposal');
  const [vendor, setVendor] = useState(existing?.vendor ?? '');
  const [receiptNo, setReceiptNo] = useState(existing?.receiptNo ?? '');
  const [amount, setAmount] = useState(existing ? String(existing.amount) : '');
  const [notes, setNotes] = useState(existing?.notes ?? '');
  const [draftId, setDraftId] = useState<string | undefined>(existing?.id);
  const [createdAt, setCreatedAt] = useState<string | undefined>(existing?.createdAt);
  const [message, setMessage] = useState<Message>(null);

  const save = () => {
    if (props.gate?.state === 'locked') {
      setMessage({
        kind: 'warn',
        text: `Field work is locked: ${fieldWorkGateLockReason(props.gate)}`,
      });
      return;
    }
    if (vendor.trim() === '') {
      setMessage({ kind: 'error', text: 'Vendor is required' });
      return;
    }
    const value = Number(amount);
    if (!Number.isFinite(value) || value < 0) {
      setMessage({ kind: 'error', text: 'Amount must be a non-negative number' });
      return;
    }
    const id = draftId ?? props.identity.generateUuid();
    const at = now().toISOString();
    const draft: ReceiptDraft = {
      id,
      serviceRequestId: props.serviceRequestId,
      receiptType,
      vendor: vendor.trim(),
      receiptNo: receiptNo.trim(),
      amount: value,
      notes: notes.trim(),
      ...(props.ticketDraftId !== undefined ? { ticketDraftId: props.ticketDraftId } : {}),
      createdAt: createdAt ?? at,
      updatedAt: at,
    };
    props.receiptStore.save(draft);
    setDraftId(id);
    setCreatedAt(draft.createdAt);
    setMessage({ kind: 'ok', text: 'Receipt draft saved' });
    props.onSaved?.(draft);
  };

  const remove = () => {
    if (draftId === undefined) return;
    props.receiptStore.delete(draftId);
    setDraftId(undefined);
    setCreatedAt(undefined);
    setVendor('');
    setReceiptNo('');
    setAmount('');
    setNotes('');
    setMessage({ kind: 'ok', text: 'Receipt deleted' });
    props.onDeleted?.();
  };

  return (
    <View style={styles.section} testID="receipt-capture">
      <Text style={styles.heading}>{`Receipt · SR ${props.serviceRequestId}`}</Text>
      <View style={styles.row}>
        {RECEIPT_TYPES.map((type) => {
          const selected = type === receiptType;
          return (
            <Pressable
              key={type}
              testID={`receipt-type-${type}`}
              onPress={() => setReceiptType(type)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={[styles.chip, selected ? styles.chipSelected : null]}
            >
              <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                {type}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="receipt-vendor-input"
        style={styles.input}
        value={vendor}
        onChangeText={setVendor}
        placeholder="Vendor"
        accessibilityLabel="Vendor"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="receipt-no-input"
        style={styles.input}
        value={receiptNo}
        onChangeText={setReceiptNo}
        placeholder="Receipt number"
        accessibilityLabel="Receipt number"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="receipt-amount-input"
        style={styles.input}
        value={amount}
        onChangeText={setAmount}
        placeholder="Amount"
        keyboardType="numeric"
        accessibilityLabel="Amount"
      />
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="receipt-notes-input"
        style={styles.input}
        value={notes}
        onChangeText={setNotes}
        placeholder="Notes"
        accessibilityLabel="Notes"
      />
      <View style={styles.row}>
        <ActionButton testID="receipt-save" label="Save receipt" onPress={save} />
        {draftId !== undefined ? (
          <ActionButton testID="receipt-delete" label="Delete receipt" onPress={remove} />
        ) : null}
      </View>
      <MessageLine message={message} />
    </View>
  );
}

/**
 * Sync Center (spec 7.15): the worker's single answer to "what's saved, synced, failed, and needs
 * review?". Dumb/pure — the caller computes the `summary` via `summarizeSyncCenter` and supplies
 * the plain-language last-Hub-contact line. Raw technical codes (409/snapshot-drift) belong in an
 * expandable developer section, not here. "Retry all" is offered only when work is outstanding.
 */
export function SyncCenterScreen(props: {
  summary: SyncCenterSummary;
  lastHubContactLabel?: string;
  onRetryAll?: () => void;
  onCopyDiagnostic?: () => void;
}) {
  const { styles } = useFieldStyles();
  return (
    <View style={styles.section} testID="sync-center">
      <Text style={styles.heading}>Sync Center</Text>
      {props.lastHubContactLabel !== undefined ? (
        <Text style={styles.meta} testID="last-hub-contact">
          {`Last Hub contact: ${props.lastHubContactLabel}`}
        </Text>
      ) : null}
      {SYNC_CENTER_ORDER.map((category) => (
        <Text key={category} style={styles.meta} testID={`sync-row-${category}`}>
          {`${SYNC_CENTER_LABELS[category]}: ${props.summary.counts[category]}`}
        </Text>
      ))}
      {props.summary.hasOutstanding ? (
        props.onRetryAll !== undefined ? (
          <ActionButton testID="sync-retry-all" label="Retry all" onPress={props.onRetryAll} />
        ) : null
      ) : (
        <Text style={styles.ok} testID="sync-all-clear">
          All work is accepted by Hub
        </Text>
      )}
      {props.onCopyDiagnostic !== undefined ? (
        <ActionButton
          testID="sync-copy-diagnostic"
          label="Copy diagnostic"
          onPress={props.onCopyDiagnostic}
        />
      ) : null}
    </View>
  );
}

/**
 * More / Settings (spec 7.x + Phase 2): Hub environment + read-only URL (informational), an
 * honest storage-durability line, the offline-policy explanation, copy-diagnostic, and sign-out.
 * Sign-out PRESERVES unsynced local work (cross-cutting invariant) — the copy says so plainly.
 */
export function MoreScreen(props: {
  appEnv: string;
  hubUrl: string | null;
  durability: string;
  appVersion?: string;
  onSignOut: () => void | Promise<void>;
  onCopyDiagnostic?: () => void;
}) {
  const { styles } = useFieldStyles();
  return (
    <View style={styles.section} testID="more-screen">
      <Text style={styles.heading}>More</Text>
      <Text style={styles.meta} testID="more-hub-env">{`Hub environment: ${props.appEnv}`}</Text>
      <Text style={styles.meta} testID="more-hub-url">{`Hub URL: ${
        props.hubUrl ?? 'not configured'
      }`}</Text>
      <Text style={styles.meta}>{`Local storage: ${props.durability}`}</Text>
      {props.appVersion !== undefined ? (
        <Text style={styles.meta}>{`Version: ${props.appVersion}`}</Text>
      ) : null}
      <Text style={styles.meta}>
        Field Capture works offline. Captured work is saved on this phone and synced to Ops Hub
        when a connection returns — it is never lost or auto-deleted.
      </Text>
      <Text style={styles.meta}>Signing out keeps your unsynced work safe on this phone.</Text>
      {props.onCopyDiagnostic !== undefined ? (
        <ActionButton
          testID="more-copy-diagnostic"
          label="Copy diagnostic info"
          onPress={props.onCopyDiagnostic}
        />
      ) : null}
      <ActionButton testID="more-sign-out" label="Sign out" onPress={props.onSignOut} />
    </View>
  );
}

const LOCATION_PLACE_KINDS: readonly fieldwork.LocationPlaceKind[] = [
  'yard',
  'disposal-site',
  'well-site',
  'other',
];

/**
 * Location validation (spec 7.13 / Phase 7) — VALIDATION ONLY, not navigation. Pick a place, take a
 * single-shot GPS fix (the device `captureGps` seam — never streaming, no map), classify it against
 * the assignment's expected area, and save it as durable, non-evictable evidence. Unknown wells save
 * as "Unverified Location Evidence"; a failed fix saves "gps-unavailable" — the phone never fakes a
 * verified location. The native GPS capture itself is injected; this screen is its logic.
 */
export function LocationValidationScreen(props: {
  locationStore: LocationEvidenceStore;
  serviceRequestId: string;
  gate?: FieldWorkGate;
  expectedArea?: { lat: number; lon: number; radiusM: number };
  captureGps: () => Promise<fieldwork.LocationGpsPoint | null>;
  identity: { generateUuid: () => string };
  now?: () => Date;
  onSaved?: (evidence: fieldwork.LocationEvidence) => void;
}) {
  const { styles, t } = useFieldStyles();
  const now = props.now ?? (() => new Date());
  const [placeKind, setPlaceKind] = useState<fieldwork.LocationPlaceKind>('well-site');
  const [evidenceType, setEvidenceType] = useState('arrival');
  const [message, setMessage] = useState<Message>(null);
  const [lastState, setLastState] = useState<fieldwork.LocationEvidenceState | null>(null);

  const lockedReason =
    props.gate?.state === 'locked' ? fieldWorkGateLockReason(props.gate) : undefined;
  const guardUnlocked = () => {
    if (lockedReason === undefined) return true;
    setMessage({ kind: 'warn', text: `Field work is locked: ${lockedReason}` });
    return false;
  };

  const save = (gps: fieldwork.LocationGpsPoint | undefined, manualOnly: boolean) => {
    if (!guardUnlocked()) return;
    const state = fieldwork.classifyLocationEvidence({
      ...(gps !== undefined ? { gps } : {}),
      ...(props.expectedArea !== undefined ? { expected: props.expectedArea } : {}),
      ...(manualOnly ? { manualOnly: true } : {}),
      ...(gps === undefined && !manualOnly ? { gpsUnavailable: true } : {}),
    });
    const evidence: fieldwork.LocationEvidence = {
      id: props.identity.generateUuid(),
      serviceRequestId: props.serviceRequestId,
      placeKind,
      evidenceType: evidenceType.trim() === '' ? 'location' : evidenceType.trim(),
      ...(gps !== undefined ? { gps } : {}),
      state,
      createdAt: now().toISOString(),
    };
    props.locationStore.record(evidence);
    setLastState(state);
    setMessage({
      kind: state === 'verified' ? 'ok' : state === 'outside-expected-area' ? 'error' : 'warn',
      text: `Location evidence saved: ${state}`,
    });
    props.onSaved?.(evidence);
  };

  const captureAndSave = async () => {
    if (!guardUnlocked()) return;
    const gps = await props.captureGps();
    save(gps ?? undefined, false);
  };

  return (
    <View style={styles.section} testID="location-validation">
      <Text style={styles.heading}>Location validation</Text>
      <View style={styles.row}>
        {LOCATION_PLACE_KINDS.map((kind) => {
          const selected = kind === placeKind;
          return (
            <Pressable
              key={kind}
              testID={`location-place-${kind}`}
              onPress={() => setPlaceKind(kind)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={[styles.chip, selected ? styles.chipSelected : null]}
            >
              <Text style={[styles.chipText, selected ? styles.chipTextSelected : null]}>
                {kind}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <TextInput
        placeholderTextColor={t.textMuted}
        testID="location-type-input"
        style={styles.input}
        value={evidenceType}
        onChangeText={setEvidenceType}
        placeholder="Evidence type (e.g. arrival)"
        accessibilityLabel="Evidence type"
      />
      <View style={styles.row}>
        <ActionButton testID="location-capture" label="Capture GPS" onPress={captureAndSave} />
        <ActionButton
          testID="location-manual"
          label="Save as Unverified Location Evidence"
          onPress={() => save(undefined, true)}
        />
      </View>
      {lastState !== null ? (
        <Text style={styles.meta} testID="location-state">{`State: ${lastState}`}</Text>
      ) : null}
      <MessageLine message={message} />
    </View>
  );
}

function formStatus(forms: FieldFormStore, formId: string): string {
  const record = forms.get(formId);
  if (record === undefined) return 'not-started';
  return record.lastError !== undefined ? `${record.status} (${record.lastError})` : record.status;
}

function captureStatus(
  blob: ReturnType<BlobUploadStore['list']>[number],
  linkState: sync.OutboxItemState | undefined,
): string {
  if (linkState === 'needs-review') return 'needs-review';
  if (linkState === 'rejected') return 'failed';
  if (blob.state === 'local-only') return 'upload pending';
  if (blob.state === 'uploading') return 'uploading';
  if (blob.state === 'uploaded') return 'uploaded';
  if (blob.state === 'linked') return 'linked';
  return 'failed';
}

function dvirForm(input: {
  formId: string;
  kind: 'pre-trip-dvir' | 'post-trip-dvir';
  vehicleRef: string;
  signatureText: string;
}): fieldwork.DvirForm {
  return {
    formId: input.formId,
    kind: input.kind,
    vehicleRef: input.vehicleRef,
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: ids(input.signatureText),
  };
}

function jhaForm(input: {
  formId: string;
  serviceRequestId: string;
  hazard: string;
  mitigation: string;
  signatureText: string;
}): fieldwork.JhaForm {
  return {
    formId: input.formId,
    kind: 'jha-jsa',
    serviceRequestId: input.serviceRequestId,
    hazards: [{ hazardId: 'h1', description: input.hazard, mitigation: input.mitigation }],
    signatureBlobIds: ids(input.signatureText),
  };
}

export function FieldWorkflowScreen(props: {
  gate: FieldWorkGate;
  workflow: FieldWorkflowService;
  forms: FieldFormStore;
  serviceRequestId: string;
  onSubmitTicket: () => Promise<unknown>;
}) {
  const { styles, t } = useFieldStyles();
  const [message, setMessage] = useState<Message>(null);
  const [revision, setRevision] = useState(0);
  const [preTripSignature, setPreTripSignature] = useState('');
  const [postTripSignature, setPostTripSignature] = useState('');
  const [vehicleRef, setVehicleRef] = useState('truck-7');

  const preTripId = `pre-trip-dvir-${props.serviceRequestId}`;
  const postTripId = `post-trip-dvir-${props.serviceRequestId}`;
  const jhaId = `jha-jsa-${props.serviceRequestId}`;

  // Item 9 — JHA save-as-you-go + don't-re-ask-once-done. Seed the editable fields from the durable
  // record keyed jha-jsa-${SR} so progress is remembered across navigation/restart, and never lost.
  const jhaSeed = props.forms.get(jhaId);
  const seedHazard =
    jhaSeed !== undefined && jhaSeed.form.kind === 'jha-jsa'
      ? (jhaSeed.form.hazards[0]?.description ?? '')
      : 'H2S';
  const seedMitigation =
    jhaSeed !== undefined && jhaSeed.form.kind === 'jha-jsa'
      ? (jhaSeed.form.hazards[0]?.mitigation ?? '')
      : 'monitor';
  const seedSignature =
    jhaSeed !== undefined && jhaSeed.form.kind === 'jha-jsa'
      ? (jhaSeed.form.signatureBlobIds[0] ?? '')
      : '';
  const [hazard, setHazard] = useState(seedHazard);
  const [mitigation, setMitigation] = useState(seedMitigation);
  const [jhaSignature, setJhaSignature] = useState(seedSignature);

  const bump = () => setRevision((n) => n + 1);

  // A JHA at completed/enqueued/accepted (or flagged) is already done for this SR — its completedAt
  // is set and the ticket is gated on it. Re-prompting would re-ask finished work, so the screen
  // shows a completed banner instead of the editable form (revision keeps this fresh after edits).
  void revision;
  const jhaRecord = props.forms.get(jhaId);
  const jhaDone = jhaRecord !== undefined && jhaRecord.status !== 'draft';
  const jhaCompletedAt =
    jhaRecord !== undefined && jhaRecord.form.kind === 'jha-jsa'
      ? jhaRecord.form.completedAt
      : undefined;

  /** Persist the JHA draft from the current field values — used on every change AND on Save. */
  const persistJhaDraft = (next?: {
    hazard?: string;
    mitigation?: string;
    signatureText?: string;
  }): ReturnType<FieldWorkflowService['saveDraft']> =>
    props.workflow.saveDraft(
      jhaForm({
        formId: jhaId,
        serviceRequestId: props.serviceRequestId,
        hazard: next?.hazard ?? hazard,
        mitigation: next?.mitigation ?? mitigation,
        signatureText: next?.signatureText ?? jhaSignature,
      }),
    );

  // Save-on-change: each keystroke updates state AND writes the draft (skipped once frozen/done so a
  // completed JHA is never silently re-drafted). Failures are swallowed here — the explicit Save
  // surfaces any locked/frozen message; on-change just keeps progress durable.
  const onChangeJha = (field: 'hazard' | 'mitigation' | 'signatureText', value: string) => {
    if (field === 'hazard') setHazard(value);
    else if (field === 'mitigation') setMitigation(value);
    else setJhaSignature(value);
    if (jhaDone) return;
    persistJhaDraft({ [field]: value });
    bump();
  };
  const saveDvir = (kind: 'pre-trip-dvir' | 'post-trip-dvir', formId: string, sig: string) => {
    const result = props.workflow.saveDraft(
      dvirForm({ formId, kind, vehicleRef, signatureText: sig }),
    );
    setMessage(formatWorkflowResult(result, 'Draft saved'));
    bump();
  };
  const complete = (formId: string) => {
    const result = props.workflow.completeForm(formId);
    setMessage(formatWorkflowResult(result, 'Completed'));
    bump();
  };
  const submit = (formId: string) => {
    const result = props.workflow.submitForm(formId);
    setMessage(formatWorkflowResult(result, 'Evidence enqueued'));
    bump();
  };

  return (
    <View style={styles.screenInner}>
      <Text style={props.gate.state === 'unlocked' ? styles.ok : styles.warn} testID="field-gate">
        {gateLabel(props.gate)}
      </Text>
      <MessageLine message={message} />
      <View style={styles.row}>
        <ActionButton
          testID="workflow-refresh-outcomes"
          label="Refresh Outcomes"
          onPress={() => {
            const result = props.workflow.reconcileOutcomes();
            setMessage({
              kind: result.needsReview.length > 0 || result.rejected.length > 0 ? 'warn' : 'ok',
              text:
                `Outcomes accepted ${result.accepted.length} review ` +
                `${result.needsReview.length} rejected ${result.rejected.length}`,
            });
            bump();
          }}
        />
      </View>

      <View style={styles.section}>
        <Text style={styles.heading}>Pre-trip DVIR</Text>
        <Text testID="pretrip-status">{`status ${formStatus(props.forms, preTripId)}`}</Text>
        <TextInput
          placeholderTextColor={t.textMuted}
          testID="vehicle-ref"
          value={vehicleRef}
          onChangeText={setVehicleRef}
          style={styles.input}
          placeholder="Vehicle"
        />
        <TextInput
          placeholderTextColor={t.textMuted}
          testID="pretrip-signature"
          value={preTripSignature}
          onChangeText={setPreTripSignature}
          style={styles.input}
          placeholder="Signature blob id"
        />
        <View style={styles.row}>
          <ActionButton
            testID="pretrip-save"
            label="Save"
            onPress={() => saveDvir('pre-trip-dvir', preTripId, preTripSignature)}
          />
          <ActionButton
            testID="pretrip-complete"
            label="Complete"
            onPress={() => complete(preTripId)}
          />
          <ActionButton testID="pretrip-submit" label="Submit" onPress={() => submit(preTripId)} />
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.heading}>JHA/JSA</Text>
        <Text testID="jha-status">{`status ${formStatus(props.forms, jhaId)}`}</Text>
        {jhaDone ? (
          // Already done for this SR — do not re-ask (item 9). The completed JHA is remembered in the
          // durable form store; the ticket is already gated on it, so we just confirm it's complete.
          <View style={styles.section} testID="jha-complete-banner">
            <Text style={styles.ok}>
              {`JHA/JSA already complete for this SR${
                jhaCompletedAt !== undefined ? ` (${jhaCompletedAt})` : ''
              } — no need to fill it out again.`}
            </Text>
            <ActionButton testID="jha-submit" label="Submit" onPress={() => submit(jhaId)} />
          </View>
        ) : (
          <>
            <TextInput
              placeholderTextColor={t.textMuted}
              testID="jha-hazard"
              value={hazard}
              onChangeText={(value) => onChangeJha('hazard', value)}
              style={styles.input}
              placeholder="Hazard"
            />
            <TextInput
              placeholderTextColor={t.textMuted}
              testID="jha-mitigation"
              value={mitigation}
              onChangeText={(value) => onChangeJha('mitigation', value)}
              style={styles.input}
              placeholder="Mitigation"
            />
            <TextInput
              placeholderTextColor={t.textMuted}
              testID="jha-signature"
              value={jhaSignature}
              onChangeText={(value) => onChangeJha('signatureText', value)}
              style={styles.input}
              placeholder="Signature blob id"
            />
            <View style={styles.row}>
              <ActionButton
                testID="jha-save"
                label="Save"
                onPress={() => {
                  const result = persistJhaDraft();
                  setMessage(formatWorkflowResult(result, 'Draft saved'));
                  bump();
                }}
              />
              <ActionButton
                testID="jha-complete"
                label="Complete"
                onPress={() => complete(jhaId)}
              />
              <ActionButton testID="jha-submit" label="Submit" onPress={() => submit(jhaId)} />
            </View>
          </>
        )}
      </View>

      <View style={styles.section}>
        <Text style={styles.heading}>Post-trip DVIR</Text>
        <Text testID="posttrip-status">{`status ${formStatus(props.forms, postTripId)}`}</Text>
        <TextInput
          placeholderTextColor={t.textMuted}
          testID="posttrip-signature"
          value={postTripSignature}
          onChangeText={setPostTripSignature}
          style={styles.input}
          placeholder="Signature blob id"
        />
        <View style={styles.row}>
          <ActionButton
            testID="posttrip-save"
            label="Save"
            onPress={() => saveDvir('post-trip-dvir', postTripId, postTripSignature)}
          />
          <ActionButton
            testID="posttrip-complete"
            label="Complete"
            onPress={() => complete(postTripId)}
          />
          <ActionButton
            testID="posttrip-submit"
            label="Submit"
            onPress={() => submit(postTripId)}
          />
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.heading}>Ticket Gate</Text>
        <Text testID="ticket-gate">
          {JSON.stringify(props.workflow.guardTicketSubmit(props.serviceRequestId))}
        </Text>
        <ActionButton
          testID="ticket-submit"
          label="Submit Ticket"
          onPress={async () => {
            const result = await props.workflow.submitTicketWithWorkflow(
              props.serviceRequestId,
              props.onSubmitTicket,
            );
            if (result.status === 'submitted') {
              const value = result.result as { status?: string };
              const status = value.status ?? 'complete';
              setMessage({
                kind: status === 'accepted' || status === 'submitted' ? 'ok' : 'warn',
                text:
                  status === 'accepted' || status === 'submitted'
                    ? `Ticket submitted: ${status}`
                    : `Ticket handoff: ${status}`,
              });
            } else if (result.status === 'blocked') {
              setMessage({ kind: 'warn', text: `Ticket blocked: ${result.missing.join(', ')}` });
            } else if (result.status === 'vehicle-unsafe') {
              setMessage({
                kind: 'error',
                text: 'Vehicle certified UNSAFE on the pre-trip DVIR — field work is blocked and sent for office review.',
              });
            } else {
              setMessage({ kind: 'warn', text: `Locked: ${result.reason}` });
            }
            bump();
          }}
        />
      </View>
      <Text style={styles.meta}>forms revision {revision}</Text>
    </View>
  );
}

export function CaptureEvidenceScreen(props: {
  capture: CaptureFlow;
  uploads: Pick<UploadEngine, 'processOnce'>;
  blobs: BlobUploadStore;
  parentType: sync.AttachBlobCommand['parentType'];
  parentId: string;
  linkOutcome?: (opId: string) => sync.OutboxItemState | undefined;
  captureDevice?: CaptureEvidenceDevice;
}) {
  const { styles } = useFieldStyles();
  const [message, setMessage] = useState<Message>(null);
  const [, setRevision] = useState(0);
  const [sources, setSources] = useState<Record<string, CaptureSource>>({});
  const [signatureValue, setSignatureValue] = useState<SignatureValue | null>(null);
  const bump = () => setRevision((n) => n + 1);

  const captureOne = async (
    attachmentKind: sync.AttachBlobCommand['attachmentKind'],
    source: CaptureSource,
  ) => {
    try {
      const captured =
        attachmentKind === 'signature'
          ? signatureValue === null
            ? null
            : {
                bytes: signatureBytes(signatureValue),
                mimeType: 'image/png',
                source: 'signature-pad' as const,
              }
          : await props.captureDevice?.({ attachmentKind, source });
      if (captured === undefined || captured === null) {
        setMessage({
          kind: 'warn',
          text:
            attachmentKind === 'signature'
              ? 'Draw a signature before saving it as evidence'
              : 'Capture canceled or unavailable',
        });
        return;
      }
      const result =
        attachmentKind === 'signature'
          ? await props.capture.captureSignature({
              bytes: captured.bytes,
              parentType: props.parentType,
              parentId: props.parentId,
            })
          : await props.capture.capture({
              bytes: captured.bytes,
              mimeType: captured.mimeType,
              source: captured.source,
              attachmentKind,
              parentType: props.parentType,
              parentId: props.parentId,
            });
      if (result.status === 'locked') {
        setMessage({ kind: 'warn', text: `Locked: ${result.reason}` });
        return;
      }
      setSources((prev) => ({ ...prev, [result.record.blobId]: captured.source }));
      setMessage({ kind: 'ok', text: `Captured ${attachmentKind}` });
      if (attachmentKind === 'signature') setSignatureValue(null);
      bump();
    } catch (error) {
      setMessage({
        kind: 'error',
        text:
          error instanceof Error
            ? `Capture failed: ${error.message}`
            : 'Capture failed. Your existing work is still saved.',
      });
    }
  };

  return (
    <View style={styles.screenInner}>
      <Text style={styles.heading}>Evidence Capture</Text>
      <MessageLine message={message} />
      <View style={styles.row}>
        <ActionButton
          testID="capture-field-ticket-photo"
          label="Field Photo"
          onPress={() => captureOne('field-ticket-photo', 'camera')}
        />
        <ActionButton
          testID="capture-disposal-photo"
          label="Disposal"
          onPress={() => captureOne('disposal-photo', 'camera')}
        />
        <ActionButton
          testID="capture-receipt-photo"
          label="Receipt"
          onPress={() => captureOne('receipt-photo', 'import')}
        />
        <ActionButton
          testID="capture-signature"
          label="Signature"
          onPress={() => captureOne('signature', 'signature-pad')}
        />
      </View>
      <View style={styles.card}>
        <Text style={styles.heading}>Signature</Text>
        <SignatureField
          value={signatureValue}
          onChange={setSignatureValue}
          testID="capture-signature-field"
        />
      </View>
      <View style={styles.row}>
        <ActionButton
          testID="capture-retry"
          label="Retry Upload"
          onPress={async () => {
            const report = await props.uploads.processOnce();
            setMessage({
              kind: report.deferred > 0 || report.expired > 0 ? 'warn' : 'ok',
              text: `Upload sweep uploaded ${report.uploaded} deferred ${report.deferred}`,
            });
            bump();
          }}
        />
        <ActionButton testID="capture-refresh" label="Refresh" onPress={bump} />
      </View>
      <View testID="capture-list">
        {props.blobs.list().map((blob) => {
          const linkState =
            blob.linkOpId !== undefined ? props.linkOutcome?.(blob.linkOpId) : undefined;
          const local =
            blob.purgedAt === undefined ? 'local saved local preserved' : `purged ${blob.purgedAt}`;
          const retry =
            blob.state === 'upload-expired' || blob.state === 'local-only'
              ? 'retry pending'
              : 'retry idle';
          const line =
            `${blob.attachmentKind} ${blob.blobId} source ${sources[blob.blobId] ?? 'unknown'} ` +
            `status ${captureStatus(blob, linkState)} ` +
            `${local} state ${blob.state} upload ${String(blob.uploadConfirmed)} ` +
            `link ${String(blob.linkConfirmed)} ${retry} ${linkState ?? ''}`;
          return (
            <Text key={blob.blobId} style={styles.meta}>
              {line}
            </Text>
          );
        })}
      </View>
    </View>
  );
}

export type CaptureEvidenceDevice = (input: {
  attachmentKind: sync.AttachBlobCommand['attachmentKind'];
  source: CaptureSource;
}) => Promise<{ bytes: Uint8Array; mimeType: string; source: CaptureSource } | null>;

export function PrintQueueScreen(props: { runtime: PrintRuntime; queue: printer.PrintJobQueue }) {
  const { styles } = useFieldStyles();
  const [message, setMessage] = useState<Message>(null);
  const [revision, setRevision] = useState(0);
  const bump = () => setRevision((n) => n + 1);

  return (
    <View style={styles.screenInner}>
      <Text style={styles.heading}>Print Queue</Text>
      <MessageLine message={message} />
      <View style={styles.row}>
        <ActionButton
          testID="print-process"
          label="Run Queue"
          onPress={async () => {
            const report = await props.runtime.processOnce();
            setMessage({
              kind: report.failed > 0 ? 'warn' : 'ok',
              text: `Print sweep printed ${report.printed} failed ${report.failed}`,
            });
            bump();
          }}
        />
        <ActionButton
          testID="print-reconcile"
          label="Sync Ack"
          onPress={() => {
            const synced = props.runtime.reconcileSync();
            setMessage({ kind: 'ok', text: `Synced ${synced}` });
            bump();
          }}
        />
        <ActionButton
          testID="print-purge"
          label="Purge Synced"
          onPress={() => {
            const ids = props.runtime.purgeSynced();
            setMessage({ kind: 'ok', text: `Purged ${ids.length}` });
            bump();
          }}
        />
      </View>
      <View testID="print-list">
        {props.queue.list().map((job) => (
          <Text key={job.printJobId} style={styles.meta}>
            {`${job.printJobId} status ${job.status} ${
              job.errorCode === 'printer-not-implemented' ? 'hardware-not-available' : ''
            }${job.errorCode !== null ? ` error ${job.errorCode}` : ''} synced ${String(
              job.syncedAt !== null,
            )} revision ${revision}`}
          </Text>
        ))}
      </View>
    </View>
  );
}

export function Pt210DiagnosticScreen(props: { binding?: Pt210NativeBinding }) {
  const { styles } = useFieldStyles();
  const binding = props.binding ?? loadPt210NativeBinding();
  const [devices, setDevices] = useState<Pt210DiscoveredDevice[]>([]);
  const [selectedDeviceId, setSelectedDeviceId] = useState<string | null>(null);
  const [lines, setLines] = useState<string[]>([]);

  const append = (line: string) => setLines((prev) => [line, ...prev].slice(0, 12));
  const requireBinding = (): Pt210NativeBinding => {
    if (binding === undefined) throw new printer.NotImplementedError('PT-210 native module');
    return binding;
  };
  const selected = (): string => {
    const deviceId = selectedDeviceId ?? devices[0]?.deviceId;
    if (deviceId === undefined) throw new Error('no PT-210 device selected');
    return deviceId;
  };
  const record = async (label: string, run: () => Promise<string>) => {
    try {
      append(`${label} ok: ${await run()}`);
    } catch (error) {
      const normalized = normalizePt210NativeError(error);
      const nativeCode = normalized.nativeCode !== undefined ? ` ${normalized.nativeCode}` : '';
      append(`${label} error: ${normalized.code}${nativeCode} ${normalized.message}`);
    }
  };

  return (
    <View style={styles.screenInner}>
      <Text style={styles.heading}>PT-210 Diagnostic</Text>
      <View style={styles.row}>
        <ActionButton
          testID="pt210-discover"
          label="Discover"
          onPress={() =>
            void record('discover', async () => {
              const found = await requireBinding().discover({
                timeoutMs: 10_000,
                includeUnpaired: true,
              });
              setDevices(found);
              setSelectedDeviceId(found[0]?.deviceId ?? null);
              return found.length > 0 ? found.map((d) => d.name).join(', ') : 'none';
            })
          }
        />
        <ActionButton
          testID="pt210-connect"
          label="Connect"
          onPress={() =>
            void record('connect', async () => {
              const status = await requireBinding().connect(selected(), { timeoutMs: 10_000 });
              return status.state;
            })
          }
        />
        <ActionButton
          testID="pt210-test-receipt"
          label="Test Receipt"
          onPress={() =>
            void record('print test receipt', async () => {
              const status = await requireBinding().writeBytes(createPt210TestReceipt(), {
                timeoutMs: 10_000,
              });
              return status.state;
            })
          }
        />
        <ActionButton
          testID="pt210-signature-test"
          label="Signature Test"
          onPress={() => {
            record('print signature test', async () => {
              const status = await requireBinding().writeBytes(createPt210SignatureBitmapTest(), {
                timeoutMs: 10_000,
              });
              return status.state;
            }).catch(() => undefined);
          }}
        />
        <ActionButton
          testID="pt210-status"
          label="Status"
          onPress={() =>
            void record('status', async () => {
              const status = await requireBinding().status({ timeoutMs: 5_000 });
              return status.state;
            })
          }
        />
        <ActionButton
          testID="pt210-reconnect"
          label="Reconnect"
          onPress={() =>
            void record('reconnect', async () => {
              const status = await requireBinding().reconnect({ timeoutMs: 10_000 });
              return status.state;
            })
          }
        />
        <ActionButton
          testID="pt210-disconnect"
          label="Disconnect"
          onPress={() =>
            void record('disconnect', async () => {
              const status = await requireBinding().disconnect({ timeoutMs: 5_000 });
              return status.state;
            })
          }
        />
      </View>
      <View testID="pt210-diagnostic-log">
        {lines.map((line, index) => (
          <Text key={`${line}-${index}`} style={styles.meta}>
            {line}
          </Text>
        ))}
      </View>
    </View>
  );
}

function useFieldStyles() {
  const t = useTheme();
  const styles = useMemo(() => makeStyles(t), [t]);
  return { styles, t };
}

const makeStyles = (t: Theme) =>
  StyleSheet.create({
    screenInner: {
      gap: 10,
      paddingVertical: 8,
    },
    section: {
      gap: 6,
      paddingVertical: 8,
      borderTopWidth: StyleSheet.hairlineWidth,
      borderTopColor: t.border,
    },
    heading: {
      fontSize: 15,
      fontWeight: '700',
      color: t.text,
    },
    row: {
      flexDirection: 'row',
      flexWrap: 'wrap',
      gap: 8,
      alignItems: 'center',
    },
    button: {
      minHeight: 34,
      paddingHorizontal: 12,
      paddingVertical: 8,
      borderRadius: 6,
      backgroundColor: '#1f6f8b',
    },
    buttonText: {
      color: '#fff',
      fontSize: 13,
      fontWeight: '600',
    },
    input: {
      borderWidth: 1,
      borderColor: t.border,
      borderRadius: 6,
      paddingHorizontal: 10,
      paddingVertical: 7,
      minWidth: 220,
      fontSize: 14,
      color: t.text,
    },
    meta: {
      fontSize: 12,
      color: t.textMuted,
    },
    ok: {
      fontSize: 13,
      color: t.success,
      fontWeight: '600',
    },
    warn: {
      fontSize: 13,
      color: t.warning,
      fontWeight: '600',
    },
    error: {
      fontSize: 13,
      color: t.danger,
      fontWeight: '600',
    },
    card: {
      gap: 4,
      padding: 10,
      borderRadius: 8,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: t.border,
      backgroundColor: t.card,
    },
    badge: {
      fontSize: 12,
      fontWeight: '700',
      color: t.text,
      backgroundColor: t.cardMuted,
      paddingHorizontal: 8,
      paddingVertical: 2,
      borderRadius: 10,
      overflow: 'hidden',
    },
    chip: {
      minHeight: 30,
      paddingHorizontal: 10,
      paddingVertical: 6,
      borderRadius: 14,
      borderWidth: 1,
      borderColor: t.border,
    },
    chipSelected: {
      backgroundColor: '#1f6f8b',
      borderColor: '#1f6f8b',
    },
    chipText: {
      fontSize: 12,
      color: t.textMuted,
      fontWeight: '600',
    },
    chipTextSelected: {
      color: '#fff',
    },
  });
