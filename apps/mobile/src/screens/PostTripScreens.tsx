/**
 * End-Day & Post-Trip flow (GUI Master §8 / screens 18–26) — the close-out half of the workday.
 * Screens, in order:
 *   18 EndDayReviewScreen          — hand-off from job work into the post-trip DVIR
 *   19 PostTripOverviewScreen      — start the daily post-trip inspection (truck + trailer)
 *   20 PostTripSectionScreen       — one inspection section; OK / Defect segmented control (§23.4)
 *   21 PostTripReviewScreen        — counts + defect remarks before signing
 *   22 PostTripSignatureScreen     — driver attestation + signature placeholder
 *   23 PostTripCompleteScreen      — post-trip done, points at Punch Out
 *   24 PunchOutScreen              — end-of-day summary + punch out
 *   25 PunchOutConfirmScreen       — confirm modal (or "Post-Trip Required" block)
 *   26 PunchOutSuccessScreen       — punched out, saved-on-phone reassurance
 *
 * Presentational only: every screen takes primitive props + callbacks and imports ONLY from
 * '../design'. No domain/runtime/data imports, no native modules. DVIR uses OK / Defect segmented
 * controls (never checkboxes) so "checked = defective" can never be ambiguous (§23.4). Driver-facing
 * language only — no UUIDs, hashes, payloads, queues, or hub URLs (§20). Status labels come from the
 * approved §20 set.
 */
import { useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { fieldwork } from '@fieldcapture/contracts';

import {
  Button,
  Card,
  SignatureField,
  StatusBadge,
  spacing,
  typeScale,
  sizing,
  useResolvedTheme,
  type SignatureValue,
  type Theme,
  type Tone,
} from '../design';

/* ------------------------------------------------------------------------------------------------ */
/* Shared local types + small presentational helpers                                                */
/* ------------------------------------------------------------------------------------------------ */

/** A single DVIR line item's outcome. Segmented (§23.4) — never a checkbox. */
export type InspectionResult = 'not-checked' | 'ok' | 'defect';

export interface PostTripItem {
  key: string;
  label: string;
  result: InspectionResult;
}

/** A pending-sync line shown as reassurance ("saved on this phone"). */
export interface SyncSummaryItem {
  key: string;
  label: string;
}

/** A line in the end-of-day summary (status reinforced by a §20 badge). */
export interface DaySummaryLine {
  key: string;
  label: string;
  value: string;
  tone: Tone;
}

/** Screen title + optional one-line caption — the consistent header used across this flow. */
function ScreenHeader(props: { title: string; caption?: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.headerBlock}>
      <Text style={[styles.h1, { color: t.text }]}>{props.title}</Text>
      {props.caption !== undefined ? (
        <Text style={[styles.caption, { color: t.textMuted }]}>{props.caption}</Text>
      ) : null}
    </View>
  );
}

/** A label/value row, e.g. "Odometer End  125,184". */
function FactRow(props: { label: string; value: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.factRow}>
      <Text style={[styles.factLabel, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.factValue, { color: t.text }]}>{props.value}</Text>
    </View>
  );
}

