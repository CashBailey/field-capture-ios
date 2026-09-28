/**
 * Driver Pre-Trip Inspection (GUI Master §7 / screens 12–17) — the daily DVIR flow a driver
 * completes before any job work unlocks: Overview → Section → Defect Detail → Review → Signature →
 * Complete.
 *
 * Company DVIR rule (GUI Master §23.4): inspection items use an OK / Defect segmented control, NOT
 * checkboxes — on this company's paper DVIR a *checked* item means a *defective* item, so a checkbox
 * would be dangerously ambiguous. Selecting "Defect" opens Defect Detail.
 *
 * Self-managing controls: every toggle, segmented control, chip, and input owns its own state so it
 * visibly responds the instant a gloved thumb taps it. Optional callbacks are still fired for the
 * host, and required nav callbacks (onBegin/onContinue/onComplete/…) drive the app's routing.
 *
 * Presentational only. No domain/runtime imports, no native modules: camera, signature pad, and GPS
 * are bordered placeholder frames + Buttons with inline confirmation; real capture is wired
 * elsewhere. Driver-facing language only — no UUIDs, payloads, queues, or env strings.
 */
import { useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { fieldwork } from '@fieldcapture/contracts';

import {
  Button,
  Card,
  SignatureField,
  StatusBadge,
  sizing,
  spacing,
  typeScale,
  useResolvedTheme,
  type SignatureValue,
  type Theme,
} from '../design';

// ---------------------------------------------------------------------------
// Shared local types (primitive fields + callbacks only)
// ---------------------------------------------------------------------------

/** A driver's per-item inspection result. "not-checked" is the untouched default. */
export type InspectionResult = 'not-checked' | 'ok' | 'defect';

/** Defect severity (GUI Master §14, used only when company policy supports it). */
export type DefectSeverity = 'minor' | 'needs-review' | 'unsafe';

const RESULT_OPTIONS: readonly { key: InspectionResult; label: string }[] = [
  { key: 'not-checked', label: 'Not Checked' },
  { key: 'ok', label: 'OK' },
  { key: 'defect', label: 'Defect' },
];

const SEVERITY_OPTIONS: readonly { key: DefectSeverity; label: string }[] = [
  { key: 'minor', label: 'Minor' },
  { key: 'needs-review', label: 'Needs Review' },
  { key: 'unsafe', label: 'Unsafe' },
];

// ---------------------------------------------------------------------------
// 12. Driver Pre-Trip Overview
// ---------------------------------------------------------------------------

export function PreTripOverviewScreen(props: {
  truck?: string;
  trailer?: string;
  odometerBegin?: string;
  /** Where the driver left off, e.g. "Not Started" or "In Progress". */
  status?: 'Not Started' | 'In Progress' | 'Required';
  onBeginInspection: () => void;
  onSaveDraft?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const truck = props.truck ?? 'Truck 7';
  const trailer = props.trailer ?? 'Vacuum Trailer 19';
  const odometer = props.odometerBegin ?? '124,882';
  const status = props.status ?? 'Required';

  const [draftSaved, setDraftSaved] = useState(false);

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Driver Pre-Trip Inspection</Text>

      <Card theme={t} tone="highlight" testID="pretrip-overview-intro">
        <StatusBadge label={status} tone={status === 'In Progress' ? 'info' : 'warning'} />
        <Text style={[styles.body2, { color: t.text }]}>Required before starting job work.</Text>
      </Card>

      <Card theme={t} title="Vehicle">
        <FieldRow theme={t} label="Truck" value={truck} />
        <FieldRow theme={t} label="Trailer" value={trailer} />
        <FieldRow theme={t} label="Odometer Begin" value={odometer} />
      </Card>

      <Card theme={t} title="Inspection method">
        <Text style={[styles.body2, { color: t.textMuted }]}>
          Mark each item OK or Defect. A Defect opens a short report so the shop knows what is
          wrong.
        </Text>
      </Card>

      <Button
        theme={t}
        label="Begin Inspection"
        onPress={props.onBeginInspection}
        testID="pretrip-begin"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Save Draft"
        onPress={() => {
          setDraftSaved(true);
          props.onSaveDraft?.();
        }}
        testID="pretrip-save-draft"
      />
      {draftSaved ? (
        <Text style={[styles.confirmLine, { color: t.success }]} testID="pretrip-draft-saved">
          Saved on this phone
        </Text>
      ) : null}
    </View>
  );
}

// ---------------------------------------------------------------------------
// 13. Driver Pre-Trip Section
// ---------------------------------------------------------------------------

export interface InspectionItem {
  key: string;
  label: string;
  result: InspectionResult;
  /** Which vehicle the item belongs to — drives the truck/trailer split on Review. */
  group?: 'truck' | 'trailer';
}

/** Real, derived inspection totals — replaces the old hardcoded "45/45, 0 defects". */
export interface InspectionSummary {
  total: number;
  checked: number;
  defectCount: number;
  truckChecked: number;
  truckTotal: number;
  trailerChecked: number;
  trailerTotal: number;
  /** True only when every item has been marked OK or Defect (nothing left "not-checked"). */
  allChecked: boolean;
}

/**
 * Summarize an inspection from the driver's actual per-item results. This is what gates Continue and
 * feeds the Review screen — a DVIR can no longer report "complete" on items that were never touched.
 */
export function summarizeInspection(
  items: readonly InspectionItem[],
  results: Record<string, InspectionResult>,
): InspectionSummary {
  let checked = 0;
  let defectCount = 0;
  let truckChecked = 0;
  let truckTotal = 0;
  let trailerChecked = 0;
  let trailerTotal = 0;
  for (const item of items) {
    const result = results[item.key] ?? item.result ?? 'not-checked';
    const isTruck = (item.group ?? 'truck') === 'truck';
    if (isTruck) truckTotal++;
    else trailerTotal++;
    if (result !== 'not-checked') {
      checked++;
      if (isTruck) truckChecked++;
      else trailerChecked++;
    }
    if (result === 'defect') defectCount++;
  }
  return {
    total: items.length,
    checked,
    defectCount,
    truckChecked,
    truckTotal,
    trailerChecked,
    trailerTotal,
    allChecked: items.length > 0 && checked === items.length,
  };
}

export function PreTripSectionScreen(props: {
  /** Heading for the inspection — the whole DVIR is one scrollable page (company policy). */
  sectionName?: string;
  items?: InspectionItem[];
  onSetResult?: (itemKey: string, result: InspectionResult) => void;
  /** Called when "Defect" is chosen so the host can open Defect Detail (screen 14). */
  onOpenDefect?: (itemKey: string) => void;
  /** Fired with the real, driver-entered totals — never advances until every item is marked. */
  onContinue: (summary: InspectionSummary) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sectionName = props.sectionName ?? 'Vehicle Inspection';

  // Self-managing per-item results: seed a key→result map from the incoming items so each row
  // re-renders highlighted the moment its OK/Defect option is tapped.
  const seedItems = props.items ?? DEFAULT_SECTION_ITEMS;
  const [results, setResults] = useState<Record<string, InspectionResult>>(() =>
    Object.fromEntries(seedItems.map((item) => [item.key, item.result])),
  );

  const summary = summarizeInspection(seedItems, results);
  const remaining = summary.total - summary.checked;
  const truckItems = seedItems.filter((i) => (i.group ?? 'truck') === 'truck');
  const trailerItems = seedItems.filter((i) => i.group === 'trailer');

  const renderItem = (item: InspectionItem) => {
    const value = results[item.key] ?? 'not-checked';
    return (
      <View key={item.key} style={styles.itemRow} testID={`pretrip-item-${item.key}`}>
        <Text style={[styles.itemLabel, { color: t.text }]}>{item.label}</Text>
        <Segmented
          theme={t}
          testID={`pretrip-item-${item.key}-control`}
          value={value}
          options={RESULT_OPTIONS}
          onSelect={(next) => {
            setResults((prev) => ({ ...prev, [item.key]: next }));
            props.onSetResult?.(item.key, next);
            if (next === 'defect') props.onOpenDefect?.(item.key);
          }}
        />
      </View>
    );
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>{sectionName}</Text>

      <Card theme={t} testID="pretrip-section-progress">
        <View style={styles.row}>
          <StatusBadge
            label={summary.allChecked ? 'Ready' : 'In Progress'}
            tone={summary.allChecked ? 'success' : 'info'}
          />
          <Text style={[styles.meta, { color: t.textMuted }]}>
            {summary.checked} of {summary.total} items checked
          </Text>
        </View>
      </Card>

      <Card theme={t} title="Truck">
        {truckItems.map(renderItem)}
      </Card>

      {trailerItems.length > 0 ? (
        <Card theme={t} title="Trailer">
          {trailerItems.map(renderItem)}
        </Card>
      ) : null}

      {!summary.allChecked ? (
        <Text style={[styles.gateHint, { color: t.warning }]} testID="pretrip-continue-hint">
          Mark every item OK or Defect to continue — {remaining} item{remaining === 1 ? '' : 's'} to
          go.
        </Text>
      ) : null}

      <Button
        theme={t}
        label="Continue"
        onPress={() => props.onContinue(summary)}
        disabled={!summary.allChecked}
        testID="pretrip-continue"
      />
    </View>
  );
}

// ---------------------------------------------------------------------------
// 14. Defect Detail
// ---------------------------------------------------------------------------

export function DefectDetailScreen(props: {
  /** The item being reported, e.g. "Brakes, Service". */
  itemName?: string;
  remarks?: string;
  onChangeRemarks?: (next: string) => void;
  requiresReview?: boolean;
  onToggleRequiresReview?: (next: boolean) => void;
  /** Severity is optional — only shown when company policy supports it. */
  showSeverity?: boolean;
  severity?: DefectSeverity;
  onSelectSeverity?: (next: DefectSeverity) => void;
  photoCount?: number;
  onAddPhoto?: () => void;
  onSaveDefect: () => void;
  onCancel: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const itemName = props.itemName ?? 'Brakes, Service';
  const showSeverity = props.showSeverity ?? false;

  const [remarks, setRemarks] = useState(props.remarks ?? '');
  const [requiresReview, setRequiresReview] = useState(props.requiresReview ?? false);
  const [severity, setSeverity] = useState<DefectSeverity>(props.severity ?? 'minor');
  const [photoCount, setPhotoCount] = useState(props.photoCount ?? 0);
  const [photoAdded, setPhotoAdded] = useState(false);

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Defect Reported</Text>

      <Card theme={t} title="Item">
        <Text style={[styles.body2, { color: t.text }]}>{itemName}</Text>
        <StatusBadge label="Needs Review" tone="warning" />
      </Card>

      <Card theme={t} title="What is wrong?">
        <TextInput
          testID="defect-remarks"
          value={remarks}
          onChangeText={(next) => {
            setRemarks(next);
            props.onChangeRemarks?.(next);
          }}
          placeholder="Describe the defect so the shop knows what to fix."
          placeholderTextColor={t.textMuted}
          multiline
          style={[
            styles.input,
            { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
          ]}
        />
      </Card>

      {showSeverity ? (
        <Card theme={t} title="Severity">
          <Segmented
            theme={t}
            testID="defect-severity"
            value={severity}
            options={SEVERITY_OPTIONS}
            onSelect={(next) => {
              setSeverity(next);
              props.onSelectSeverity?.(next);
            }}
          />
        </Card>
      ) : null}

      <Card theme={t} title="Photo">
        <View style={[styles.photoFrame, { borderColor: t.border, backgroundColor: t.cardMuted }]}>
          <Text style={[styles.photoText, { color: t.textMuted }]}>
            {photoCount > 0
              ? `${photoCount} photo${photoCount === 1 ? '' : 's'} attached`
              : 'No photo yet'}
          </Text>
        </View>
        <Button
          theme={t}
          variant="secondary"
          label="Add Photo"
          onPress={() => {
            setPhotoCount((n) => n + 1);
            setPhotoAdded(true);
            props.onAddPhoto?.();
          }}
          testID="defect-add-photo"
        />
        {photoAdded ? (
          <Text style={[styles.confirmLine, { color: t.success }]} testID="defect-photo-added">
            Photo added
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Review">
        <Pressable
          testID="defect-requires-review"
          onPress={() => {
            const next = !requiresReview;
            setRequiresReview(next);
            props.onToggleRequiresReview?.(next);
          }}
          accessibilityRole="checkbox"
          accessibilityState={{ checked: requiresReview }}
          style={styles.toggleRow}
        >
          <View
            style={[
              styles.toggleBox,
              { borderColor: requiresReview ? t.warning : t.border },
              requiresReview ? { backgroundColor: t.warning } : null,
            ]}
          >
            <Text style={[styles.toggleGlyph, { color: t.onPrimary }]}>
              {requiresReview ? '!' : ''}
            </Text>
          </View>
          <Text style={[styles.body2, { color: t.text }]}>Mark Requires Review</Text>
        </Pressable>
      </Card>

      <Button theme={t} label="Save Defect" onPress={props.onSaveDefect} testID="defect-save" />
      <Button
        theme={t}
        variant="secondary"
        label="Cancel"
        onPress={props.onCancel}
        testID="defect-cancel"
      />
    </View>
  );
}

// ---------------------------------------------------------------------------
// 15. Driver Pre-Trip Review
// ---------------------------------------------------------------------------

export function PreTripReviewScreen(props: {
  truckChecked?: number;
  truckTotal?: number;
  trailerChecked?: number;
  trailerTotal?: number;
  defectCount?: number;
  remarks?: string;
  onContinueToSignature: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const truckChecked = props.truckChecked ?? 45;
  const truckTotal = props.truckTotal ?? 45;
  const trailerChecked = props.trailerChecked ?? 16;
  const trailerTotal = props.trailerTotal ?? 16;
  const defectCount = props.defectCount ?? 0;
  const remarks = props.remarks ?? 'No visible defects';
  const hasDefects = defectCount > 0;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Pre-Trip Review</Text>

      <Card theme={t} title="Items checked">
        <FieldRow
          theme={t}
          label="Truck items checked"
          value={`${truckChecked} of ${truckTotal}`}
        />
        <FieldRow
          theme={t}
          label="Trailer items checked"
          value={`${trailerChecked} of ${trailerTotal}`}
        />
        <FieldRow theme={t} label="Defects" value={String(defectCount)} />
      </Card>

      <Card theme={t} title="Remarks">
        <Text style={[styles.body2, { color: t.text }]}>{remarks}</Text>
      </Card>

      {hasDefects ? (
        <Card theme={t} tone="highlight" title="Defects Reported" testID="pretrip-review-defects">
          <StatusBadge label="Needs Review" tone="warning" />
          <Text style={[styles.body2, { color: t.text }]}>
            {defectCount} defect{defectCount === 1 ? '' : 's'} need supervisor or mechanic review.
          </Text>
        </Card>
      ) : (
        <Card theme={t} testID="pretrip-review-clean">
          <StatusBadge label="Complete" tone="success" />
          <Text style={[styles.body2, { color: t.text }]}>
            All inspection items are checked and no defects were reported.
          </Text>
        </Card>
      )}

      <Button
        theme={t}
        label="Continue to Signature"
        onPress={props.onContinueToSignature}
        testID="pretrip-to-signature"
      />
    </View>
  );
}

// ---------------------------------------------------------------------------
// 16. Driver Pre-Trip Signature
// ---------------------------------------------------------------------------

export function PreTripSignatureScreen(props: {
  driverName?: string;
  onChangeDriverName?: (next: string) => void;
  /** Whether the signature pad already holds a captured signature. */
  signatureCaptured?: boolean;
  onCaptureSignature?: () => void;
  onClearSignature?: () => void;
  dateTime?: string;
  truck?: string;
  trailer?: string;
  /** Driver attestation shown above the pad; defaults to the canonical DVIR pre-trip text. */
  certificationText?: string;
  onCompletePreTrip: (payload: { signature: SignatureValue; signerName: string }) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const dateTime = props.dateTime ?? 'Today, 6:12 AM';
  const truck = props.truck ?? 'Truck 7';
  const trailer = props.trailer ?? 'Vacuum Trailer 19';

  const [confirming, setConfirming] = useState(false);
  const [driverName, setDriverName] = useState(props.driverName ?? '');
  const [signature, setSignature] = useState<SignatureValue | null>(null);
  const signed = signature !== null;
  const prefilled = (props.driverName ?? '').trim().length > 0;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Driver Signature</Text>

      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>
          {props.certificationText ?? fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT}
        </Text>
      </Card>

      <Card theme={t} title="Driver">
        <TextInput
          testID="signature-driver-name"
          value={driverName}
          onChangeText={(next) => {
            setDriverName(next);
            props.onChangeDriverName?.(next);
          }}
          placeholder="Your name or driver ID"
          placeholderTextColor={t.textMuted}
          style={[
            styles.nameInput,
            { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
          ]}
        />
        {prefilled ? (
          <Text style={[styles.meta, { color: t.textMuted }]} testID="signature-driver-prefilled">
            From your sign-in — edit only if needed.
          </Text>
        ) : null}
      </Card>

      <Card theme={t} title="Signature">
        <SignatureField
          theme={t}
          value={signature}
          onChange={(next) => {
            setSignature(next);
            if (next === null) props.onClearSignature?.();
            else props.onCaptureSignature?.();
          }}
          testID="pretrip-signature"
        />
      </Card>

      <Card theme={t} title="Date / Time">
        <Text style={[styles.body2, { color: t.text }]}>{dateTime}</Text>
      </Card>

      {confirming ? (
        <Card
          theme={t}
          tone="highlight"
          title="Complete Pre-Trip Inspection?"
          testID="signature-confirm"
        >
          <Text style={[styles.body2, { color: t.text }]}>
            You are confirming the inspection for {truck} and {trailer}.
          </Text>
          <Button
            theme={t}
            label="Complete Pre-Trip"
            onPress={() => {
              setConfirming(false);
              if (signature !== null) {
                props.onCompletePreTrip({ signature, signerName: driverName });
              }
            }}
            testID="signature-confirm-complete"
          />
          <Button
            theme={t}
            variant="secondary"
            label="Cancel"
            onPress={() => setConfirming(false)}
            testID="signature-confirm-cancel"
          />
        </Card>
      ) : (
        <Button
          theme={t}
          label="Complete Pre-Trip"
          onPress={() => setConfirming(true)}
          disabled={!signed || driverName.trim().length === 0}
          testID="signature-complete"
        />
      )}
    </View>
  );
}

// ---------------------------------------------------------------------------
// 17. Driver Pre-Trip Complete
// ---------------------------------------------------------------------------

export function PreTripCompleteScreen(props: {
  hasDefects?: boolean;
  defectCount?: number;
  truck?: string;
  trailer?: string;
  onStartNextJob: () => void;
  onViewDefectStatus?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const hasDefects = props.hasDefects ?? false;
  const defectCount = props.defectCount ?? 0;
  const truck = props.truck ?? 'Truck 7';
  const trailer = props.trailer ?? 'Vacuum Trailer 19';

  if (hasDefects) {
    return (
      <View style={styles.body}>
        <Text style={[styles.h1, { color: t.text }]}>Defects Submitted</Text>

        <Card theme={t} tone="highlight" testID="pretrip-complete-defects">
          <StatusBadge label="Submitted" tone="info" />
          <Text style={[styles.body2, { color: t.text }]}>
            Job work may be locked until review is complete.
          </Text>
          {defectCount > 0 ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>
              {defectCount} defect{defectCount === 1 ? '' : 's'} reported on {truck} and {trailer}.
            </Text>
          ) : null}
        </Card>

        {props.onViewDefectStatus !== undefined ? (
          <Button
            theme={t}
            label="View Defect Status"
            onPress={props.onViewDefectStatus}
            testID="pretrip-view-defect-status"
          />
        ) : null}
      </View>
    );
  }

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Pre-Trip Complete</Text>

      <Card theme={t} tone="highlight" testID="pretrip-complete-clean">
        <StatusBadge label="Complete" tone="success" />
        <Text style={[styles.body2, { color: t.text }]}>
          Vehicle condition marked satisfactory.
        </Text>
        <Text style={[styles.body2, { color: t.text }]}>Next step: Start your first job.</Text>
      </Card>

      <Button
        theme={t}
        label="Start Next Job"
        onPress={props.onStartNextJob}
        testID="pretrip-start-next-job"
      />
    </View>
  );
}

// ---------------------------------------------------------------------------
// Local presentational helpers
// ---------------------------------------------------------------------------

/** A label : value line used inside summary cards. */
function FieldRow(props: { label: string; value: string; theme: Theme }): ReactNode {
  const t = props.theme;
  return (
    <View style={styles.fieldRow}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.fieldValue, { color: t.text }]}>{props.value}</Text>
    </View>
  );
}

/**
 * Segmented control — the OK / Defect (and severity) selector. NOT a checkbox: each option is an
 * explicit, labeled choice so "checked = defective" can never be misread (GUI Master §23.4). The
 * active option is styled from the `value` prop the caller now drives off its own state.
 */
function Segmented<T extends string>(props: {
  value: T;
  options: readonly { key: T; label: string }[];
  onSelect: (next: T) => void;
  theme: Theme;
  testID?: string;
}): ReactNode {
  const t = props.theme;
  return (
    <View style={[styles.segment, { borderColor: t.border }]} testID={props.testID}>
      {props.options.map((opt) => {
        const selected = opt.key === props.value;
        const danger = opt.key === 'defect' || opt.key === 'unsafe';
        const bg = selected ? (danger ? t.danger : t.primary) : 'transparent';
        const fg = selected ? t.onPrimary : t.textMuted;
        return (
          <Pressable
            key={opt.key}
            testID={`${props.testID ?? 'segment'}-${opt.key}`}
            onPress={() => props.onSelect(opt.key)}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            accessibilityLabel={opt.label}
            style={[styles.segmentOption, { backgroundColor: bg }]}
          >
            <Text style={[styles.segmentText, { color: fg }]} numberOfLines={1}>
              {opt.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

// ---------------------------------------------------------------------------
// Sample fallbacks (used only when a prop is absent)
// ---------------------------------------------------------------------------

/** Build an all-"not-checked" item from a label (key = slugified label). */
function dvirItem(label: string, group: 'truck' | 'trailer'): InspectionItem {
  return {
    key: `${group}-${label
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/(^-|-$)/g, '')}`,
    label,
    result: 'not-checked',
    group,
  };
}

const TRUCK_ITEM_LABELS: readonly string[] = [
  'Air Compressor',
  'Air Lines',
  'Battery / Box',
  'Belts and Hoses',
  'Body',
  'Brake Accessories',
  'Brakes, Parking',
  'Brakes, Service',
  'Clutch',
  'Coolant Level',
  'Defroster / Heater',
  'Drive Line',
  'Engine Oil Level',
  'Exhaust System',
  'Fifth Wheel',
  'Visible Fluid Leaks',
  'Frame and Assembly',
  'Front Axle',
  'Fuel Tanks / Caps',
  'Glad Hands',
  'Headlights / High Beams',
  'Horn',
  'Mirrors',
  'Mud Flaps',
  'Muffler',
  'Oil Pressure Gauge',
  'Power Steering',
  'Radiator',
  'Reflectors / Reflective Tape',
  'Safe Loading',
  'Springs',
  'Starter',
  'Steering Mechanism',
  'Tail Lights / Turn Signals',
  'Tires (Tractor)',
  'Transmission',
  'Trip Recorder / ELD',
  'Wheels and Rims (Tractor)',
  'Windows',
  'Windshield',
  'Windshield Wipers / Washer',
  'Fire Extinguisher',
  'Emergency Triangles / Flares',
  'Seat Belts',
  'Cab / Doors',
  'Gauges and Warning Lights',
];

const TRAILER_ITEM_LABELS: readonly string[] = [
  'Brake Connections',
  'Brakes (Trailer)',
  'Coupling Devices',
  'Doors / Hatches',
  'Hitch / Pintle',
  'Landing Gear',
  'Clearance / Marker Lights',
  'Tail / Turn Lights (Trailer)',
  'Vacuum Pump',
  'Product Hoses',
  'Reflectors / Tape (Trailer)',
  'Suspension (Trailer)',
  'Tank / Vessel Integrity',
  'Tires (Trailer)',
  'Valves / Fittings',
  'Wheels and Rims (Trailer)',
];

/**
 * The full company DVIR checklist — 46 truck + 16 trailer = 62 items, every one starting
 * "not-checked" (a driver must actively mark each OK or Defect; nothing is pre-passed).
 */
const DEFAULT_SECTION_ITEMS: readonly InspectionItem[] = [
  ...TRUCK_ITEM_LABELS.map((l) => dvirItem(l, 'truck')),
  ...TRAILER_ITEM_LABELS.map((l) => dvirItem(l, 'trailer')),
];

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  meta: {
    fontSize: typeScale.label,
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  confirmLine: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  fieldRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 4,
    gap: spacing.md,
  },
  fieldLabel: {
    fontSize: typeScale.label,
    flexShrink: 1,
  },
  fieldValue: {
    fontSize: typeScale.body,
    fontWeight: '700',
    textAlign: 'right',
  },
  itemRow: {
    paddingVertical: spacing.sm,
    gap: spacing.sm,
  },
  itemLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  segment: {
    flexDirection: 'row',
    borderWidth: 1,
    borderRadius: sizing.radius,
    overflow: 'hidden',
  },
  segmentOption: {
    flex: 1,
    minHeight: sizing.minTouchTarget,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.sm,
  },
  segmentText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  input: {
    minHeight: 96,
    borderWidth: 1,
    borderRadius: sizing.radius,
    padding: spacing.md,
    fontSize: typeScale.body,
    textAlignVertical: 'top',
  },
  nameInput: {
    minHeight: sizing.minTouchTarget,
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    fontSize: typeScale.body,
  },
  photoFrame: {
    minHeight: 120,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
  },
  photoText: {
    fontSize: typeScale.label,
  },
  gateHint: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: sizing.minTouchTarget,
  },
  toggleBox: {
    width: 28,
    height: 28,
    borderWidth: 2,
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  toggleGlyph: {
    fontSize: typeScale.label,
    fontWeight: '800',
  },
});
