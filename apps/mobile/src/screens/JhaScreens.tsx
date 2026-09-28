/**
 * JHA/JSA flow (GUI Master §10 / screens 33–43) — the job-specific Job Hazard Analysis the driver
 * completes ON SITE before work begins. The flow walks: Overview → Job and Site → Emergency Info →
 * Pre-Job Safety → PPE → Hazards → Job Steps and Risk → Stop Work Authority → Signatures → Review →
 * Complete. Completing it unlocks the Field Ticket.
 *
 * These screens are PRESENTATIONAL ONLY: every screen takes small primitive props + callbacks, and
 * renders design-kit surfaces (Card / Button / StatusBadge). No domain/runtime/data imports, no
 * native modules. Signature capture, GPS, and the real save/sync are wired elsewhere — here a
 * signature shows a bordered preview frame + "Sign" / "Clear" buttons. Driver-facing language only:
 * no UUIDs, payloads, queues, or env strings (GUI Master §20). Risk math is computed for the driver
 * (severity × likelihood), never asked of them.
 */
import { useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { fieldwork } from '@fieldcapture/contracts';

import {
  Button,
  Card,
  SignatureField,
  StatusBadge,
  spacing,
  typeScale,
  useResolvedTheme,
  type SignatureValue,
  type Theme,
  type Tone,
} from '../design';

/* ------------------------------------------------------------------ *
 * Shared types + small local helpers
 * ------------------------------------------------------------------ */

/** Driver-facing section status (subset of the GUI Master §20 status vocabulary). */
export type JhaSectionStatus =
  | 'Not Started'
  | 'In Progress'
  | 'Required'
  | 'Complete'
  | 'Needs Review';

const SECTION_TONE: Record<JhaSectionStatus, Tone> = {
  'Not Started': 'neutral',
  'In Progress': 'info',
  Required: 'warning',
  Complete: 'success',
  'Needs Review': 'warning',
};

export interface JhaSection {
  key: string;
  label: string;
  status: JhaSectionStatus;
}

/** A read-only labeled field (auto-filled job/site data, emergency info). */
export interface JhaField {
  label: string;
  value: string;
}

/** A single safety-check item rendered as an OK / Not Yet segmented control (never a checkbox). */
export interface JhaCheckItem {
  key: string;
  label: string;
  /** true = confirmed OK, false = not yet / outstanding. */
  ok: boolean;
  /** When true the item is sourced from the daily DVIR and is shown read-only here. */
  autoFilled?: boolean;
}

export interface JhaCheckGroup {
  key: string;
  title: string;
  items: JhaCheckItem[];
}

/** A large selectable PPE / hazard tile. */
export interface JhaSelectable {
  key: string;
  label: string;
  selected: boolean;
}

/** Risk category derived from the risk score. */
export type RiskCategory = 'Low' | 'Medium' | 'High' | 'Critical';

export interface JhaJobStep {
  key: string;
  index: number;
  title: string;
  hazards: string;
  controls: string;
  severity: number;
  likelihood: number;
  initials: string;
}

export interface JhaSignatureRow {
  key: string;
  role: string;
  name: string;
  dateTime: string;
  required: boolean;
  signed: boolean;
}

export interface JhaReviewLine {
  label: string;
  value: string;
  done: boolean;
}

/** Compute a 1–25 risk score; the driver never does this math (GUI Master screen 39). */
export function calcRiskScore(severity: number, likelihood: number): number {
  const s = clampRisk(severity);
  const l = clampRisk(likelihood);
  return s * l;
}

/** Map a 1–25 score to a driver-facing category. */
export function riskCategory(score: number): RiskCategory {
  if (score >= 17) return 'Critical';
  if (score >= 10) return 'High';
  if (score >= 5) return 'Medium';
  return 'Low';
}

function clampRisk(value: number): number {
  if (!Number.isFinite(value)) return 1;
  if (value < 1) return 1;
  if (value > 5) return 5;
  return Math.round(value);
}

const RISK_TONE: Record<RiskCategory, Tone> = {
  Low: 'success',
  Medium: 'info',
  High: 'warning',
  Critical: 'danger',
};

/* ------------------------------------------------------------------ *
 * Small presentational sub-components (file-local)
 * ------------------------------------------------------------------ */

function FieldRow(props: { field: JhaField; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.fieldRow}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.field.label}</Text>
      <Text style={[styles.fieldValue, { color: t.text }]}>{props.field.value}</Text>
    </View>
  );
}

/**
 * OK / Not Yet segmented control. Mirrors the DVIR OK/Defect pattern (GUI Master §23.4): a confirmed
 * item reads "OK", an outstanding one "Not Yet" — never an ambiguous checkbox where checked could
 * mean "problem".
 */