/** The "Next required step" highlight card reused by hand-off screens (§8). */
function NextStepCard(props: {
  stepLabel: string;
  primaryLabel: string;
  onPrimary: () => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  return (
    <Card
      theme={t}
      tone="highlight"
      title="Next required step"
      {...(props.testID !== undefined ? { testID: props.testID } : {})}
    >
      <Text style={[styles.nextTitle, { color: t.text }]}>{props.stepLabel}</Text>
      <Button theme={t} label={props.primaryLabel} onPress={props.onPrimary} />
    </Card>
  );
}

/**
 * OK / Defect segmented control (GUI Master §23.4). Three explicit states so a tap is never
 * ambiguous: Not Checked is the neutral default, OK is pass, Defect is fail. "Defect" is the only
 * thing that reads as a problem — there is no checkbox whose "checked" could mean either.
 */
function ResultSegment(props: {
  value: InspectionResult;
  onChange: (next: InspectionResult) => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  const options: readonly { key: InspectionResult; label: string; tone: Tone }[] = [
    { key: 'not-checked', label: 'Not Checked', tone: 'neutral' },
    { key: 'ok', label: 'OK', tone: 'success' },
    { key: 'defect', label: 'Defect', tone: 'danger' },
  ];
  return (
    <View style={[styles.segment, { borderColor: t.border }]} testID={props.testID}>
      {options.map((opt) => {
        const selected = opt.key === props.value;
        const accent =
          opt.tone === 'success' ? t.success : opt.tone === 'danger' ? t.danger : t.textMuted;
        return (
          <Pressable
            key={opt.key}
            testID={props.testID !== undefined ? `${props.testID}-${opt.key}` : undefined}
            onPress={() => props.onChange(opt.key)}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            accessibilityLabel={opt.label}
            style={[
              styles.segmentCell,
              { borderColor: t.border },
              selected ? { backgroundColor: accent } : null,
            ]}
          >
            <Text
              style={[styles.segmentText, { color: selected ? t.onPrimary : t.textMuted }]}
              numberOfLines={1}
            >
              {opt.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/**
 * A secondary action that has no real wiring yet (Review Jobs, View Sync, Contact Dispatch, …). On
 * tap it flips internal state so an inline confirmation line appears, AND still calls the optional
 * host callback. Never a silent no-op — the driver always sees the tap land.
 */
function FeedbackButton(props: {
  label: string;
  confirmation: string;
  onPress?: () => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  const [acted, setActed] = useState<boolean>(false);
  const press = () => {
    setActed(true);
    props.onPress?.();
  };
  return (
    <>
      <Button
        theme={t}
        variant="secondary"
        label={props.label}
        onPress={press}
        {...(props.testID !== undefined ? { testID: props.testID } : {})}
      />
      {acted ? (
        <Text
          style={[styles.confirmLine, { color: t.success }]}
          testID={props.testID !== undefined ? `${props.testID}-confirm` : undefined}
        >
          {props.confirmation}
        </Text>
      ) : null}
    </>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 18. End Day Review                                                                                */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 18 — End Day Review. Transition from job work to post-trip. Summarizes how the day went
 * (jobs completed, field tickets submitted, items still syncing) and points firmly at the one
 * required next step: the driver post-trip inspection.
 */
export function EndDayReviewScreen(props: {
  jobsCompleted?: number;
  jobsTotal?: number;
  ticketsSubmitted?: number;
  pendingSync?: number;
  onStartPostTrip: () => void;
  onReviewJobs?: () => void;
  onViewSync?: () => void;
  onContactDispatch: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const jobsCompleted = props.jobsCompleted ?? 3;
  const jobsTotal = props.jobsTotal ?? 3;
  const ticketsSubmitted = props.ticketsSubmitted ?? 3;
  const pendingSync = props.pendingSync ?? 4;

  return (
    <View style={styles.body}>
      <ScreenHeader title="End Day" caption="Wrap up today and start your post-trip." theme={t} />

      <Card theme={t} title="Today’s summary" testID="end-day-summary">
        <FactRow label="Jobs completed" value={`${jobsCompleted} of ${jobsTotal}`} theme={t} />
        <FactRow label="Field tickets" value={`${ticketsSubmitted} submitted`} theme={t} />
        <View style={styles.factRow}>
          <Text style={[styles.factLabel, { color: t.textMuted }]}>Pending sync</Text>
          <StatusBadge
            label={pendingSync === 0 ? 'Synced' : 'Pending Sync'}
            tone={pendingSync === 0 ? 'success' : 'warning'}
            testID="end-day-sync-badge"
          />
        </View>
        {pendingSync > 0 ? (
          <Text style={[styles.body2, { color: t.textMuted }]}>
            {`${pendingSync} item${pendingSync === 1 ? '' : 's'} saved on this phone, syncing when connected.`}
          </Text>
        ) : null}
      </Card>

      <NextStepCard
        stepLabel="Driver Post-Trip Inspection"
        primaryLabel="Start Post-Trip"
        onPrimary={props.onStartPostTrip}
        testID="end-day-next"
        theme={t}
      />

      <Card theme={t} title="More options">
        {props.onReviewJobs !== undefined ? (
          <FeedbackButton
            theme={t}
            label="Review Jobs"
            confirmation="Opening today’s jobs…"
            onPress={props.onReviewJobs}
            testID="end-day-review-jobs"
          />
        ) : null}
        {props.onViewSync !== undefined ? (
          <FeedbackButton
            theme={t}
            label="View Sync"
            confirmation="Opening sync status…"
            onPress={props.onViewSync}
            testID="end-day-view-sync"
          />
        ) : null}
        <FeedbackButton
          theme={t}
          label="Contact Dispatch"
          confirmation="Calling dispatch…"
          onPress={props.onContactDispatch}
          testID="end-day-dispatch"
        />
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 19. Driver Post-Trip Overview                                                                     */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 19 — Driver Post-Trip Overview. Starts the daily post-trip DVIR. Names the rig the driver
 * is closing out and the ending odometer, and makes clear the inspection is required before punching
 * out.
 */
export function PostTripOverviewScreen(props: {
  truck?: string;
  trailer?: string;
  odometerEnd?: string;
  onBegin: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const truck = props.truck ?? 'Truck 7';
  const trailer = props.trailer ?? 'Vacuum Trailer 19';
  const odometerEnd = props.odometerEnd ?? '125,184';

  return (
    <View style={styles.body}>
      <ScreenHeader title="Driver Post-Trip Inspection" theme={t} />

      <Card
        theme={t}
        tone="highlight"
        title="Required before punching out"
        testID="post-trip-required-card"
      >
        <View style={styles.row}>
          <StatusBadge label="Required" tone="warning" testID="post-trip-required-badge" />
        </View>
        <Text style={[styles.body2, { color: t.text }]}>
          Check the truck and trailer for any damage or problems from today’s work before you end
          your day.
        </Text>
      </Card>

      <Card theme={t} title="Equipment" testID="post-trip-equipment">
        <FactRow label="Truck" value={truck} theme={t} />
        <FactRow label="Trailer" value={trailer} theme={t} />
        <FactRow label="Odometer End" value={odometerEnd} theme={t} />
      </Card>

      <Button theme={t} label="Begin Post-Trip" onPress={props.onBegin} testID="post-trip-begin" />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 20. Driver Post-Trip Section                                                                      */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 20 — Driver Post-Trip Section. One inspection section (mirrors the pre-trip sections) with
 * a Not Checked | OK | Defect segmented control per item (§23.4). Post-trip wording: report defects
 * found during or after today’s work. The component owns the per-item state locally and reports each
 * change up via onChangeItem so the host can persist.
 */
export function PostTripSectionScreen(props: {
  sectionTitle?: string;
  sectionIndex?: number;
  sectionCount?: number;
  items?: PostTripItem[];
  onChangeItem?: (key: string, result: InspectionResult) => void;
  onContinue: () => void;
  onBack?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sectionTitle = props.sectionTitle ?? 'Engine & Cab';
  const sectionIndex = props.sectionIndex ?? 1;
  const sectionCount = props.sectionCount ?? 6;

  const initial: PostTripItem[] = props.items ?? [
    { key: 'fluids', label: 'Fluid leaks (oil, coolant, fuel)', result: 'not-checked' },
    { key: 'brakes', label: 'Brakes & air lines', result: 'not-checked' },
    { key: 'lights', label: 'Lights & reflectors', result: 'not-checked' },
    { key: 'tires', label: 'Tires & wheels', result: 'not-checked' },
    { key: 'mirrors', label: 'Mirrors & windshield', result: 'not-checked' },
  ];

  const [items, setItems] = useState<PostTripItem[]>(initial);

  const setResult = (key: string, result: InspectionResult) => {
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, result } : it)));
    props.onChangeItem?.(key, result);
  };

  const checked = items.filter((it) => it.result !== 'not-checked').length;
  const defects = items.filter((it) => it.result === 'defect').length;
  const allChecked = checked === items.length;

  return (
    <View style={styles.body}>
      <ScreenHeader
        title={sectionTitle}
        caption={`Section ${sectionIndex} of ${sectionCount}`}
        theme={t}
      />

      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          Report any defects found during or after today’s work.
        </Text>
        <View style={styles.row}>
          <StatusBadge
            label={allChecked ? (defects > 0 ? 'Needs Review' : 'Complete') : 'In Progress'}
            tone={allChecked ? (defects > 0 ? 'danger' : 'success') : 'info'}
            testID="post-trip-section-status"
          />
          <Text style={[styles.meta, { color: t.textMuted }]}>
            {`${checked} of ${items.length} checked`}
          </Text>
        </View>
      </Card>

      {items.map((item) => (
        <Card key={item.key} theme={t} testID={`post-trip-item-${item.key}`}>
          <Text style={[styles.itemLabel, { color: t.text }]}>{item.label}</Text>
          <ResultSegment
            value={item.result}
            onChange={(next) => setResult(item.key, next)}
            testID={`post-trip-segment-${item.key}`}
            theme={t}
          />
        </Card>
      ))}

      {props.onBack !== undefined ? (
        <Button
          theme={t}
          variant="secondary"
          label="Back"
          onPress={props.onBack}
          testID="post-trip-section-back"
        />
      ) : null}
      <Button
        theme={t}
        label="Continue"
        onPress={props.onContinue}
        disabled={!allChecked}
        testID="post-trip-section-continue"
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 21. Driver Post-Trip Review                                                                       */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 21 — Driver Post-Trip Review. Roll-up of the truck/trailer item counts and any defects with
 * remarks, before the driver signs. The remarks field is editable so the driver can clarify before
 * attesting.
 */
export function PostTripReviewScreen(props: {
  truckChecked?: number;
  truckTotal?: number;
  trailerChecked?: number;
  trailerTotal?: number;
  defects?: number;
  remarks?: string;
  onChangeRemarks?: (text: string) => void;
  onContinue: () => void;
  onBack?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const truckChecked = props.truckChecked ?? 45;
  const truckTotal = props.truckTotal ?? 45;
  const trailerChecked = props.trailerChecked ?? 16;
  const trailerTotal = props.trailerTotal ?? 16;
  const defects = props.defects ?? 1;

  const [remarks, setRemarks] = useState<string>(props.remarks ?? 'Right rear trailer light dim');
  const onRemarks = (text: string) => {
    setRemarks(text);
    props.onChangeRemarks?.(text);
  };

  const truckComplete = truckChecked === truckTotal;
  const trailerComplete = trailerChecked === trailerTotal;

  return (
    <View style={styles.body}>
      <ScreenHeader
        title="Post-Trip Review"
        caption="Confirm everything before you sign."
        theme={t}
      />

      <Card theme={t} title="Items checked" testID="post-trip-review-counts">
        <View style={styles.factRow}>
          <Text style={[styles.factLabel, { color: t.textMuted }]}>Truck items checked</Text>
          <View style={styles.row}>
            <Text
              style={[styles.factValue, { color: t.text }]}
            >{`${truckChecked} of ${truckTotal}`}</Text>
            <StatusBadge
              label={truckComplete ? 'Complete' : 'In Progress'}
              tone={truckComplete ? 'success' : 'info'}
            />
          </View>
        </View>
        <View style={styles.factRow}>
          <Text style={[styles.factLabel, { color: t.textMuted }]}>Trailer items checked</Text>
          <View style={styles.row}>
            <Text
              style={[styles.factValue, { color: t.text }]}
            >{`${trailerChecked} of ${trailerTotal}`}</Text>
            <StatusBadge
              label={trailerComplete ? 'Complete' : 'In Progress'}
              tone={trailerComplete ? 'success' : 'info'}
            />
          </View>
        </View>
      </Card>

      <Card
        theme={t}
        tone={defects > 0 ? 'highlight' : 'default'}
        title="Defects"
        testID="post-trip-review-defects"
      >
        <View style={styles.row}>
          <StatusBadge
            label={defects > 0 ? 'Needs Review' : 'Complete'}
            tone={defects > 0 ? 'danger' : 'success'}
            testID="post-trip-defects-badge"
          />
          <Text style={[styles.factValue, { color: t.text }]}>
            {defects === 0 ? 'No defects found' : `${defects} defect${defects === 1 ? '' : 's'}`}
          </Text>
        </View>
        <Text style={[styles.factLabel, { color: t.textMuted }]}>Remarks</Text>
        <TextInput
          style={[
            styles.input,
            { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
          ]}
          value={remarks}
          onChangeText={onRemarks}
          placeholder="Describe any defect found"
          placeholderTextColor={t.textMuted}
          multiline
          accessibilityLabel="Defect remarks"
          testID="post-trip-remarks"
        />
      </Card>

      {props.onBack !== undefined ? (
        <Button
          theme={t}
          variant="secondary"
          label="Back"
          onPress={props.onBack}
          testID="post-trip-review-back"
        />
      ) : null}
      <Button
        theme={t}
        label="Continue to Signature"
        onPress={props.onContinue}
        testID="post-trip-review-continue"
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 22. Driver Post-Trip Signature                                                                    */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 22 — Driver Post-Trip Signature. Attestation plus a signature placeholder (a bordered
 * preview frame — the real capture is wired on-device). The driver taps Sign to fill the pad, then
 * Complete Post-Trip is enabled.
 */
export function PostTripSignatureScreen(props: {
  driverName?: string;
  signed?: boolean;
  onSign?: () => void;
  onClear?: () => void;
  /** Driver attestation shown above the pad; defaults to the canonical DVIR post-trip text. */
  certificationText?: string;
  onComplete: (payload: { signature: SignatureValue; signerName: string }) => void;
  onBack?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const driverName = props.driverName ?? '';
  const [signature, setSignature] = useState<SignatureValue | null>(null);
  const signed = signature !== null;

  return (
    <View style={styles.body}>
      <ScreenHeader title="Driver Signature" theme={t} />

      <Card theme={t} tone="highlight" testID="post-trip-attestation">
        <Text style={[styles.attest, { color: t.text }]}>
          {props.certificationText ?? fieldwork.DVIR_POSTTRIP_CERTIFICATION_TEXT}
        </Text>
        {driverName.trim().length > 0 ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>{driverName}</Text>
        ) : null}
      </Card>

      <Card theme={t} title="Signature">
        <SignatureField
          theme={t}
          value={signature}
          onChange={(next) => {
            setSignature(next);
            if (next === null) props.onClear?.();
            else props.onSign?.();
          }}
          testID="post-trip-signature"
        />
        <View style={styles.row}>
          <StatusBadge
            label={signed ? 'Saved on Phone' : 'Required'}
            tone={signed ? 'success' : 'warning'}
            testID="post-trip-sign-status"
          />
        </View>
      </Card>

      {props.onBack !== undefined ? (
        <Button
          theme={t}
          variant="secondary"
          label="Back"
          onPress={props.onBack}
          testID="post-trip-sign-back"
        />
      ) : null}
      <Button
        theme={t}
        label="Complete Post-Trip"
        onPress={() => {
          if (signature !== null) props.onComplete({ signature, signerName: driverName });
        }}
        disabled={!signed}
        testID="post-trip-complete"
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 23. Driver Post-Trip Complete                                                                     */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 23 — Driver Post-Trip Complete. Confirms the post-trip is done and routes the driver to the
 * final required step of the day: Punch Out.
 */
export function PostTripCompleteScreen(props: {
  defects?: number;
  onPunchOut: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const defects = props.defects ?? 1;

  return (
    <View style={styles.body}>
      <ScreenHeader title="Post-Trip Complete" theme={t} />

      <Card theme={t} title="Inspection saved" testID="post-trip-complete-card">
        <View style={styles.row}>
          <StatusBadge label="Complete" tone="success" testID="post-trip-complete-badge" />
          {defects > 0 ? (
            <StatusBadge label="Needs Review" tone="danger" testID="post-trip-complete-defects" />
          ) : null}
        </View>
        <Text style={[styles.body2, { color: t.text }]}>
          {defects > 0
            ? `Your post-trip is saved on this phone. ${defects} defect${defects === 1 ? '' : 's'} flagged for the shop.`
            : 'Your post-trip is saved on this phone and will sync when connected.'}
        </Text>
      </Card>

      <NextStepCard
        stepLabel="Punch Out"
        primaryLabel="Punch Out"
        onPrimary={props.onPunchOut}
        testID="post-trip-complete-next"
        theme={t}
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 24. Punch Out                                                                                      */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 24 — Punch Out. The end-of-day command card: punch-in/now times, a status roll-up of the
 * whole day (pre-trip, jobs, tickets, post-trip, sync), and the punch-out action. Each summary line
 * carries an approved §20 status badge so state reads without color alone.
 */
export function PunchOutScreen(props: {
  punchedInAt?: string;
  currentTime?: string;
  summary?: DaySummaryLine[];
  onPunchOut: () => void;
  onReviewJobs: () => void;
  onViewSync: () => void;
  onContactDispatch: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const punchedInAt = props.punchedInAt ?? '6:02 AM';
  const currentTime = props.currentTime ?? '5:41 PM';

  const summary: DaySummaryLine[] = props.summary ?? [
    { key: 'pre-trip', label: 'Pre-Trip', value: 'Complete', tone: 'success' },
    { key: 'jobs', label: 'Jobs', value: '3 complete', tone: 'success' },
    { key: 'tickets', label: 'Field Tickets', value: '3 submitted', tone: 'success' },
    { key: 'post-trip', label: 'Post-Trip', value: 'Complete', tone: 'success' },
    { key: 'sync', label: 'Sync', value: '4 pending', tone: 'warning' },
  ];

  return (
    <View style={styles.body}>
      <ScreenHeader title="Ready to Punch Out" theme={t} />

      <Card theme={t} title="Workday" testID="punch-out-times">
        <View style={styles.row}>
          <StatusBadge label="Punched In" tone="success" testID="punch-out-state" />
        </View>
        <FactRow label="Punched in" value={punchedInAt} theme={t} />
        <FactRow label="Current time" value={currentTime} theme={t} />
      </Card>

      <Card theme={t} title="Today’s Summary" testID="punch-out-summary">
        {summary.map((line) => (
          <View key={line.key} style={styles.factRow} testID={`punch-out-${line.key}`}>
            <Text style={[styles.factLabel, { color: t.textMuted }]}>{line.label}</Text>
            <View style={styles.row}>
              <Text style={[styles.factValue, { color: t.text }]}>{line.value}</Text>
              <StatusBadge label={summaryBadgeLabel(line)} tone={line.tone} />
            </View>
          </View>
        ))}
      </Card>

      <Button theme={t} label="Punch Out" onPress={props.onPunchOut} testID="punch-out-primary" />

      <Card theme={t} title="More options">
        <FeedbackButton
          theme={t}
          label="Review Jobs"
          confirmation="Opening today’s jobs…"
          onPress={props.onReviewJobs}
          testID="punch-out-review-jobs"
        />
        <FeedbackButton
          theme={t}
          label="View Sync"
          confirmation="Opening sync status…"
          onPress={props.onViewSync}
          testID="punch-out-view-sync"
        />
        <FeedbackButton
          theme={t}
          label="Contact Dispatch"
          confirmation="Calling dispatch…"
          onPress={props.onContactDispatch}
          testID="punch-out-dispatch"
        />
      </Card>
    </View>
  );
}

/** Map a summary line to a short §20 badge label (the value text carries the detail). */
function summaryBadgeLabel(line: DaySummaryLine): string {
  if (line.tone === 'warning') return 'Pending Sync';
  if (line.tone === 'danger') return 'Needs Review';
  if (line.tone === 'info') return 'In Progress';
  return 'Complete';
}

/* ------------------------------------------------------------------------------------------------ */
/* 25. Punch Out Confirmation                                                                         */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 25 — Punch Out Confirmation. Rendered as an inline modal surface (no native Modal dep). Two
 * modes:
 *   - postTripComplete = true  → "Punch out?" confirm with Cancel / Punch Out.
 *   - postTripComplete = false → "Post-Trip Required" block that routes back to the inspection.
 */
export function PunchOutConfirmScreen(props: {
  postTripComplete?: boolean;
  pendingSync?: number;
  onConfirm: () => void;
  onCancel: () => void;
  onGoToPostTrip?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const postTripComplete = props.postTripComplete ?? true;
  const pendingSync = props.pendingSync ?? 4;

  if (!postTripComplete) {
    return (
      <View style={[styles.modalScrim, { backgroundColor: t.background }]}>
        <Card theme={t} tone="highlight" title="Post-Trip Required" testID="punch-out-blocked">
          <View style={styles.row}>
            <StatusBadge label="Blocked" tone="danger" testID="punch-out-blocked-badge" />
          </View>
          <Text style={[styles.body2, { color: t.text }]}>
            Complete your Post-Trip Inspection before punching out.
          </Text>
          {props.onGoToPostTrip !== undefined ? (
            <Button
              theme={t}
              label="Go to Post-Trip"
              onPress={props.onGoToPostTrip}
              testID="punch-out-goto-post-trip"
            />
          ) : null}
          <Button
            theme={t}
            variant="secondary"
            label="Cancel"
            onPress={props.onCancel}
            testID="punch-out-blocked-cancel"
          />
        </Card>
      </View>
    );
  }

  return (
    <View style={[styles.modalScrim, { backgroundColor: t.background }]}>
      <Card theme={t} title="Punch out?" testID="punch-out-confirm">
        <Text style={[styles.body2, { color: t.text }]}>This will end your workday.</Text>
        <Text style={[styles.body2, { color: t.textMuted }]}>
          {pendingSync > 0
            ? `Any saved work on this phone will continue syncing when connected (${pendingSync} item${pendingSync === 1 ? '' : 's'} pending).`
            : 'Any saved work on this phone will continue syncing when connected.'}
        </Text>
        <Button
          theme={t}
          label="Punch Out"
          onPress={props.onConfirm}
          testID="punch-out-confirm-yes"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Cancel"
          onPress={props.onCancel}
          testID="punch-out-confirm-cancel"
        />
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* 26. Punch Out Success                                                                              */
/* ------------------------------------------------------------------------------------------------ */

/**
 * Screen 26 — Punch Out Success. Confirms the workday ended and reassures the driver that any saved
 * work is safe on the phone and will sync when connected. Primary routes to Sync; secondary is Done.
 */
export function PunchOutSuccessScreen(props: {
  endedAt?: string;
  pendingSync?: number;
  onViewSync: () => void;
  onDone: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const endedAt = props.endedAt ?? '5:41 PM';
  const pendingSync = props.pendingSync ?? 4;

  return (
    <View style={styles.body}>
      <ScreenHeader title="Punched Out" theme={t} />

      <Card theme={t} tone="highlight" title="Workday ended" testID="punch-out-success">
        <View style={styles.row}>
          <StatusBadge label="Punched Out" tone="neutral" testID="punch-out-success-badge" />
        </View>
        <Text style={[styles.body2, { color: t.text }]}>{`Workday ended at ${endedAt}.`}</Text>
        {pendingSync > 0 ? (
          <Text style={[styles.body2, { color: t.text }]}>
            {`${pendingSync} item${pendingSync === 1 ? '' : 's'} ${pendingSync === 1 ? 'is' : 'are'} saved on this phone and will sync when connected.`}
          </Text>
        ) : (
          <Text style={[styles.body2, { color: t.text }]}>
            All your work is saved and up to date.
          </Text>
        )}
      </Card>

      <Button
        theme={t}
        label="View Sync"
        onPress={props.onViewSync}
        testID="punch-out-success-view-sync"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Done"
        onPress={props.onDone}
        testID="punch-out-success-done"
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------ */
/* Styles                                                                                             */
/* ------------------------------------------------------------------------------------------------ */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  headerBlock: {
    gap: spacing.xs,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  caption: {
    fontSize: typeScale.label,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    flexWrap: 'wrap',
  },
  meta: {
    fontSize: typeScale.label,
  },
  confirmLine: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  nextTitle: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  factRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 6,
    gap: spacing.sm,
  },
  factLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  factValue: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  itemLabel: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  segment: {
    flexDirection: 'row',
    borderWidth: 1,
    borderRadius: sizing.radius,
    overflow: 'hidden',
  },
  segmentCell: {
    flex: 1,
    minHeight: sizing.minTouchTarget,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.xs,
    borderLeftWidth: StyleSheet.hairlineWidth,
  },
  segmentText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  input: {
    minHeight: sizing.minTouchTarget,
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    fontSize: typeScale.body,
    textAlignVertical: 'top',
  },
  attest: {
    fontSize: typeScale.heading,
    fontWeight: '700',
    lineHeight: 27,
  },
  signPad: {
    minHeight: 120,
    borderWidth: 1,
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xs,
  },
  signScript: {
    fontSize: typeScale.title,
    fontWeight: '700',
    fontStyle: 'italic',
  },
  signHint: {
    fontSize: typeScale.label,
  },
  modalScrim: {
    flex: 1,
    padding: spacing.lg,
    justifyContent: 'center',
    gap: spacing.md,
  },
});
