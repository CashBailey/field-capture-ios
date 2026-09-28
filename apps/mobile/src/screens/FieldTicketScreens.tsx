/**
 * Field Ticket pages (GUI Master §11 / screens 44–52) — the digital field ticket flow a driver
 * fills out after the JHA/JSA: Overview → Job Info → Times → Load/Tank 1 → Load/Tank 2 →
 * Barrels & Line Items → Evidence & Signature → Review → Submitted.
 *
 * Self-managing form surfaces: every control owns its selected/typed state internally (seeded from
 * the matching optional prop) so it visibly responds on tap, and still calls the host's optional
 * callback when one is supplied. Required navigation callbacks (onBegin/onNext/onReview/onSubmit/…)
 * are driven by the app and pass through untouched. Driver-facing language only — no UUIDs,
 * payloads, queues, or env strings (GUI Master §20). Realistic sample fallbacks fill any absent
 * props so the screens are legible in isolation.
 */
import { useState, type ReactNode } from 'react';
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

// ---------------------------------------------------------------------------
// Shared driver-facing status vocabulary (GUI Master §20)
// ---------------------------------------------------------------------------

/** Evidence capture state — the small set an evidence row can be in. */
export type EvidenceState = 'Not Started' | 'Captured' | 'Pending Sync' | 'Synced';

const EVIDENCE_TONE: Record<EvidenceState, Tone> = {
  'Not Started': 'neutral',
  Captured: 'info',
  'Pending Sync': 'warning',
  Synced: 'success',
};

/** Ticket capture mode (GUI Master §44 selector). */
export type TicketMode = 'Digital' | 'Paper' | 'Hybrid';

const TICKET_MODES: readonly TicketMode[] = ['Digital', 'Paper', 'Hybrid'];

// ---------------------------------------------------------------------------
// Small presentational building blocks (local to this file)
// ---------------------------------------------------------------------------

/** A labelled read-only key/value row used by the Review summary. */
function SummaryRow(props: { theme: Theme; label: string; value: string }) {
  const { theme: t } = props;
  return (
    <View style={styles.summaryRow}>
      <Text style={[styles.summaryLabel, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.summaryValue, { color: t.text }]}>{props.value}</Text>
    </View>
  );
}

/**
 * A single labelled, self-managing text field. Holds its own value in state (seeded from the
 * initial value) so typing always shows; reports changes via the optional onChange.
 */
function Field(props: {
  theme: Theme;
  label: string;
  value: string;
  placeholder?: string;
  keypad?: boolean;
  onChange?: (next: string) => void;
  testID?: string;
}) {
  const { theme: t } = props;
  const [value, setValue] = useState(props.value);
  return (
    <View style={styles.field}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.label}</Text>
      <TextInput
        testID={props.testID}
        style={[
          styles.input,
          { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
        ]}
        value={value}
        placeholder={props.placeholder ?? ''}
        placeholderTextColor={t.textMuted}
        keyboardType={props.keypad === true ? 'numeric' : 'default'}
        onChangeText={(next) => {
          setValue(next);
          props.onChange?.(next);
        }}
      />
    </View>
  );
}