function OkSegment(props: {
  ok: boolean;
  disabled?: boolean;
  onSetOk: (ok: boolean) => void;
  theme: Theme;
  testID?: string;
}) {
  const t = props.theme;
  const disabled = props.disabled ?? false;
  const segments: { value: boolean; label: string; tone: Tone }[] = [
    { value: true, label: 'OK', tone: 'success' },
    { value: false, label: 'Not Yet', tone: 'warning' },
  ];
  return (
    <View style={styles.segment} testID={props.testID}>
      {segments.map((seg) => {
        const active = props.ok === seg.value;
        const accent = seg.tone === 'success' ? t.success : t.warning;
        return (
          <Pressable
            key={seg.label}
            disabled={disabled}
            onPress={() => props.onSetOk(seg.value)}
            accessibilityRole="button"
            accessibilityState={{ selected: active, disabled }}
            accessibilityLabel={seg.label}
            style={[
              styles.segmentCell,
              { borderColor: active ? accent : t.border },
              active ? { backgroundColor: accent } : null,
              disabled ? styles.segmentDisabled : null,
            ]}
          >
            <Text style={[styles.segmentText, { color: active ? t.onPrimary : t.textMuted }]}>
              {seg.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/** A large selectable tile (PPE / Hazard). Selected reads as a filled primary tile. */
function SelectTile(props: {
  item: JhaSelectable;
  onToggle: () => void;
  theme: Theme;
  testID?: string;
}) {
  const t = props.theme;
  const { selected, label } = props.item;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onToggle}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      accessibilityLabel={label}
      style={[
        styles.tile,
        { borderColor: selected ? t.primary : t.border },
        selected ? { backgroundColor: t.primary } : { backgroundColor: t.cardMuted },
      ]}
    >
      <Text style={[styles.tileLabel, { color: selected ? t.onPrimary : t.text }]}>{label}</Text>
      <Text style={[styles.tileMark, { color: selected ? t.onPrimary : t.textMuted }]}>
        {selected ? 'Selected' : 'Tap to select'}
      </Text>
    </Pressable>
  );
}

/** Stepper control used for severity / likelihood (1–5). */
function RiskStepper(props: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  theme: Theme;
  testID?: string;
}) {
  const t = props.theme;
  const value = clampRisk(props.value);
  return (
    <View style={styles.stepperRow} testID={props.testID}>
      <Text style={[styles.stepperLabel, { color: t.text }]}>{props.label}</Text>
      <View style={styles.stepperControls}>
        <Pressable
          onPress={() => props.onChange(clampRisk(value - 1))}
          disabled={value <= 1}
          accessibilityRole="button"
          accessibilityLabel={`Decrease ${props.label}`}
          style={[
            styles.stepBtn,
            { borderColor: t.border },
            value <= 1 ? styles.stepDisabled : null,
          ]}
        >
          <Text style={[styles.stepBtnText, { color: t.text }]}>−</Text>
        </Pressable>
        <Text style={[styles.stepValue, { color: t.text }]}>{value}</Text>
        <Pressable
          onPress={() => props.onChange(clampRisk(value + 1))}
          disabled={value >= 5}
          accessibilityRole="button"
          accessibilityLabel={`Increase ${props.label}`}
          style={[
            styles.stepBtn,
            { borderColor: t.border },
            value >= 5 ? styles.stepDisabled : null,
          ]}
        >
          <Text style={[styles.stepBtnText, { color: t.text }]}>+</Text>
        </Pressable>
      </View>
    </View>
  );
}

function ScreenHeader(props: {
  title: string;
  subtitle?: string;
  theme: Theme;
  children?: ReactNode;
}) {
  const t = props.theme;
  return (
    <View style={styles.header}>
      <Text style={[styles.h1, { color: t.text }]}>{props.title}</Text>
      {props.subtitle !== undefined ? (
        <Text style={[styles.subtitle, { color: t.textMuted }]}>{props.subtitle}</Text>
      ) : null}
      {props.children}
    </View>
  );
}

/* ------------------------------------------------------------------ *
 * 33. JHA/JSA Overview
 * ------------------------------------------------------------------ */

export function JhaOverviewScreen(props: {
  srNumber?: string;
  customer?: string;
  lease?: string;
  sections?: JhaSection[];
  primaryLabel?: string;
  onBegin: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const srNumber = props.srNumber ?? '2026-000001';
  const customer = props.customer ?? 'Acme Energy';
  const lease = props.lease ?? 'Northfield Lease';
  const sections =
    props.sections ??
    DEFAULT_SECTIONS.map((s) => ({ ...s, status: 'Not Started' as JhaSectionStatus }));
  const complete = sections.filter((s) => s.status === 'Complete').length;

  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="JHA/JSA"
        subtitle="Complete at the tank battery before loading begins — this covers the on-site work, not the drive."
      />

      <Card theme={t} title="Job">
        <Text style={[styles.jobSr, { color: t.text }]}>{`SR ${srNumber}`}</Text>
        <Text style={[styles.bodyText, { color: t.textMuted }]}>{`${customer} · ${lease}`}</Text>
      </Card>

      <Card theme={t} tone="highlight" title="Progress" testID="jha-progress">
        <Text style={[styles.bodyText, { color: t.text }]}>
          {`${complete} of ${sections.length} sections complete`}
        </Text>
        <Button
          theme={t}
          label={props.primaryLabel ?? 'Begin JHA/JSA'}
          onPress={props.onBegin}
          testID="jha-begin"
        />
      </Card>

      <Card theme={t} title="Sections">
        {sections.map((section) => (
          <View key={section.key} style={styles.sectionRow} testID={`jha-section-${section.key}`}>
            <Text style={[styles.sectionLabel, { color: t.text }]}>{section.label}</Text>
            <StatusBadge label={section.status} tone={SECTION_TONE[section.status]} />
          </View>
        ))}
      </Card>
    </View>
  );
}

const DEFAULT_SECTIONS: readonly { key: string; label: string }[] = [
  { key: 'job-site', label: 'Job and Site' },
  { key: 'emergency', label: 'Emergency Info' },
  { key: 'pre-job', label: 'Pre-Job Safety' },
  { key: 'ppe', label: 'PPE' },
  { key: 'hazards', label: 'Hazards' },
  { key: 'job-steps', label: 'Job Steps and Risk' },
  { key: 'stop-work', label: 'Stop Work Authority' },
  { key: 'signatures', label: 'Signatures' },
  { key: 'review', label: 'Review' },
];

/* ------------------------------------------------------------------ *
 * 34. JHA/JSA Job and Site
 * ------------------------------------------------------------------ */

export function JhaJobAndSiteScreen(props: {
  fields?: JhaField[];
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const fields = props.fields ?? DEFAULT_JOB_SITE_FIELDS;
  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Job and Site"
        subtitle="Auto-filled from your assignment. Review before continuing."
      />
      <Card theme={t} title="Job details">
        {fields.map((field) => (
          <FieldRow key={field.label} field={field} theme={t} />
        ))}
      </Card>
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: Emergency Info'}
        onPress={props.onNext}
        testID="jha-jobsite-next"
      />
    </View>
  );
}

const DEFAULT_JOB_SITE_FIELDS: readonly JhaField[] = [
  { label: 'Company Name', value: 'Acme Oilfield Services' },
  { label: 'Customer / Operator', value: 'Acme Energy' },
  { label: 'Date', value: 'June 16, 2026' },
  { label: 'Prepared By', value: 'J. Bailey' },
  { label: 'Driver Name', value: 'J. Bailey' },
  { label: 'Supervisor Name', value: 'M. Reyes' },
  { label: 'Truck Unit No.', value: 'Truck 7' },
  { label: 'Trailer / Tanker No.', value: 'Vacuum Trailer 19' },
  { label: 'Job Ticket / Work Order No.', value: 'SR 2026-000001' },
  { label: 'Lease / Facility / Well Pad', value: 'Northfield 114H' },
  { label: 'County', value: 'Reeves County, TX' },
  { label: 'Start Location', value: 'Pecos Yard' },
  { label: 'Destination / SWD Facility', value: 'Northfield 114H' },
  { label: 'Start Time', value: '06:30' },
  { label: 'Estimated Finish Time', value: '11:00' },
  { label: 'Shift', value: 'Day' },
  { label: 'Weather', value: 'Clear' },
  { label: 'Temperature', value: '92°F' },
  { label: 'Heat Index', value: '98°F' },
  { label: 'Cell Phone / Radio Channel', value: 'Channel 3' },
];

/* ------------------------------------------------------------------ *
 * 35. JHA/JSA Emergency Info
 * ------------------------------------------------------------------ */

export function JhaEmergencyInfoScreen(props: {
  fields?: JhaField[];
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const fields = props.fields ?? DEFAULT_EMERGENCY_FIELDS;
  return (
    <View style={styles.body}>
      <ScreenHeader theme={t} title="Emergency Info" subtitle="Know these before work begins." />
      <Card theme={t} tone="highlight" title="If something goes wrong">
        <Text style={[styles.bodyText, { color: t.text }]}>
          Stop work and make the area safe first, then use the contacts below. In a life-threatening
          emergency, call 911.
        </Text>
      </Card>
      <Card theme={t} title="Emergency contacts and access">
        {fields.map((field) => (
          <FieldRow key={field.label} field={field} theme={t} />
        ))}
      </Card>
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: Pre-Job Safety'}
        onPress={props.onNext}
        testID="jha-emergency-next"
      />
    </View>
  );
}

const DEFAULT_EMERGENCY_FIELDS: readonly JhaField[] = [
  { label: 'Emergency Contact Number', value: '911' },
  { label: 'Site Contact / Company Man', value: 'D. Cole · (432) 555-0142' },
  { label: 'Customer Safety Contact', value: 'Acme Safety · (432) 555-0190' },
  { label: 'Nearest Hospital / Clinic', value: 'Reeves County Hospital, Pecos' },
  { label: 'Muster Point', value: 'Lease entrance, north gate' },
  { label: 'Spill Response Contact', value: 'Field Dispatch · (432) 555-0100' },
  { label: 'H2S Emergency Contact', value: 'Site Safety · (432) 555-0190' },
  { label: '911 Access Instructions', value: 'Give lease name, well pad, and county road marker' },
  {
    label: 'Gate Codes / Lease Road Directions',
    value: 'Gate code at dispatch; CR 308 to north pad',
  },
];

/* ------------------------------------------------------------------ *
 * 36. JHA/JSA Pre-Job Safety
 * ------------------------------------------------------------------ */

export function JhaPreJobSafetyScreen(props: {
  groups?: JhaCheckGroup[];
  /** Auto-filled pre-trip / DVIR completion (GUI Master screen 36). */
  dvirCompleted?: boolean;
  onSetItemOk?: (groupKey: string, itemKey: string, ok: boolean) => void;
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [local, setLocal] = useState<JhaCheckGroup[]>(props.groups ?? DEFAULT_PRE_JOB_GROUPS);
  const dvirCompleted = props.dvirCompleted ?? false;

  const setOk = (groupKey: string, itemKey: string, ok: boolean) => {
    setLocal((groups) =>
      groups.map((g) =>
        g.key === groupKey
          ? { ...g, items: g.items.map((i) => (i.key === itemKey ? { ...i, ok } : i)) }
          : g,
      ),
    );
    props.onSetItemOk?.(groupKey, itemKey, ok);
  };

  const resolveOk = (item: JhaCheckItem): boolean =>
    item.key === 'dvir-pre-trip' ? dvirCompleted || item.ok : item.ok;

  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Pre-Job Safety"
        subtitle="Confirm each item is OK before you start."
      />
      {dvirCompleted ? (
        <Card theme={t} title="Pre-trip">
          <View style={styles.row}>
            <Text style={[styles.bodyText, { color: t.text }]}>
              DVIR / Pre-Trip Inspection pulled from today’s inspection.
            </Text>
            <StatusBadge label="Complete" tone="success" testID="jha-dvir-autofill" />
          </View>
        </Card>
      ) : null}
      {local.map((group) => (
        <Card key={group.key} theme={t} title={group.title} testID={`jha-prejob-${group.key}`}>
          {group.items.map((item) => {
            const isDvir = item.key === 'dvir-pre-trip';
            const ok = resolveOk(item);
            const autoFilled = (item.autoFilled ?? false) || (isDvir && dvirCompleted);
            return (
              <View key={item.key} style={styles.checkRow}>
                <Text style={[styles.checkLabel, { color: t.text }]}>{item.label}</Text>
                {autoFilled ? (
                  <StatusBadge
                    label={ok ? 'Complete' : 'Required'}
                    tone={ok ? 'success' : 'warning'}
                  />
                ) : (
                  <OkSegment
                    theme={t}
                    ok={ok}
                    onSetOk={(value) => setOk(group.key, item.key, value)}
                    testID={`jha-check-${item.key}`}
                  />
                )}
              </View>
            );
          })}
        </Card>
      ))}
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: PPE'}
        onPress={props.onNext}
        testID="jha-prejob-next"
      />
    </View>
  );
}

const DEFAULT_PRE_JOB_GROUPS: JhaCheckGroup[] = [
  {
    key: 'driver',
    title: 'Driver Readiness',
    items: [
      { key: 'fit-for-duty', label: 'Fit for Duty', ok: false },
      { key: 'fatigue', label: 'Fatigue Check Completed', ok: false },
      { key: 'hos', label: 'Hours of Service Verified', ok: false },
      {
        key: 'dvir-pre-trip',
        label: 'DVIR / Pre-Trip Inspection Completed',
        ok: false,
        autoFilled: true,
      },
    ],
  },
  {
    key: 'route',
    title: 'Route and Weather',
    items: [
      { key: 'journey', label: 'Journey Management / Route Review Completed', ok: false },
      { key: 'road', label: 'Road Conditions Reviewed', ok: false },
      { key: 'weather', label: 'Weather / Heat Stress Reviewed', ok: false },
      { key: 'hydration', label: 'Hydration Plan in Place', ok: false },
    ],
  },
  {
    key: 'site',
    title: 'Site Readiness',
    items: [
      { key: 'h2s-required', label: 'H2S Monitor Required', ok: false },
      { key: 'h2s-checked', label: 'H2S Monitor Checked', ok: false },
      { key: 'ppe-inspected', label: 'PPE Inspected', ok: false },
      { key: 'fire-ext', label: 'Fire Extinguisher Inspected', ok: false },
      { key: 'first-aid', label: 'First Aid Kit Available', ok: false },
      { key: 'chocks', label: 'Wheel Chocks Available', ok: false },
    ],
  },
  {
    key: 'equipment',
    title: 'Equipment Readiness',
    items: [
      { key: 'fittings', label: 'Areas and Fittings Inspected', ok: false },
      { key: 'pump-pto', label: 'Pump / PTO Inspected', ok: false },
      { key: 'valves', label: 'Valves Inspected', ok: false },
    ],
  },
  {
    key: 'customer',
    title: 'Customer Site Requirements',
    items: [
      { key: 'orientation', label: 'Customer Site Orientation Completed', ok: false },
      { key: 'spotter', label: 'Backing Spotter Required', ok: false },
      { key: 'power-lines', label: 'Overhead Power Lines Checked', ok: false },
      { key: 'slip-trip', label: 'Slip / Trip Hazards Identified', ok: false },
      { key: 'lighting', label: 'Lighting Required for Night Work', ok: false },
    ],
  },
];

/* ------------------------------------------------------------------ *
 * 37. JHA/JSA PPE
 * ------------------------------------------------------------------ */

export function JhaPpeScreen(props: {
  items?: JhaSelectable[];
  onToggle?: (key: string, selected: boolean) => void;
  onChangeOther?: (text: string) => void;
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [local, setLocal] = useState<JhaSelectable[]>(props.items ?? DEFAULT_PPE);
  const [otherText, setOtherText] = useState('');
  const toggle = (key: string) => {
    setLocal((items) => {
      const next = items.map((i) => (i.key === key ? { ...i, selected: !i.selected } : i));
      const changed = next.find((i) => i.key === key);
      if (changed !== undefined) props.onToggle?.(key, changed.selected);
      return next;
    });
  };
  const otherSelected = local.find((i) => i.key === 'other')?.selected ?? false;
  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="PPE"
        subtitle="Select the protective equipment required for this job."
      />
      <Card theme={t} title="Required PPE">
        <View style={styles.tileGrid}>
          {local.map((item) => (
            <SelectTile
              key={item.key}
              item={item}
              onToggle={() => toggle(item.key)}
              theme={t}
              testID={`jha-ppe-${item.key}`}
            />
          ))}
        </View>
        {otherSelected ? (
          <TextInput
            testID="jha-ppe-other-text"
            value={otherText}
            onChangeText={(next) => {
              setOtherText(next);
              props.onChangeOther?.(next);
            }}
            placeholder="Describe the other PPE"
            placeholderTextColor={t.textMuted}
            style={[
              styles.otherInput,
              { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
            ]}
          />
        ) : null}
      </Card>
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: Hazards'}
        onPress={props.onNext}
        testID="jha-ppe-next"
      />
    </View>
  );
}

const DEFAULT_PPE: JhaSelectable[] = [
  { key: 'fr', label: 'FR Clothing', selected: false },
  { key: 'hard-hat', label: 'Hard Hat', selected: false },
  { key: 'glasses', label: 'Safety Glasses', selected: false },
  { key: 'hearing', label: 'Hearing Protection', selected: false },
  { key: 'work-gloves', label: 'Work Gloves', selected: false },
  { key: 'chem-gloves', label: 'Chemical Resistant Gloves', selected: false },
  { key: 'boots', label: 'Steel Toe Boots', selected: false },
  { key: 'vest', label: 'Reflective Vest', selected: false },
  { key: 'h2s-monitor', label: 'H2S Monitor', selected: false },
  { key: 'respirator', label: 'Respirator if Required', selected: false },
  { key: 'rain-gear', label: 'Rain Gear', selected: false },
  { key: 'other', label: 'Other', selected: false },
];

/* ------------------------------------------------------------------ *
 * 38. JHA/JSA Hazards
 * ------------------------------------------------------------------ */

export interface JhaHazard extends JhaSelectable {
  /** Suggested controls shown when the hazard is selected. */
  controls: string[];
}

export function JhaHazardsScreen(props: {
  hazards?: JhaHazard[];
  onToggle?: (key: string, selected: boolean) => void;
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [local, setLocal] = useState<JhaHazard[]>(props.hazards ?? DEFAULT_HAZARDS);
  const toggle = (key: string) => {
    setLocal((items) => {
      const next = items.map((i) => (i.key === key ? { ...i, selected: !i.selected } : i));
      const changed = next.find((i) => i.key === key);
      if (changed !== undefined) props.onToggle?.(key, changed.selected);
      return next;
    });
  };
  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Hazards"
        subtitle="Select hazards present. Controls appear for each one you pick."
      />
      <Card theme={t} title="Job hazards">
        <View style={styles.tileGrid}>
          {local.map((hazard) => (
            <SelectTile
              key={hazard.key}
              item={hazard}
              onToggle={() => toggle(hazard.key)}
              theme={t}
              testID={`jha-hazard-${hazard.key}`}
            />
          ))}
        </View>
      </Card>
      {local.some((h) => h.selected) ? (
        <Card theme={t} tone="highlight" title="Controls" testID="jha-hazard-controls">
          {local
            .filter((h) => h.selected)
            .map((hazard) => (
              <View key={hazard.key} style={styles.controlBlock}>
                <Text style={[styles.controlTitle, { color: t.text }]}>
                  {`${hazard.label} selected`}
                </Text>
                {hazard.controls.map((control) => (
                  <Text key={control} style={[styles.controlItem, { color: t.text }]}>
                    {`• ${control}`}
                  </Text>
                ))}
              </View>
            ))}
        </Card>
      ) : null}
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: Job Steps'}
        onPress={props.onNext}
        testID="jha-hazards-next"
      />
    </View>
  );
}

const DEFAULT_HAZARDS: JhaHazard[] = [
  {
    key: 'collision',
    label: 'Vehicle Collision',
    selected: false,
    controls: [
      'Maintain safe following distance',
      'Obey lease speed limits',
      'Stay alert at intersections',
    ],
  },
  {
    key: 'rollover',
    label: 'Rollover',
    selected: false,
    controls: ['Slow on curves and grades', 'Watch soft shoulders', 'Keep load secured'],
  },
  {
    key: 'dust',
    label: 'Dust / Low Visibility',
    selected: false,
    controls: ['Use headlights', 'Reduce speed', 'Increase following distance'],
  },
  {
    key: 'backing',
    label: 'Backing Hazards',
    selected: false,
    controls: ['Use a spotter', 'Walk the path first', 'Back slowly with hazards on'],
  },
  {
    key: 'fatigue',
    label: 'Fatigue',
    selected: false,
    controls: ['Take rest breaks', 'Stay hydrated', 'Stop if drowsy'],
  },
  {
    key: 'heat',
    label: 'Heat Stress',
    selected: false,
    controls: ['Drink water often', 'Take shade breaks', 'Watch for heat illness'],
  },
  {
    key: 'h2s',
    label: 'H2S Exposure',
    selected: false,
    controls: [
      'H2S monitor checked',
      'Know muster point',
      'Stay upwind',
      'Stop work if alarm sounds',
    ],
  },
  {
    key: 'chemical',
    label: 'Chemical Exposure',
    selected: false,
    controls: ['Wear chemical gloves', 'Review SDS', 'Avoid skin contact'],
  },
  {
    key: 'slips',
    label: 'Slips / Trips / Falls',
    selected: false,
    controls: ['Watch footing', 'Keep area clear', 'Use three points of contact'],
  },
  {
    key: 'pinch',
    label: 'Pinch Points',
    selected: false,
    controls: ['Keep hands clear of fittings', 'Wear gloves', 'Mind connection points'],
  },
  {
    key: 'hose-whip',
    label: 'Hose Whip',
    selected: false,
    controls: [
      'Secure hose connections',
      'Bleed pressure before disconnect',
      'Stand clear of hose ends',
    ],
  },
  {
    key: 'fire',
    label: 'Fire / Explosion',
    selected: false,
    controls: ['No ignition sources', 'Ground equipment', 'Fire extinguisher staged'],
  },
  {
    key: 'spill',
    label: 'Spill / Release',
    selected: false,
    controls: ['Stage containment', 'Know spill response contact', 'Stop transfer if leaking'],
  },
  {
    key: 'power-lines',
    label: 'Overhead Power Lines',
    selected: false,
    controls: ['Check clearance before raising', 'Maintain safe distance', 'Use a spotter'],
  },
  {
    key: 'wildlife',
    label: 'Wildlife',
    selected: false,
    controls: ['Scan area on arrival', 'Keep distance', 'Watch for snakes near equipment'],
  },
];

/* ------------------------------------------------------------------ *
 * 39. JHA/JSA Job Steps and Risk
 * ------------------------------------------------------------------ */

export function JhaJobStepsScreen(props: {
  steps?: JhaJobStep[];
  onChangeStep?: (step: JhaJobStep) => void;
  primaryLabel?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [local, setLocal] = useState<JhaJobStep[]>(props.steps ?? DEFAULT_JOB_STEPS);
  const [openKey, setOpenKey] = useState<string | null>(local[0]?.key ?? null);

  const update = (key: string, patch: Partial<JhaJobStep>) => {
    setLocal((steps) => {
      const next = steps.map((s) => (s.key === key ? { ...s, ...patch } : s));
      const changed = next.find((s) => s.key === key);
      if (changed !== undefined) props.onChangeStep?.(changed);
      return next;
    });
  };

  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Job Steps and Risk"
        subtitle="Review each step. The app scores the risk for you."
      />
      {local.map((step) => {
        const open = step.key === openKey;
        const initialScore = calcRiskScore(step.severity, step.likelihood);
        const initialCat = riskCategory(initialScore);
        return (
          <Card key={step.key} theme={t} testID={`jha-step-${step.key}`}>
            <Pressable
              onPress={() => setOpenKey(open ? null : step.key)}
              accessibilityRole="button"
              accessibilityState={{ expanded: open }}
              style={styles.stepHeaderRow}
            >
              <Text style={[styles.stepTitle, { color: t.text }]}>
                {`${step.index}. ${step.title}`}
              </Text>
              <StatusBadge label={initialCat} tone={RISK_TONE[initialCat]} />
            </Pressable>
            {open ? (
              <View style={styles.stepDetail}>
                <Text style={[styles.fieldLabel, { color: t.textMuted }]}>Potential Hazards</Text>
                <TextInput
                  value={step.hazards}
                  onChangeText={(text) => update(step.key, { hazards: text })}
                  multiline
                  placeholder="Hazards for this step"
                  placeholderTextColor={t.textMuted}
                  accessibilityLabel={`Potential hazards for step ${step.index}`}
                  style={[
                    styles.input,
                    styles.inputMulti,
                    { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
                  ]}
                />
                <Text style={[styles.fieldLabel, { color: t.textMuted }]}>
                  Controls / Safe Work Practices
                </Text>
                <TextInput
                  value={step.controls}
                  onChangeText={(text) => update(step.key, { controls: text })}
                  multiline
                  placeholder="Controls for this step"
                  placeholderTextColor={t.textMuted}
                  accessibilityLabel={`Controls for step ${step.index}`}
                  style={[
                    styles.input,
                    styles.inputMulti,
                    { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
                  ]}
                />

                <Text style={[styles.fieldLabel, { color: t.textMuted }]}>Initial Risk</Text>
                <RiskStepper
                  theme={t}
                  label="Severity (1–5)"
                  value={step.severity}
                  onChange={(v) => update(step.key, { severity: v })}
                  testID={`jha-step-sev-${step.key}`}
                />
                <RiskStepper
                  theme={t}
                  label="Likelihood (1–5)"
                  value={step.likelihood}
                  onChange={(v) => update(step.key, { likelihood: v })}
                  testID={`jha-step-like-${step.key}`}
                />
                <View style={styles.scoreRow}>
                  <Text
                    style={[styles.scoreText, { color: t.text }]}
                  >{`Risk Score ${initialScore}`}</Text>
                  <StatusBadge
                    label={`Risk ${initialCat}`}
                    tone={RISK_TONE[initialCat]}
                    testID={`jha-step-score-${step.key}`}
                  />
                </View>
                <Text style={[styles.helperText, { color: t.textMuted }]}>
                  Residual risk drops as you apply the controls above.
                </Text>

                <Text style={[styles.fieldLabel, { color: t.textMuted }]}>Initials</Text>
                <TextInput
                  value={step.initials}
                  onChangeText={(text) => update(step.key, { initials: text })}
                  placeholder="Your initials"
                  placeholderTextColor={t.textMuted}
                  autoCapitalize="characters"
                  accessibilityLabel={`Initials for step ${step.index}`}
                  style={[
                    styles.input,
                    { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
                  ]}
                />
              </View>
            ) : (
              <Text style={[styles.helperText, { color: t.textMuted }]}>
                {`Risk Score ${initialScore} · Tap to review hazards and controls`}
              </Text>
            )}
          </Card>
        );
      })}
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Next: Stop Work Authority'}
        onPress={props.onNext}
        testID="jha-steps-next"
      />
    </View>
  );
}

const DEFAULT_JOB_STEPS: JhaJobStep[] = [
  {
    key: 's1',
    index: 1,
    title: 'Receive dispatch and review job ticket',
    hazards: 'Distraction, incomplete information',
    controls: 'Confirm details before leaving yard',
    severity: 2,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's2',
    index: 2,
    title: 'Complete pre-trip inspection',
    hazards: 'Equipment defect, pinch points',
    controls: 'Follow DVIR, tag out defects',
    severity: 2,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's3',
    index: 3,
    title: 'Travel to lease / facility',
    hazards: 'Vehicle collision, rollover, dust',
    controls: 'Defensive driving, reduce speed',
    severity: 4,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's4',
    index: 4,
    title: 'Stage truck and secure area',
    hazards: 'Backing hazards, power lines',
    controls: 'Use spotter, set chocks',
    severity: 3,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's5',
    index: 5,
    title: 'Connect hoses and verify conditions',
    hazards: 'Hose whip, H2S, chemical exposure',
    controls: 'Bleed pressure, monitor H2S, PPE',
    severity: 4,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's6',
    index: 6,
    title: 'Load or unload water',
    hazards: 'Spill / release, slips',
    controls: 'Stage containment, watch footing',
    severity: 3,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's7',
    index: 7,
    title: 'Disconnect and secure equipment',
    hazards: 'Pinch points, residual pressure',
    controls: 'Verify zero pressure, wear gloves',
    severity: 3,
    likelihood: 2,
    initials: '',
  },
  {
    key: 's8',
    index: 8,
    title: 'Complete paperwork and post-trip inspection',
    hazards: 'Fatigue, missed defect',
    controls: 'Complete DVIR, take breaks',
    severity: 2,
    likelihood: 2,
    initials: '',
  },
];

/* ------------------------------------------------------------------ *
 * 40. JHA/JSA Stop Work Authority
 * ------------------------------------------------------------------ */

export function JhaStopWorkScreen(props: {
  conditions?: string[];
  acknowledged?: boolean;
  onAcknowledge: () => void;
  primaryLabel?: string;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const conditions = props.conditions ?? DEFAULT_STOP_WORK;
  const [acked, setAcked] = useState<boolean>(props.acknowledged ?? false);
  const acknowledge = () => {
    setAcked(true);
    props.onAcknowledge();
  };
  return (
    <View style={styles.body}>
      <ScreenHeader theme={t} title="Stop Work Authority" />
      <Card theme={t} tone="highlight" title="Stop immediately for">
        {conditions.map((condition) => (
          <Text key={condition} style={[styles.bulletText, { color: t.text }]}>
            {`• ${condition}`}
          </Text>
        ))}
      </Card>
      <Card theme={t} title="Acknowledgement">
        <Text style={[styles.bodyText, { color: t.text }]}>
          Anyone on this site — crew, contractor, customer, or visitor — has the authority to stop
          work if conditions are unsafe. No one needs permission.
        </Text>
        <Text style={[styles.bodyText, { color: t.text }]} testID="jha-stopwork-tailgate">
          If more than one person is on site, we hold a tailgate meeting so everyone understands the
          work and its hazards before it starts.
        </Text>
        {acked ? (
          <StatusBadge label="Complete" tone="success" testID="jha-stopwork-state" />
        ) : (
          <StatusBadge label="Required" tone="warning" testID="jha-stopwork-state" />
        )}
      </Card>
      <Button
        theme={t}
        label={acked ? 'Acknowledged' : (props.primaryLabel ?? 'Acknowledge')}
        onPress={acknowledge}
        disabled={acked}
        testID="jha-stopwork-ack"
      />
    </View>
  );
}

const DEFAULT_STOP_WORK: readonly string[] = [
  'H2S alarm',
  'Uncontrolled leak or spill',
  'Fire',
  'Lightning',
  'Heat illness symptoms',
  'Failed equipment',
  'Unsafe road condition',
  'Missing PPE',
  'Unsafe backing condition',
  'Worker concern',
];

/* ------------------------------------------------------------------ *
 * 41. JHA/JSA Signatures
 * ------------------------------------------------------------------ */

/** Who can be added to a JHA besides the driver — the supervisor / customer rep are usually absent. */
const CREW_ROLE_OPTIONS: readonly string[] = [
  'Additional Crew',
  'Owner',
  'Supervisor',
  'Customer Rep',
  'Other',
];

/** A person who signs the JHA. The driver is fixed (signed in); everyone else is added if present. */
interface JhaSigner {
  key: string;
  role: string;
  name: string;
  required: boolean;
  /** The driver row — role is not editable and the row cannot be removed. */
  fixed: boolean;
}

/** Wrap-style role chooser for an added (non-driver) signer. */
function RolePicker(props: {
  value: string;
  onChange: (role: string) => void;
  theme: Theme;
  testID?: string;
}) {
  const t = props.theme;
  return (
    <View style={styles.roleRow} testID={props.testID}>
      {CREW_ROLE_OPTIONS.map((role) => {
        const selected = role === props.value;
        return (
          <Pressable
            key={role}
            testID={`${props.testID ?? 'role'}-${role.toLowerCase().replace(/\s+/g, '-')}`}
            onPress={() => props.onChange(role)}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            style={[
              styles.roleChip,
              { borderColor: selected ? t.primary : t.border },
              selected ? { backgroundColor: t.primary } : null,
            ]}
          >
            <Text style={[styles.roleChipText, { color: selected ? t.onPrimary : t.text }]}>
              {role}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function JhaSignaturesScreen(props: {
  /** The signed-in driver's name/id — pre-fills the (fixed) driver row. */
  driverName?: string;
  people?: JhaSigner[];
  primaryLabel?: string;
  /** Crew attestation shown to the driver; defaults to the canonical JHA text. */
  certificationText?: string;
  onContinue: (payload: {
    signatures: { signature: SignatureValue; signerName: string; signerRole: string }[];
  }) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [people, setPeople] = useState<JhaSigner[]>(
    () =>
      props.people ?? [
        {
          key: 'driver',
          role: 'Driver',
          name: props.driverName ?? '',
          required: true,
          fixed: true,
        },
      ],
  );
  const [sigs, setSigs] = useState<Record<string, SignatureValue | null>>({});
  const [nextId, setNextId] = useState(1);

  const setName = (key: string, name: string) =>
    setPeople((ps) => ps.map((p) => (p.key === key ? { ...p, name } : p)));
  const setRole = (key: string, role: string) =>
    setPeople((ps) => ps.map((p) => (p.key === key ? { ...p, role } : p)));
  const addPerson = () => {
    const key = `person-${nextId}`;
    setNextId((n) => n + 1);
    setPeople((ps) => [
      ...ps,
      { key, role: 'Additional Crew', name: '', required: false, fixed: false },
    ]);
  };
  const removePerson = (key: string) => {
    setPeople((ps) => ps.filter((p) => p.key !== key));
    setSigs((s) => {
      const next = { ...s };
      delete next[key];
      return next;
    });
  };

  // Gate Continue on the driver (the fixed row); fall back to "driver" key if no fixed row given.
  const driverKey = (people.find((p) => p.fixed) ?? people[0])?.key;
  const driverSigned = driverKey != null && sigs[driverKey] != null;
  const emitSignatures = () =>
    props.onContinue({
      signatures: people
        .filter((p) => sigs[p.key] != null)
        .map((p) => ({ signature: sigs[p.key]!, signerName: p.name, signerRole: p.role })),
    });

  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Signatures"
        subtitle="The driver signs. Add anyone else on site — only people who are actually present."
      />
      <Card theme={t} tone="highlight">
        <Text style={[styles.subtleText, { color: t.text }]}>
          {props.certificationText ?? fieldwork.JHA_CERTIFICATION_TEXT}
        </Text>
      </Card>
      {people.map((person) => {
        const signed = sigs[person.key] != null;
        return (
          <Card
            key={person.key}
            theme={t}
            title={person.fixed ? 'Driver' : undefined}
            testID={`jha-sig-${person.key}`}
          >
            {!person.fixed ? (
              <RolePicker
                value={person.role}
                onChange={(r) => setRole(person.key, r)}
                theme={t}
                testID={`jha-sig-role-${person.key}`}
              />
            ) : null}
            <TextInput
              testID={`jha-sig-name-${person.key}`}
              value={person.name}
              onChangeText={(x) => setName(person.key, x)}
              placeholder={person.fixed ? 'Your name or driver ID' : 'Name'}
              placeholderTextColor={t.textMuted}
              style={[
                styles.otherInput,
                { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
              ]}
            />
            {person.fixed && (props.driverName ?? '').trim().length > 0 ? (
              <Text style={[styles.subtleText, { color: t.textMuted }]}>
                From your sign-in — edit only if needed.
              </Text>
            ) : null}
            <SignatureField
              theme={t}
              value={sigs[person.key] ?? null}
              onChange={(v) => setSigs((s) => ({ ...s, [person.key]: v }))}
              testID={`jha-sig-pad-${person.key}`}
            />
            <StatusBadge
              label={signed ? 'Signed' : person.required ? 'Required' : 'Optional'}
              tone={signed ? 'success' : person.required ? 'warning' : 'neutral'}
              testID={`jha-sig-state-${person.key}`}
            />
            {!person.fixed ? (
              <Button
                theme={t}
                variant="secondary"
                label="Remove"
                onPress={() => removePerson(person.key)}
                fullWidth={false}
                testID={`jha-sig-remove-${person.key}`}
              />
            ) : null}
          </Card>
        );
      })}
      <Button
        theme={t}
        variant="secondary"
        label="Add person on site"
        onPress={addPerson}
        testID="jha-sig-add"
      />
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Continue to Review'}
        onPress={emitSignatures}
        disabled={!driverSigned}
        testID="jha-sig-continue"
      />
    </View>
  );
}

/* ------------------------------------------------------------------ *
 * 42. JHA/JSA Review
 * ------------------------------------------------------------------ */

export function JhaReviewScreen(props: {
  lines?: JhaReviewLine[];
  confirmOpen?: boolean;
  primaryLabel?: string;
  onComplete: () => void;
  onConfirmComplete?: () => void;
  onCancelConfirm?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const lines = props.lines ?? DEFAULT_REVIEW_LINES;
  const [confirming, setConfirming] = useState<boolean>(props.confirmOpen ?? false);

  const openConfirm = () => {
    setConfirming(true);
    props.onComplete();
  };
  const confirm = () => {
    setConfirming(false);
    props.onConfirmComplete?.();
  };
  const cancel = () => {
    setConfirming(false);
    props.onCancelConfirm?.();
  };

  return (
    <View style={styles.body}>
      <ScreenHeader
        theme={t}
        title="Review"
        subtitle="Confirm every section before you complete the JHA/JSA."
      />
      <Card theme={t} title="Summary">
        {lines.map((line) => (
          <View key={line.label} style={styles.sectionRow} testID={`jha-review-${line.label}`}>
            <Text style={[styles.sectionLabel, { color: t.text }]}>{line.label}</Text>
            <StatusBadge label={line.value} tone={line.done ? 'success' : 'warning'} />
          </View>
        ))}
      </Card>

      {confirming ? (
        <Card theme={t} tone="highlight" title="Complete JHA/JSA?" testID="jha-review-confirm">
          <Text style={[styles.bodyText, { color: t.text }]}>
            You are confirming that hazards, controls, PPE, emergency info, and stop-work authority
            were reviewed for this job.
          </Text>
          <Button
            theme={t}
            label={props.primaryLabel ?? 'Complete JHA/JSA'}
            onPress={confirm}
            testID="jha-review-confirm-yes"
          />
          <Button
            theme={t}
            variant="secondary"
            label="Cancel"
            onPress={cancel}
            testID="jha-review-confirm-cancel"
          />
        </Card>
      ) : (
        <Button
          theme={t}
          label={props.primaryLabel ?? 'Complete JHA/JSA'}
          onPress={openConfirm}
          testID="jha-review-complete"
        />
      )}
    </View>
  );
}

const DEFAULT_REVIEW_LINES: readonly JhaReviewLine[] = [
  { label: 'Job and Site', value: 'Complete', done: true },
  { label: 'Emergency Info', value: 'Complete', done: true },
  { label: 'Pre-Job Safety', value: 'Complete', done: true },
  { label: 'PPE', value: 'Complete', done: true },
  { label: 'Hazards', value: 'Complete', done: true },
  { label: 'Risk Review', value: 'Complete', done: true },
  { label: 'Stop Work', value: 'Acknowledged', done: true },
  { label: 'Signatures', value: 'Complete', done: true },
];

/* ------------------------------------------------------------------ *
 * 43. JHA/JSA Complete
 * ------------------------------------------------------------------ */

export function JhaCompleteScreen(props: {
  srNumber?: string;
  primaryLabel?: string;
  onStartFieldTicket: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const srNumber = props.srNumber ?? '2026-000001';
  return (
    <View style={styles.body}>
      <ScreenHeader theme={t} title="JHA/JSA Complete" />
      <Card theme={t} tone="highlight" title={`SR ${srNumber}`}>
        <View style={styles.row}>
          <StatusBadge label="Complete" tone="success" testID="jha-complete-state" />
        </View>
        <Text style={[styles.bodyText, { color: t.text }]}>Field Ticket is now unlocked.</Text>
      </Card>
      <Button
        theme={t}
        label={props.primaryLabel ?? 'Start Field Ticket'}
        onPress={props.onStartFieldTicket}
        testID="jha-complete-start"
      />
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
  header: {
    gap: spacing.xs,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  subtitle: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  bodyText: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  helperText: {
    fontSize: typeScale.label,
    lineHeight: 20,
  },
  jobSr: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  sectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 6,
    gap: spacing.sm,
  },
  sectionLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
    flexShrink: 1,
  },
  fieldRow: {
    paddingVertical: 4,
    gap: 2,
  },
  fieldLabel: {
    fontSize: typeScale.caption,
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.3,
  },
  fieldValue: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  checkRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.sm,
    paddingVertical: 6,
  },
  checkLabel: {
    fontSize: typeScale.body,
    flexShrink: 1,
    flexBasis: '52%',
  },
  segment: {
    flexDirection: 'row',
    gap: spacing.xs,
  },
  segmentCell: {
    minHeight: 40,
    minWidth: 64,
    paddingHorizontal: 12,
    borderWidth: 1,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  segmentDisabled: {
    opacity: 0.5,
  },
  segmentText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  tileGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  tile: {
    flexGrow: 1,
    flexBasis: '46%',
    minHeight: 72,
    borderWidth: 1,
    borderRadius: 12,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    justifyContent: 'center',
    gap: 2,
  },
  tileLabel: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  tileMark: {
    fontSize: typeScale.caption,
    fontWeight: '600',
  },
  controlBlock: {
    paddingVertical: 6,
    gap: 2,
  },
  controlTitle: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  controlItem: {
    fontSize: typeScale.body,
    lineHeight: 22,
  },
  bulletText: {
    fontSize: typeScale.body,
    lineHeight: 24,
  },
  stepHeaderRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.sm,
  },
  stepTitle: {
    fontSize: typeScale.body,
    fontWeight: '700',
    flexShrink: 1,
  },
  stepDetail: {
    gap: spacing.xs,
    paddingTop: spacing.xs,
  },
  input: {
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    fontSize: typeScale.body,
    minHeight: 48,
  },
  inputMulti: {
    minHeight: 64,
    textAlignVertical: 'top',
  },
  stepperRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 4,
    gap: spacing.sm,
  },
  stepperLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
    flexShrink: 1,
  },
  stepperControls: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  stepBtn: {
    width: 44,
    height: 44,
    borderWidth: 1,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepDisabled: {
    opacity: 0.4,
  },
  stepBtnText: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  stepValue: {
    fontSize: typeScale.heading,
    fontWeight: '800',
    minWidth: 24,
    textAlign: 'center',
  },
  scoreRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 4,
    gap: spacing.sm,
  },
  scoreText: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  signatureFrame: {
    minHeight: 88,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.md,
  },
  signatureText: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  otherInput: {
    minHeight: 48,
    borderWidth: 1,
    borderRadius: 8,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    fontSize: typeScale.body,
    marginTop: spacing.sm,
  },
  subtleText: {
    fontSize: typeScale.label,
  },
  roleRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.sm,
  },
  roleChip: {
    minHeight: 40,
    paddingHorizontal: spacing.md,
    justifyContent: 'center',
    borderWidth: 1,
    borderRadius: 20,
  },
  roleChipText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
});