/** A paired feet / inches numeric input for gauge readings (GUI Master §47). Self-managing. */
function FeetInchesField(props: {
  theme: Theme;
  label: string;
  feet: string;
  inches: string;
  onChangeFeet?: (next: string) => void;
  onChangeInches?: (next: string) => void;
  testID?: string;
}) {
  const { theme: t } = props;
  const [feet, setFeet] = useState(props.feet);
  const [inches, setInches] = useState(props.inches);
  return (
    <View style={styles.field}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.label}</Text>
      <View style={styles.pairRow}>
        <View style={styles.pairCell}>
          <TextInput
            testID={props.testID !== undefined ? `${props.testID}-ft` : undefined}
            style={[
              styles.input,
              { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
            ]}
            value={feet}
            keyboardType="numeric"
            placeholder="0"
            placeholderTextColor={t.textMuted}
            onChangeText={(next) => {
              setFeet(next);
              props.onChangeFeet?.(next);
            }}
          />
          <Text style={[styles.unit, { color: t.textMuted }]}>ft</Text>
        </View>
        <View style={styles.pairCell}>
          <TextInput
            testID={props.testID !== undefined ? `${props.testID}-in` : undefined}
            style={[
              styles.input,
              { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
            ]}
            value={inches}
            keyboardType="numeric"
            placeholder="0"
            placeholderTextColor={t.textMuted}
            onChangeText={(next) => {
              setInches(next);
              props.onChangeInches?.(next);
            }}
          />
          <Text style={[styles.unit, { color: t.textMuted }]}>in</Text>
        </View>
      </View>
    </View>
  );
}

/** A capture/preview placeholder frame (real camera/signature pad is wired elsewhere). */
function CaptureFrame(props: { theme: Theme; caption: string }) {
  const { theme: t } = props;
  return (
    <View style={[styles.frame, { borderColor: t.border, backgroundColor: t.cardMuted }]}>
      <Text style={[styles.frameText, { color: t.textMuted }]}>{props.caption}</Text>
    </View>
  );
}

/** A small inline confirmation line — visible feedback for actions not yet fully wired. */
function FeedbackLine(props: { theme: Theme; text: string; testID?: string }) {
  const { theme: t } = props;
  return (
    <Text testID={props.testID} style={[styles.feedback, { color: t.success }]}>
      {props.text}
    </Text>
  );
}

/** A confirm modal overlay (presentational; no native modal dep). */
function ConfirmOverlay(props: {
  theme: Theme;
  title: string;
  body: string;
  cancelLabel: string;
  confirmLabel: string;
  onCancel: () => void;
  onConfirm: () => void;
  children?: ReactNode;
}) {
  const { theme: t } = props;
  return (
    <View style={styles.overlay} testID="ticket-confirm-overlay">
      <View style={[styles.sheet, { backgroundColor: t.card, borderColor: t.border }]}>
        <Text style={[styles.sheetTitle, { color: t.text }]}>{props.title}</Text>
        <Text style={[styles.body2, { color: t.text }]}>{props.body}</Text>
        {props.children}
        <Button
          theme={t}
          label={props.confirmLabel}
          onPress={props.onConfirm}
          testID="ticket-confirm-yes"
        />
        <Button
          theme={t}
          variant="secondary"
          label={props.cancelLabel}
          onPress={props.onCancel}
          testID="ticket-confirm-cancel"
        />
      </View>
    </View>
  );
}

// ===========================================================================
// 44. Field Ticket Overview
// ===========================================================================

export function FieldTicketOverviewScreen(props: {
  /** When false, the ticket is locked behind the JHA/JSA. */
  jhaComplete: boolean;
  srNumber?: string;
  customer?: string;
  lease?: string;
  mode?: TicketMode;
  onSelectMode?: (mode: TicketMode) => void;
  onBegin: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const sr = props.srNumber ?? 'SR 2026-000001';
  const customer = props.customer ?? 'Acme Energy';
  const lease = props.lease ?? 'Northfield Lease';
  const [mode, setMode] = useState<TicketMode>(props.mode ?? 'Digital');

  if (!props.jhaComplete) {
    return (
      <View style={styles.body}>
        <Text style={[styles.h1, { color: t.text }]}>Field Ticket</Text>
        <Card theme={t} title="Field Ticket Locked" testID="ticket-locked">
          <StatusBadge label="Locked" tone="neutral" />
          <Text style={[styles.body2, { color: t.text }]}>
            Complete the JHA/JSA before starting the field ticket.
          </Text>
        </Card>
      </View>
    );
  }

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Field Ticket</Text>

      <Card theme={t} tone="highlight" title={sr} testID="ticket-overview-job">
        <Text style={[styles.body2, { color: t.text }]}>
          {customer} · {lease}
        </Text>
        <StatusBadge label="Not Started" tone="neutral" />
      </Card>

      <Card theme={t} title="Ticket mode">
        <View style={styles.segment}>
          {TICKET_MODES.map((m) => {
            const selected = m === mode;
            return (
              <Pressable
                key={m}
                testID={`ticket-mode-${m}`}
                onPress={() => {
                  setMode(m);
                  props.onSelectMode?.(m);
                }}
                accessibilityRole="button"
                accessibilityState={{ selected }}
                style={[
                  styles.segmentCell,
                  { borderColor: selected ? t.primary : t.border },
                  selected ? { backgroundColor: t.primary } : null,
                ]}
              >
                <Text style={[styles.segmentText, { color: selected ? t.onPrimary : t.textMuted }]}>
                  {m}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </Card>

      <Button theme={t} label="Begin Ticket" onPress={props.onBegin} testID="ticket-begin" />
    </View>
  );
}

// ===========================================================================
// 45. Field Ticket Job Info
// ===========================================================================

export function FieldTicketJobInfoScreen(props: {
  ticketNo?: string;
  company?: string;
  date?: string;
  lease?: string;
  well?: string;
  rig?: string;
  driver?: string;
  orderedBy?: string;
  truckUnit?: string;
  trailerUnit?: string;
  onChangeField?: (field: string, value: string) => void;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const change = props.onChangeField;
  const bind = (field: string) =>
    change !== undefined ? { onChange: (v: string) => change(field, v) } : {};

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Job Info</Text>
      <Text style={[styles.subtle, { color: t.textMuted }]}>
        We filled in what we already know. Check it and add anything missing.
      </Text>

      <Card theme={t} title="Ticket details">
        <Field
          theme={t}
          label="Field Ticket No."
          value={props.ticketNo ?? 'TKT-10488'}
          {...bind('ticketNo')}
        />
        <Field
          theme={t}
          label="Company"
          value={props.company ?? 'Acme Energy'}
          {...bind('company')}
        />
        <Field theme={t} label="Date" value={props.date ?? 'Jun 16, 2026'} {...bind('date')} />
        <Field theme={t} label="Lease" value={props.lease ?? 'Northfield'} {...bind('lease')} />
        <Field theme={t} label="Well #" value={props.well ?? '114H'} {...bind('well')} />
        <Field theme={t} label="Rig #" value={props.rig ?? '—'} {...bind('rig')} />
      </Card>

      <Card theme={t} title="Crew and units">
        <Field
          theme={t}
          label="Driver"
          value={props.driver ?? 'Truck 7 Driver'}
          {...bind('driver')}
        />
        <Field
          theme={t}
          label="Ordered By"
          value={props.orderedBy ?? 'Acme Dispatch'}
          {...bind('orderedBy')}
        />
        <Field
          theme={t}
          label="Truck Unit #"
          value={props.truckUnit ?? 'Truck 7'}
          {...bind('truckUnit')}
        />
        <Field
          theme={t}
          label="Trailer Unit #"
          value={props.trailerUnit ?? 'Vacuum Trailer 19'}
          {...bind('trailerUnit')}
        />
      </Card>

      <Button theme={t} label="Next: Times" onPress={props.onNext} testID="ticket-jobinfo-next" />
    </View>
  );
}

// ===========================================================================
// 46. Field Ticket Times
// ===========================================================================

type TimeSlot = 'yardArrival' | 'timeIn' | 'timeOut';

/** A single time card that manages its own stamped value and edit state. */
function TimeCard(props: {
  theme: Theme;
  slotKey: TimeSlot;
  label: string;
  value: string;
  onUseCurrentTime?: (slot: TimeSlot) => void;
  onEditManually?: (slot: TimeSlot) => void;
}) {
  const t = props.theme;
  const [value, setValue] = useState(props.value);
  const [editing, setEditing] = useState(false);

  /** A driver-readable current time stamp; deterministic-free (real clock is host-wired). */
  const stampNow = () => {
    const now = new Date();
    const h = now.getHours();
    const m = now.getMinutes();
    const ampm = h >= 12 ? 'PM' : 'AM';
    const h12 = h % 12 === 0 ? 12 : h % 12;
    return `${h12}:${m.toString().padStart(2, '0')} ${ampm}`;
  };

  return (
    <Card theme={t} title={props.label} testID={`ticket-time-${props.slotKey}`}>
      {editing ? (
        <TextInput
          testID={`ticket-time-input-${props.slotKey}`}
          style={[
            styles.input,
            { color: t.text, borderColor: t.border, backgroundColor: t.cardMuted },
          ]}
          value={value}
          placeholder="8:30 AM"
          placeholderTextColor={t.textMuted}
          onChangeText={setValue}
        />
      ) : (
        <Text style={[styles.timeValue, { color: t.text }]}>{value}</Text>
      )}
      <View style={styles.btnRow}>
        <View style={styles.btnHalf}>
          <Button
            theme={t}
            label="Use Current Time"
            onPress={() => {
              setValue(stampNow());
              setEditing(false);
              props.onUseCurrentTime?.(props.slotKey);
            }}
            testID={`ticket-time-now-${props.slotKey}`}
          />
        </View>
        <View style={styles.btnHalf}>
          <Button
            theme={t}
            variant="secondary"
            label={editing ? 'Done' : 'Edit Manually'}
            onPress={() => {
              setEditing((prev) => !prev);
              props.onEditManually?.(props.slotKey);
            }}
            testID={`ticket-time-edit-${props.slotKey}`}
          />
        </View>
      </View>
    </Card>
  );
}

export function FieldTicketTimesScreen(props: {
  yardArrival?: string;
  timeIn?: string;
  timeOut?: string;
  /** Stamp the current time into a slot. */
  onUseCurrentTime?: (slot: TimeSlot) => void;
  onEditManually?: (slot: TimeSlot) => void;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);

  const slots: readonly { key: TimeSlot; label: string; value: string }[] = [
    { key: 'yardArrival', label: 'Yard Arrival Time', value: props.yardArrival ?? '6:05 AM' },
    { key: 'timeIn', label: 'Time In', value: props.timeIn ?? '8:14 AM' },
    { key: 'timeOut', label: 'Time Out', value: props.timeOut ?? '—' },
  ];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Times</Text>

      {slots.map((slot) => (
        <TimeCard
          key={slot.key}
          theme={t}
          slotKey={slot.key}
          label={slot.label}
          value={slot.value}
          {...(props.onUseCurrentTime !== undefined
            ? { onUseCurrentTime: props.onUseCurrentTime }
            : {})}
          {...(props.onEditManually !== undefined ? { onEditManually: props.onEditManually } : {})}
        />
      ))}

      <Button
        theme={t}
        label="Next: Load / Tank 1"
        onPress={props.onNext}
        testID="ticket-times-next"
      />
    </View>
  );
}

// ===========================================================================
// 47 & 48. Field Ticket Load / Tank (shared body)
// ===========================================================================

/** A feet/inches gauge value. */
export interface GaugeReading {
  feet: string;
  inches: string;
}

const EMPTY_GAUGE: GaugeReading = { feet: '', inches: '' };

function LoadTankBody(props: {
  theme: Theme;
  tankLabel: string;
  locationTime: string;
  tank: string;
  beginTotal: GaugeReading;
  beginWater: GaugeReading;
  beginCondensate: GaugeReading;
  endTotal: GaugeReading;
  endWater: GaugeReading;
  endCondensate: GaugeReading;
  waterPulled: GaugeReading;
  barrelsPulled: string;
  onChangeField?: (field: string, value: string) => void;
  onChangeGauge?: (field: string, part: 'feet' | 'inches', value: string) => void;
}) {
  const t = props.theme;
  const change = props.onChangeField;
  const changeGauge = props.onChangeGauge;
  const bindText = (field: string) =>
    change !== undefined ? { onChange: (v: string) => change(field, v) } : {};
  const bindGauge = (field: string) =>
    changeGauge !== undefined
      ? {
          onChangeFeet: (v: string) => changeGauge(field, 'feet', v),
          onChangeInches: (v: string) => changeGauge(field, 'inches', v),
        }
      : {};

  return (
    <>
      <Card theme={t} title="Location">
        <Field
          theme={t}
          label="Location Time"
          value={props.locationTime}
          placeholder="8:30 AM"
          {...bindText('locationTime')}
        />
        <Field
          theme={t}
          label="Tank"
          value={props.tank}
          placeholder="Tank 1"
          {...bindText('tank')}
        />
      </Card>

      <Card theme={t} title="Beginning Gauge">
        <FeetInchesField
          theme={t}
          label="Total Reading"
          {...props.beginTotal}
          {...bindGauge('beginTotal')}
          testID="gauge-begin-total"
        />
        <FeetInchesField
          theme={t}
          label="Water Reading"
          {...props.beginWater}
          {...bindGauge('beginWater')}
          testID="gauge-begin-water"
        />
        <FeetInchesField
          theme={t}
          label="Condensate"
          {...props.beginCondensate}
          {...bindGauge('beginCondensate')}
          testID="gauge-begin-cond"
        />
      </Card>

      <Card theme={t} title="Ending Gauge">
        <FeetInchesField
          theme={t}
          label="Total Reading"
          {...props.endTotal}
          {...bindGauge('endTotal')}
          testID="gauge-end-total"
        />
        <FeetInchesField
          theme={t}
          label="Water Reading"
          {...props.endWater}
          {...bindGauge('endWater')}
          testID="gauge-end-water"
        />
        <FeetInchesField
          theme={t}
          label="Condensate"
          {...props.endCondensate}
          {...bindGauge('endCondensate')}
          testID="gauge-end-cond"
        />
      </Card>

      <Card theme={t} title="Result">
        <FeetInchesField
          theme={t}
          label="Amount of Water Pulled"
          {...props.waterPulled}
          {...bindGauge('waterPulled')}
          testID="gauge-water-pulled"
        />
        <Field
          theme={t}
          label="Barrels Pulled"
          value={props.barrelsPulled}
          placeholder="0"
          keypad
          {...bindText('barrelsPulled')}
        />
      </Card>
    </>
  );
}

export function FieldTicketLoadTank1Screen(props: {
  locationTime?: string;
  tank?: string;
  beginTotal?: GaugeReading;
  beginWater?: GaugeReading;
  beginCondensate?: GaugeReading;
  endTotal?: GaugeReading;
  endWater?: GaugeReading;
  endCondensate?: GaugeReading;
  waterPulled?: GaugeReading;
  barrelsPulled?: string;
  onChangeField?: (field: string, value: string) => void;
  onChangeGauge?: (field: string, part: 'feet' | 'inches', value: string) => void;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Load / Tank 1</Text>
      <LoadTankBody
        theme={t}
        tankLabel="Tank 1"
        locationTime={props.locationTime ?? ''}
        tank={props.tank ?? 'Tank 1'}
        beginTotal={props.beginTotal ?? EMPTY_GAUGE}
        beginWater={props.beginWater ?? EMPTY_GAUGE}
        beginCondensate={props.beginCondensate ?? EMPTY_GAUGE}
        endTotal={props.endTotal ?? EMPTY_GAUGE}
        endWater={props.endWater ?? EMPTY_GAUGE}
        endCondensate={props.endCondensate ?? EMPTY_GAUGE}
        waterPulled={props.waterPulled ?? EMPTY_GAUGE}
        barrelsPulled={props.barrelsPulled ?? ''}
        {...(props.onChangeField !== undefined ? { onChangeField: props.onChangeField } : {})}
        {...(props.onChangeGauge !== undefined ? { onChangeGauge: props.onChangeGauge } : {})}
      />
      <Button
        theme={t}
        label="Next: Load / Tank 2"
        onPress={props.onNext}
        testID="ticket-tank1-next"
      />
    </View>
  );
}

export function FieldTicketLoadTank2Screen(props: {
  /** When true the driver marked there is no second load — fields collapse. */
  noSecondLoad?: boolean;
  onToggleNoSecondLoad?: (next: boolean) => void;
  locationTime?: string;
  tank?: string;
  beginTotal?: GaugeReading;
  beginWater?: GaugeReading;
  beginCondensate?: GaugeReading;
  endTotal?: GaugeReading;
  endWater?: GaugeReading;
  endCondensate?: GaugeReading;
  waterPulled?: GaugeReading;
  barrelsPulled?: string;
  onChangeField?: (field: string, value: string) => void;
  onChangeGauge?: (field: string, part: 'feet' | 'inches', value: string) => void;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [noSecond, setNoSecond] = useState(props.noSecondLoad ?? false);

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Load / Tank 2</Text>

      <Card theme={t} title="Second load">
        <View style={styles.row}>
          <Text style={[styles.body2, { color: t.text, flex: 1 }]}>
            {noSecond
              ? 'Marked as no second load.'
              : 'Record a second tank, or mark there isn’t one.'}
          </Text>
          {noSecond ? <StatusBadge label="Saved on Phone" tone="success" /> : null}
        </View>
        <Button
          theme={t}
          variant={noSecond ? 'secondary' : 'destructive'}
          label={noSecond ? 'Add second load' : 'No second load'}
          onPress={() => {
            const next = !noSecond;
            setNoSecond(next);
            props.onToggleNoSecondLoad?.(next);
          }}
          testID="ticket-tank2-toggle"
        />
      </Card>

      {noSecond ? null : (
        <LoadTankBody
          theme={t}
          tankLabel="Tank 2"
          locationTime={props.locationTime ?? ''}
          tank={props.tank ?? 'Tank 2'}
          beginTotal={props.beginTotal ?? EMPTY_GAUGE}
          beginWater={props.beginWater ?? EMPTY_GAUGE}
          beginCondensate={props.beginCondensate ?? EMPTY_GAUGE}
          endTotal={props.endTotal ?? EMPTY_GAUGE}
          endWater={props.endWater ?? EMPTY_GAUGE}
          endCondensate={props.endCondensate ?? EMPTY_GAUGE}
          waterPulled={props.waterPulled ?? EMPTY_GAUGE}
          barrelsPulled={props.barrelsPulled ?? ''}
          {...(props.onChangeField !== undefined ? { onChangeField: props.onChangeField } : {})}
          {...(props.onChangeGauge !== undefined ? { onChangeGauge: props.onChangeGauge } : {})}
        />
      )}

      <Button
        theme={t}
        label="Next: Barrels and Line Items"
        onPress={props.onNext}
        testID="ticket-tank2-next"
      />
    </View>
  );
}

// ===========================================================================
// 49. Field Ticket Barrels and Line Items
// ===========================================================================

/** A single billing line item. Rate/total are optional — hidden from drivers when sensitive. */
export interface LineItem {
  key: string;
  description: string;
  quantity: string;
  rate?: string;
  total?: string;
}

export function FieldTicketLineItemsScreen(props: {
  totalBarrelsPulled?: string;
  lineItems?: LineItem[];
  /** When false, Rate/Total columns are hidden (OpsHub calculates billing). */
  showRates?: boolean;
  grandTotal?: string;
  onNext: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const showRates = props.showRates ?? false;
  const items: LineItem[] = props.lineItems ?? [
    {
      key: 'l1',
      description: 'Saltwater disposal',
      quantity: '120 bbl',
      rate: '$2.10',
      total: '$252.00',
    },
    { key: 'l2', description: 'Standby time', quantity: '0.5 hr', rate: '$95.00', total: '$47.50' },
  ];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Barrels and Line Items</Text>

      <Card theme={t} tone="highlight" title="Total Barrels Pulled">
        <Text style={[styles.bigNumber, { color: t.text }]}>
          {props.totalBarrelsPulled ?? '120 bbl'}
        </Text>
      </Card>

      <Card theme={t} title="Line items">
        <View style={styles.liHeaderRow}>
          <Text style={[styles.liHead, { color: t.textMuted, flex: 2 }]}>Description</Text>
          <Text style={[styles.liHead, { color: t.textMuted, flex: 1, textAlign: 'right' }]}>
            Qty
          </Text>
          {showRates ? (
            <>
              <Text style={[styles.liHead, { color: t.textMuted, flex: 1, textAlign: 'right' }]}>
                Rate
              </Text>
              <Text style={[styles.liHead, { color: t.textMuted, flex: 1, textAlign: 'right' }]}>
                Total
              </Text>
            </>
          ) : null}
        </View>
        {items.map((item) => (
          <View key={item.key} style={styles.liRow} testID={`line-item-${item.key}`}>
            <Text style={[styles.liCell, { color: t.text, flex: 2 }]}>{item.description}</Text>
            <Text style={[styles.liCell, { color: t.text, flex: 1, textAlign: 'right' }]}>
              {item.quantity}
            </Text>
            {showRates ? (
              <>
                <Text style={[styles.liCell, { color: t.text, flex: 1, textAlign: 'right' }]}>
                  {item.rate ?? '—'}
                </Text>
                <Text style={[styles.liCell, { color: t.text, flex: 1, textAlign: 'right' }]}>
                  {item.total ?? '—'}
                </Text>
              </>
            ) : null}
          </View>
        ))}
        {showRates ? (
          <View style={styles.grandRow}>
            <Text style={[styles.grandLabel, { color: t.text }]}>Grand Total</Text>
            <Text style={[styles.grandValue, { color: t.text }]}>
              {props.grandTotal ?? '$299.50'}
            </Text>
          </View>
        ) : (
          <Text style={[styles.subtle, { color: t.textMuted }]}>
            Billing rates are calculated by Ops Hub after you submit.
          </Text>
        )}
      </Card>

      <Button
        theme={t}
        label="Next: Evidence and Signature"
        onPress={props.onNext}
        testID="ticket-lineitems-next"
      />
    </View>
  );
}

// ===========================================================================
// 50. Field Ticket Evidence and Signature
// ===========================================================================

export interface EvidenceItem {
  key: string;
  label: string;
  required: boolean;
  state: EvidenceState;
}

const isSignatureKey = (key: string) => key.includes('signature');

/** One evidence row that manages its own captured state and shows inline feedback on tap. */
function EvidenceCard(props: {
  theme: Theme;
  item: EvidenceItem;
  onCapture?: (key: string) => void;
}) {
  const t = props.theme;
  const { item } = props;
  const [state, setState] = useState<EvidenceState>(item.state);
  const [justCaptured, setJustCaptured] = useState(false);
  const done = state !== 'Not Started';
  const isSig = isSignatureKey(item.key);
  const isGps = item.key === 'gps-event';
  const captionVerb = isSig ? 'Sign' : isGps ? 'Stamp' : 'Photo';

  const capture = () => {
    setState('Captured');
    setJustCaptured(true);
    props.onCapture?.(item.key);
  };

  const confirmText = isSig
    ? 'Signature captured'
    : isGps
      ? 'GPS stamped'
      : 'Photo added — saved on this phone';

  return (
    <Card theme={t} title={item.label} testID={`evidence-${item.key}`}>
      <View style={styles.row}>
        <StatusBadge
          label={item.required ? 'Required' : 'Optional'}
          tone={item.required ? 'warning' : 'neutral'}
        />
        <StatusBadge label={state} tone={EVIDENCE_TONE[state]} />
      </View>
      <CaptureFrame
        theme={t}
        caption={
          done
            ? `${captionVerb} captured — tap below to retake.`
            : `No ${item.label.toLowerCase()} yet.`
        }
      />
      <View style={styles.btnRow}>
        <View style={styles.btnHalf}>
          <Button
            theme={t}
            label={done ? 'Retake' : isSig ? 'Sign' : isGps ? 'Capture GPS' : 'Take Photo'}
            onPress={capture}
            testID={`evidence-capture-${item.key}`}
          />
        </View>
        {done ? (
          <View style={styles.btnHalf}>
            <Button
              theme={t}
              variant="secondary"
              label="Use Photo"
              onPress={() => {
                setJustCaptured(true);
                props.onCapture?.(item.key);
              }}
              testID={`evidence-use-${item.key}`}
            />
          </View>
        ) : null}
      </View>
      {justCaptured ? (
        <FeedbackLine theme={t} text={confirmText} testID={`evidence-feedback-${item.key}`} />
      ) : null}
    </Card>
  );
}

export function FieldTicketEvidenceScreen(props: {
  items?: EvidenceItem[];
  onCapture?: (key: string) => void;
  onReview: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const items: EvidenceItem[] = props.items ?? [
    { key: 'ticket-photo', label: 'Ticket Photo', required: true, state: 'Captured' },
    { key: 'disposal-photo', label: 'Disposal Photo', required: true, state: 'Captured' },
    { key: 'receipt-photo', label: 'Receipt Photo', required: false, state: 'Not Started' },
    { key: 'customer-signature', label: 'Customer Signature', required: true, state: 'Captured' },
    { key: 'driver-signature', label: 'Driver Signature', required: true, state: 'Not Started' },
    { key: 'gps-event', label: 'GPS Event', required: true, state: 'Synced' },
  ];

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Evidence and Signature</Text>
      <Text style={[styles.subtle, { color: t.textMuted }]}>
        Capture each required item. Anything you capture is saved on this phone right away.
      </Text>

      {items.map((item) => (
        <EvidenceCard
          key={item.key}
          theme={t}
          item={item}
          {...(props.onCapture !== undefined ? { onCapture: props.onCapture } : {})}
        />
      ))}

      <Button
        theme={t}
        label="Review Ticket"
        onPress={props.onReview}
        testID="ticket-evidence-next"
      />
    </View>
  );
}

// ===========================================================================
// 51. Field Ticket Review
// ===========================================================================

export function FieldTicketReviewScreen(props: {
  ticketNo?: string;
  srNumber?: string;
  customer?: string;
  lease?: string;
  well?: string;
  timeIn?: string;
  timeOut?: string;
  barrelsPulled?: string;
  photosAttached?: number;
  signatureCaptured?: boolean;
  submitting?: boolean;
  onSubmit: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [confirming, setConfirming] = useState(false);

  const ticketNo = props.ticketNo ?? 'TKT-10488';
  const sr = props.srNumber ?? 'SR 2026-000001';
  const photos = props.photosAttached ?? 2;
  const signed = props.signatureCaptured ?? true;
  const submitting = props.submitting ?? false;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Review</Text>

      <Card theme={t} title="Review Field Ticket" testID="ticket-review-card">
        <SummaryRow theme={t} label="Ticket No." value={ticketNo} />
        <SummaryRow theme={t} label="Customer" value={props.customer ?? 'Acme Energy'} />
        <SummaryRow theme={t} label="Lease" value={props.lease ?? 'Northfield Lease'} />
        <SummaryRow theme={t} label="Well" value={props.well ?? 'Northfield 06H'} />
        <SummaryRow theme={t} label="Time In" value={props.timeIn ?? '8:14 AM'} />
        <SummaryRow theme={t} label="Time Out" value={props.timeOut ?? '10:42 AM'} />
        <SummaryRow theme={t} label="Barrels Pulled" value={props.barrelsPulled ?? '120 bbl'} />
        <SummaryRow theme={t} label="Photos" value={`${photos} attached`} />
        <SummaryRow
          theme={t}
          label="Signature"
          value={signed ? 'Customer signature captured' : 'Not captured'}
        />
      </Card>

      <Button
        theme={t}
        label={submitting ? 'Submitting…' : 'Submit Field Ticket'}
        onPress={() => setConfirming(true)}
        disabled={submitting}
        testID="ticket-review-submit"
      />

      {confirming ? (
        <ConfirmOverlay
          theme={t}
          title="Submit field ticket?"
          body={`This will submit ${ticketNo} for ${sr}.`}
          cancelLabel="Cancel"
          confirmLabel="Submit Ticket"
          onCancel={() => setConfirming(false)}
          onConfirm={() => {
            setConfirming(false);
            void props.onSubmit();
          }}
        >
          <Text style={[styles.subtle, { color: t.textMuted }]}>
            If offline, it will be saved on this phone and synced later.
          </Text>
        </ConfirmOverlay>
      ) : null}
    </View>
  );
}

// ===========================================================================
// 52. Field Ticket Submitted
// ===========================================================================

export function FieldTicketSubmittedScreen(props: {
  ticketNo?: string;
  barrelsPulled?: string;
  /** Sync state of the just-submitted ticket. */
  state?: 'Saved on Phone' | 'Pending Sync' | 'Syncing' | 'Synced' | 'Submitted';
  onReviewJob: () => void;
  onPrint?: () => void;
  onStartNextJob?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const state = props.state ?? 'Saved on Phone';
  const stateTone: Tone =
    state === 'Synced' || state === 'Submitted'
      ? 'success'
      : state === 'Saved on Phone'
        ? 'info'
        : 'warning';

  const [printed, setPrinted] = useState(false);

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Field Ticket Submitted</Text>

      <Card
        theme={t}
        tone="highlight"
        title={props.ticketNo ?? 'TKT-10488'}
        testID="ticket-submitted-card"
      >
        <Text style={[styles.bigNumber, { color: t.text }]}>
          {props.barrelsPulled ?? '120 bbl'}
        </Text>
        <StatusBadge label={state} tone={stateTone} />
        <Text style={[styles.body2, { color: t.text }]}>
          Your ticket is safe on this phone. It will sync to Ops Hub automatically when you have a
          connection.
        </Text>
      </Card>

      <Button
        theme={t}
        label="Review Job"
        onPress={props.onReviewJob}
        testID="ticket-submitted-review"
      />

      <View style={styles.btnRow}>
        <View style={styles.btnHalf}>
          <Button
            theme={t}
            variant="secondary"
            label="Print Ticket"
            onPress={() => {
              setPrinted(true);
              props.onPrint?.();
            }}
            testID="ticket-submitted-print"
          />
        </View>
        <View style={styles.btnHalf}>
          <Button
            theme={t}
            variant="secondary"
            label="Start Next Job"
            onPress={() => props.onStartNextJob?.()}
            testID="ticket-submitted-next"
          />
        </View>
      </View>

      {printed ? (
        <FeedbackLine theme={t} text="Sent to printer" testID="ticket-submitted-print-feedback" />
      ) : null}
    </View>
  );
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  subtle: {
    fontSize: typeScale.label,
    lineHeight: 21,
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  feedback: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  // Segmented control (ticket mode)
  segment: {
    flexDirection: 'row',
    gap: spacing.xs,
  },
  segmentCell: {
    flex: 1,
    minHeight: sizing.minTouchTarget,
    borderWidth: 1,
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.sm,
  },
  segmentText: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  // Fields
  field: {
    gap: spacing.xs,
  },
  fieldLabel: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  input: {
    minHeight: sizing.minTouchTarget,
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    fontSize: typeScale.body,
  },
  pairRow: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  pairCell: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
  unit: {
    fontSize: typeScale.label,
    fontWeight: '700',
    width: 22,
  },
  // Times
  timeValue: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  btnRow: {
    flexDirection: 'row',
    gap: spacing.sm,
  },
  btnHalf: {
    flex: 1,
  },
  // Capture frame
  frame: {
    minHeight: 96,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.md,
  },
  frameText: {
    fontSize: typeScale.label,
    textAlign: 'center',
  },
  // Line items
  bigNumber: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  liHeaderRow: {
    flexDirection: 'row',
    gap: spacing.sm,
    paddingBottom: spacing.xs,
  },
  liHead: {
    fontSize: typeScale.caption,
    fontWeight: '700',
  },
  liRow: {
    flexDirection: 'row',
    gap: spacing.sm,
    paddingVertical: 6,
  },
  liCell: {
    fontSize: typeScale.label,
  },
  grandRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingTop: spacing.sm,
  },
  grandLabel: {
    fontSize: typeScale.body,
    fontWeight: '800',
  },
  grandValue: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  // Review summary
  summaryRow: {
    paddingVertical: 6,
  },
  summaryLabel: {
    fontSize: typeScale.caption,
    fontWeight: '600',
  },
  summaryValue: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  // Confirm overlay
  overlay: {
    marginTop: spacing.sm,
  },
  sheet: {
    borderWidth: 1,
    borderRadius: sizing.cardRadius,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  sheetTitle: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
});
