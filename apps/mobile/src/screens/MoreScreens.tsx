/**
 * More & Settings (GUI Master §15 / screens 75–83) — the driver's settings hub. These screens are
 * low-stakes by design: profile + role, language/theme/text-size preferences, a driver-safe printer
 * panel, help/dispatch contacts, and a sign-out that is careful to say it does NOT punch you out.
 *
 * Selectable preferences (language, theme, text size) and toggles are SELF-MANAGING: each holds its
 * own internal state seeded from the matching optional prop, renders its active styling from that
 * state, and still forwards the existing callback so the app stays in sync. Action buttons with no
 * real wiring yet give inline, visible feedback on tap. Sign-out is an inline confirmation card (no
 * native modal dep) per the house pattern. Driver-facing language only: no UUIDs, env strings, hub
 * URLs, or storage internals (GUI Master §20).
 */
import { useState } from 'react';
import { Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  StatusBadge,
  spacing,
  typeScale,
  useResolvedTheme,
  useThemeChoice,
  type Theme,
  type Tone,
} from '../design';
import {
  callDispatch as dialDispatch,
  callNumber,
  DISPATCH_PHONE,
  SUPERVISOR_PHONE,
} from '../config/contacts';

/* ------------------------------------------------------------------ */
/* Shared local primitives                                            */
/* ------------------------------------------------------------------ */

/** A read-only "label : value" pair, used by Account and contact cards. */
function FieldRow(props: { label: string; value: string; theme: Theme }) {
  const t = props.theme;
  return (
    <View style={styles.fieldRow}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.label}</Text>
      <Text style={[styles.fieldValue, { color: t.text }]}>{props.value}</Text>
    </View>
  );
}

/** A single-select option row (radio-style) for language / theme / text-size pickers. */
function OptionRow(props: {
  label: string;
  hint?: string;
  selected: boolean;
  onPress: () => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  const { selected } = props;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onPress}
      accessibilityRole="radio"
      accessibilityState={{ selected }}
      accessibilityLabel={props.label}
      style={({ pressed }) => [
        styles.optionRow,
        { borderColor: selected ? t.primary : t.border },
        selected ? { backgroundColor: t.highlight } : null,
        pressed ? styles.pressed : null,
      ]}
    >
      <View style={styles.optionText}>
        <Text style={[styles.optionLabel, { color: t.text }]}>{props.label}</Text>
        {props.hint !== undefined ? (
          <Text style={[styles.optionHint, { color: t.textMuted }]}>{props.hint}</Text>
        ) : null}
      </View>
      <View style={[styles.radioOuter, { borderColor: selected ? t.primary : t.border }]}>
        {selected ? <View style={[styles.radioInner, { backgroundColor: t.primary }]} /> : null}
      </View>
    </Pressable>
  );
}

/** A tappable navigation row used by the More Home settings list. */
function NavRow(props: {
  label: string;
  badge?: { label: string; tone: Tone };
  onPress: () => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  return (
    <Pressable
      testID={props.testID}
      onPress={props.onPress}
      accessibilityRole="button"
      accessibilityLabel={props.label}
      style={({ pressed }) => [styles.navRow, pressed ? styles.pressed : null]}
    >
      <Text style={[styles.navLabel, { color: t.text }]}>{props.label}</Text>
      {props.badge !== undefined ? (
        <StatusBadge label={props.badge.label} tone={props.badge.tone} />
      ) : (
        <Text style={[styles.chevron, { color: t.textMuted }]}>›</Text>
      )}
    </Pressable>
  );
}

/** A short, inline confirmation line shown after an action button is tapped. */
function FeedbackLine(props: { text: string; tone?: Tone; theme: Theme }) {
  const t = props.theme;
  const tone = props.tone ?? 'success';
  const color =
    tone === 'success'
      ? t.success
      : tone === 'warning'
        ? t.warning
        : tone === 'danger'
          ? t.danger
          : tone === 'info'
            ? t.info
            : t.textMuted;
  return (
    <Text style={[styles.feedback, { color }]} accessibilityLiveRegion="polite">
      {props.text}
    </Text>
  );
}

/* ------------------------------------------------------------------ */
/* 75. More Home                                                      */
/* ------------------------------------------------------------------ */

export interface MoreHomeProps {
  driverName?: string;
  driverRole?: string;
  company?: string;
  /** Plain-English sync line, e.g. "All work synced" or "2 items waiting to sync". */
  syncSummary?: string;
  syncTone?: Tone;
  /** Whether Admin Mode entry is shown (still locked behind a PIN elsewhere). */
  showAdminMode?: boolean;
  onOpenAccount: () => void;
  /** Optional: when omitted, the Language row is hidden (i18n not yet shipped — see TODO). */
  onOpenLanguage?: () => void;
  onOpenTheme: () => void;
  onOpenTextSize: () => void;
  onOpenPrinter: () => void;
  onOpenHelp: () => void;
  onOpenContactDispatch: () => void;
  onOpenAdminMode: () => void;
  onSignOut: () => void;
  theme?: Theme;
}

export function MoreHomeScreen(props: MoreHomeProps) {
  const t = useResolvedTheme(props.theme);
  const driverName = props.driverName ?? 'Signed-in driver';
  const driverRole = props.driverRole ?? 'Driver';
  const company = props.company ?? 'Acme Oilfield Services';
  const syncSummary = props.syncSummary ?? 'All work is saved and up to date.';
  const syncTone = props.syncTone ?? 'success';
  const showAdminMode = props.showAdminMode ?? true;

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>More</Text>

      <Card theme={t} title="Profile" testID="more-profile">
        <Text style={[styles.profileName, { color: t.text }]}>{driverName}</Text>
        <Text style={[styles.profileMeta, { color: t.text }]}>{driverRole}</Text>
        <Text style={[styles.profileMeta, { color: t.textMuted }]}>{company}</Text>
      </Card>

      <Card theme={t} title="Sync summary" testID="more-sync">
        <StatusBadge label="Synced" tone={syncTone} />
        <Text style={[styles.body2, { color: t.text }]}>{syncSummary}</Text>
      </Card>

      <Card theme={t} title="Settings">
        <NavRow theme={t} label="Account" onPress={props.onOpenAccount} testID="more-account" />
        {/* Language is hidden until real i18n ships — never present a control that does nothing.
            TODO(i18n): translate screens (DVIR/JHA Spanish) then restore onOpenLanguage. */}
        {props.onOpenLanguage !== undefined ? (
          <NavRow
            theme={t}
            label="Language"
            onPress={props.onOpenLanguage}
            testID="more-language"
          />
        ) : null}
        <NavRow theme={t} label="Theme" onPress={props.onOpenTheme} testID="more-theme" />
        <NavRow theme={t} label="Text Size" onPress={props.onOpenTextSize} testID="more-textsize" />
        <NavRow theme={t} label="Printer" onPress={props.onOpenPrinter} testID="more-printer" />
        <NavRow theme={t} label="Help and Support" onPress={props.onOpenHelp} testID="more-help" />
        <NavRow
          theme={t}
          label="Contact Dispatch"
          onPress={props.onOpenContactDispatch}
          testID="more-dispatch"
        />
        {showAdminMode ? (
          <NavRow
            theme={t}
            label="Admin Mode"
            badge={{ label: 'Locked', tone: 'neutral' }}
            onPress={props.onOpenAdminMode}
            testID="more-admin"
          />
        ) : null}
      </Card>

      <Button
        theme={t}
        variant="secondary"
        label="Sign Out"
        onPress={props.onSignOut}
        testID="more-signout"
      />
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 76. Account                                                        */
/* ------------------------------------------------------------------ */

export interface AccountProps {
  name?: string;
  role?: string;
  employeeId?: string;
  phone?: string;
  assignedYard?: string;
  defaultTruck?: string;
  defaultTrailer?: string;
  onUpdateContactInfo?: () => void;
  onContactSupervisor?: () => void;
  theme?: Theme;
}

export function AccountScreen(props: AccountProps) {
  const t = useResolvedTheme(props.theme);
  const [requested, setRequested] = useState(false);
  const [contacting, setContacting] = useState(false);
  const missing = 'Not provided by Hub';

  const update = () => {
    setRequested(true);
    props.onUpdateContactInfo?.();
  };
  const contact = () => {
    setContacting(true);
    callNumber(SUPERVISOR_PHONE);
    props.onContactSupervisor?.();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Account</Text>

      <Card theme={t} title="Your details" testID="account-details">
        <FieldRow theme={t} label="Name" value={props.name ?? missing} />
        <FieldRow theme={t} label="Role" value={props.role ?? missing} />
        <FieldRow theme={t} label="Employee ID" value={props.employeeId ?? missing} />
        <FieldRow theme={t} label="Phone" value={props.phone ?? missing} />
        <FieldRow theme={t} label="Assigned Yard" value={props.assignedYard ?? missing} />
        <FieldRow theme={t} label="Default Truck" value={props.defaultTruck ?? missing} />
        <FieldRow theme={t} label="Default Trailer" value={props.defaultTrailer ?? missing} />
      </Card>

      <Card theme={t} title="Need a change?">
        <Text style={[styles.body2, { color: t.textMuted }]}>
          Your details come from the office. Ask to have them updated if anything here is wrong.
        </Text>
        <Button theme={t} label="Update Contact Info" onPress={update} testID="account-update" />
        {requested ? <FeedbackLine theme={t} text="Request sent to the office." /> : null}
        <Button
          theme={t}
          variant="secondary"
          label="Contact Supervisor"
          onPress={contact}
          testID="account-supervisor"
        />
        {contacting ? (
          <FeedbackLine theme={t} text="Contacting your supervisor…" tone="info" />
        ) : null}
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 77. Language                                                       */
/* ------------------------------------------------------------------ */

export type LanguageChoice = 'en' | 'es' | 'device';

const LANGUAGE_OPTIONS: readonly { key: LanguageChoice; label: string }[] = [
  { key: 'en', label: 'English' },
  { key: 'es', label: 'Español' },
  { key: 'device', label: 'Use device language' },
];

export interface LanguageProps {
  selected?: LanguageChoice;
  onSelect: (choice: LanguageChoice) => void;
  theme?: Theme;
}

export function LanguageScreen(props: LanguageProps) {
  const t = useResolvedTheme(props.theme);
  const [selected, setSelected] = useState<LanguageChoice>(props.selected ?? 'en');

  const choose = (key: LanguageChoice) => {
    setSelected(key);
    props.onSelect(key);
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Language</Text>

      <Card theme={t} title="App language">
        {LANGUAGE_OPTIONS.map((opt) => (
          <OptionRow
            key={opt.key}
            theme={t}
            label={opt.label}
            selected={opt.key === selected}
            onPress={() => choose(opt.key)}
            testID={`language-${opt.key}`}
          />
        ))}
      </Card>

      <Card theme={t} tone="highlight" title="About form languages">
        <Text style={[styles.body2, { color: t.text }]}>
          Some forms may be English-only when no approved Spanish version exists. Your DVIR and
          JHA/JSA are available in English and Spanish; the field ticket is English-only for now.
        </Text>
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 78. Theme                                                          */
/* ------------------------------------------------------------------ */

export type ThemeChoice = 'system' | 'light' | 'dark';

const THEME_OPTIONS: readonly { key: ThemeChoice; label: string; hint: string }[] = [
  { key: 'system', label: 'System', hint: 'Match your phone settings' },
  { key: 'light', label: 'Light', hint: 'Bright screen for daytime' },
  { key: 'dark', label: 'Dark', hint: 'Dim screen for night work' },
];

export interface ThemeProps {
  selected?: ThemeChoice;
  onSelect?: (choice: ThemeChoice) => void;
  theme?: Theme;
}

export function ThemeScreen(props: ThemeProps) {
  const t = useResolvedTheme(props.theme);
  // Source of truth is the app-wide theme context — selecting here re-themes the whole app and
  // persists across launches. (props.selected/onSelect remain for hosts/tests that want to observe.)
  const { choice, setChoice } = useThemeChoice();
  const selected = props.selected ?? choice;

  const choose = (key: ThemeChoice) => {
    setChoice(key);
    props.onSelect?.(key);
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Theme</Text>

      <Card theme={t} title="Appearance">
        {THEME_OPTIONS.map((opt) => (
          <OptionRow
            key={opt.key}
            theme={t}
            label={opt.label}
            hint={opt.hint}
            selected={opt.key === selected}
            onPress={() => choose(opt.key)}
            testID={`theme-${opt.key}`}
          />
        ))}
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 79. Text Size / Accessibility                                      */
/* ------------------------------------------------------------------ */

export type TextSizeChoice = 'default' | 'large' | 'extra-large';

const TEXT_SIZE_OPTIONS: readonly { key: TextSizeChoice; label: string }[] = [
  { key: 'default', label: 'Default' },
  { key: 'large', label: 'Large' },
  { key: 'extra-large', label: 'Extra Large' },
];

const ACCESSIBILITY_RULES: readonly string[] = [
  'Minimum touch target: 44 × 44 pt',
  'Preferred field action target: 52 × 52 pt',
  'No color-only status indicators',
  'Large labels for outdoor use',
];

export interface TextSizeProps {
  selectedSize?: TextSizeChoice;
  highContrast?: boolean;
  reduceMotion?: boolean;
  onSelectSize: (choice: TextSizeChoice) => void;
  onToggleHighContrast: (next: boolean) => void;
  onToggleReduceMotion: (next: boolean) => void;
  theme?: Theme;
}

export function TextSizeScreen(props: TextSizeProps) {
  const t = useResolvedTheme(props.theme);
  const [selectedSize, setSelectedSize] = useState<TextSizeChoice>(props.selectedSize ?? 'default');
  const [highContrast, setHighContrast] = useState(props.highContrast ?? false);
  const [reduceMotion, setReduceMotion] = useState(props.reduceMotion ?? false);

  const chooseSize = (key: TextSizeChoice) => {
    setSelectedSize(key);
    props.onSelectSize(key);
  };
  const toggleHighContrast = (next: boolean) => {
    setHighContrast(next);
    props.onToggleHighContrast(next);
  };
  const toggleReduceMotion = (next: boolean) => {
    setReduceMotion(next);
    props.onToggleReduceMotion(next);
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Text Size</Text>

      <Card theme={t} title="Text size">
        {TEXT_SIZE_OPTIONS.map((opt) => (
          <OptionRow
            key={opt.key}
            theme={t}
            label={opt.label}
            selected={opt.key === selectedSize}
            onPress={() => chooseSize(opt.key)}
            testID={`textsize-${opt.key}`}
          />
        ))}
      </Card>

      <Card theme={t} title="Accessibility">
        <ToggleRow
          theme={t}
          label="High Contrast"
          hint="Stronger borders and text"
          value={highContrast}
          onToggle={toggleHighContrast}
          testID="textsize-high-contrast"
        />
        <ToggleRow
          theme={t}
          label="Reduce Motion"
          hint="Limit animations"
          value={reduceMotion}
          onToggle={toggleReduceMotion}
          testID="textsize-reduce-motion"
        />
      </Card>

      <Card theme={t} tone="highlight" title="How the app stays readable">
        {ACCESSIBILITY_RULES.map((rule) => (
          <Text key={rule} style={[styles.body2, { color: t.text }]}>
            • {rule}
          </Text>
        ))}
      </Card>
    </View>
  );
}

/** An on/off accessibility toggle rendered as an accessible switch row. */
function ToggleRow(props: {
  label: string;
  hint?: string;
  value: boolean;
  onToggle: (next: boolean) => void;
  testID?: string;
  theme: Theme;
}) {
  const t = props.theme;
  const { value } = props;
  return (
    <Pressable
      testID={props.testID}
      onPress={() => props.onToggle(!value)}
      accessibilityRole="switch"
      accessibilityState={{ checked: value }}
      accessibilityLabel={props.label}
      style={({ pressed }) => [
        styles.optionRow,
        { borderColor: value ? t.primary : t.border },
        pressed ? styles.pressed : null,
      ]}
    >
      <View style={styles.optionText}>
        <Text style={[styles.optionLabel, { color: t.text }]}>{props.label}</Text>
        {props.hint !== undefined ? (
          <Text style={[styles.optionHint, { color: t.textMuted }]}>{props.hint}</Text>
        ) : null}
      </View>
      <View style={[styles.switchTrack, { backgroundColor: value ? t.primary : t.border }]}>
        <View
          style={[
            styles.switchThumb,
            { backgroundColor: t.card },
            value ? styles.switchThumbOn : styles.switchThumbOff,
          ]}
        />
      </View>
    </Pressable>
  );
}

/* ------------------------------------------------------------------ */
/* 80. Printer Settings                                               */
/* ------------------------------------------------------------------ */

export interface PrinterSettingsProps {
  printerName?: string;
  connected?: boolean;
  connectionMessage?: string;
  /** Whether the test-page action is permitted for this driver/printer. */
  testPageAllowed?: boolean;
  reconnecting?: boolean;
  printing?: boolean;
  actionMessage?: string;
  actionTone?: Tone;
  onPrinterHelp?: () => void;
  onReconnect?: () => void | Promise<void>;
  onPrintTestPage?: () => void | Promise<void>;
  theme?: Theme;
}

export function PrinterSettingsScreen(props: PrinterSettingsProps) {
  const t = useResolvedTheme(props.theme);
  const printerName = props.printerName ?? 'PT-210';
  const connected = props.connected ?? false;
  const testPageAllowed = props.testPageAllowed ?? true;
  const connectionMessage =
    props.connectionMessage ??
    (connected
      ? 'Your printer is connected and ready for field tickets.'
      : 'Printer not connected. Reconnect when you are near it to print field tickets.');
  const busy = (props.reconnecting ?? false) || (props.printing ?? false);

  const [helpOpened, setHelpOpened] = useState(false);
  const [reconnecting, setReconnecting] = useState(false);
  const [printed, setPrinted] = useState(false);
  const actionMessage =
    props.actionMessage ??
    (reconnecting ? 'Looking for your printer…' : printed ? 'Sent to printer.' : undefined);
  const actionTone = props.actionTone ?? (printed ? 'success' : 'info');

  const help = () => {
    setHelpOpened(true);
    props.onPrinterHelp?.();
  };
  const reconnect = () => {
    setReconnecting(true);
    setPrinted(false);
    props.onReconnect?.();
  };
  const printTest = () => {
    setPrinted(true);
    props.onPrintTestPage?.();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Printer</Text>

      <Card theme={t} title="Printer" testID="printer-status">
        <Text style={[styles.profileName, { color: t.text }]}>{printerName}</Text>
        <StatusBadge
          label={connected ? 'Synced' : 'Offline Mode'}
          tone={connected ? 'success' : 'warning'}
          testID="printer-connection"
        />
        <Text style={[styles.body2, { color: t.textMuted }]}>{connectionMessage}</Text>
      </Card>

      <Card theme={t} title="Actions">
        <Button
          theme={t}
          variant="secondary"
          label="Printer Help"
          onPress={help}
          testID="printer-help"
        />
        {helpOpened ? <FeedbackLine theme={t} text="Opening printer help…" tone="info" /> : null}
        <Button
          theme={t}
          label="Reconnect Printer"
          onPress={reconnect}
          disabled={busy}
          testID="printer-reconnect"
        />
        {actionMessage !== undefined ? (
          <FeedbackLine theme={t} text={actionMessage} tone={actionTone} />
        ) : null}
        <Button
          theme={t}
          variant="secondary"
          label="Print Test Page"
          onPress={printTest}
          disabled={!testPageAllowed || busy}
          testID="printer-test-page"
        />
        {!testPageAllowed ? (
          <Text style={[styles.optionHint, { color: t.textMuted }]}>
            Test page is available once the printer is connected.
          </Text>
        ) : !connected ? (
          <Text style={[styles.optionHint, { color: t.textMuted }]}>
            Test page will reconnect first if needed.
          </Text>
        ) : null}
      </Card>

      <Card theme={t}>
        <Text style={[styles.body2, { color: t.textMuted }]}>
          Advanced printer diagnostics are kept in Admin Mode for supervisors and support.
        </Text>
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 81. Help and Support                                               */
/* ------------------------------------------------------------------ */

export interface HelpSupportProps {
  /** Optional observers — the call buttons dial the OS directly; nav is provided by the host. */
  onCallDispatch?: () => void;
  onCallSupervisor?: () => void;
  onViewSops?: () => void;
  onEmergencyContacts?: () => void;
  theme?: Theme;
}

export function HelpSupportScreen(props: HelpSupportProps) {
  const t = useResolvedTheme(props.theme);
  const [feedback, setFeedback] = useState<{ text: string; tone: Tone } | null>(null);

  const callDispatch = () => {
    setFeedback({ text: 'Calling dispatch…', tone: 'info' });
    dialDispatch();
    props.onCallDispatch?.();
  };
  const callSupervisor = () => {
    setFeedback({ text: 'Calling your supervisor…', tone: 'info' });
    callNumber(SUPERVISOR_PHONE);
    props.onCallSupervisor?.();
  };
  const reportProblem = () => {
    setFeedback({ text: 'Opening a message to dispatch…', tone: 'info' });
    void Linking.openURL(`sms:${DISPATCH_PHONE}?body=${encodeURIComponent('App problem: ')}`).catch(
      () => undefined,
    );
  };
  const viewSops = () => {
    setFeedback({ text: 'Opening SOPs…', tone: 'info' });
    props.onViewSops?.();
  };
  const emergency = () => {
    setFeedback({ text: 'Opening emergency contacts…', tone: 'danger' });
    props.onEmergencyContacts?.();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Help and Support</Text>

      <Card theme={t} title="Get help">
        <Button
          theme={t}
          label="Call Dispatch"
          onPress={callDispatch}
          testID="help-call-dispatch"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Call Supervisor"
          onPress={callSupervisor}
          testID="help-call-supervisor"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Report App Problem"
          onPress={reportProblem}
          testID="help-report-problem"
        />
        <Button
          theme={t}
          variant="secondary"
          label="View SOPs"
          onPress={viewSops}
          testID="help-view-sops"
        />
        {feedback !== null ? (
          <FeedbackLine theme={t} text={feedback.text} tone={feedback.tone} />
        ) : null}
      </Card>

      <Card theme={t} tone="highlight" title="Emergency">
        <Text style={[styles.body2, { color: t.text }]}>
          In an emergency, stop work and make the area safe first. Emergency contacts are always
          reachable here.
        </Text>
        <Button
          theme={t}
          variant="destructive"
          label="Emergency Contacts"
          onPress={emergency}
          testID="help-emergency-contacts"
        />
      </Card>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 82. Contact Dispatch                                               */
/* ------------------------------------------------------------------ */

export interface ContactEntry {
  key: string;
  /** Driver-facing role label, e.g. "Dispatch", "Office", "Supervisor". */
  role: string;
  name?: string;
  phone?: string;
}

export interface ContactDispatchProps {
  contacts?: ContactEntry[];
  /** Optional observers — the screen itself dials/messages via the OS, these just notify the host. */
  onCall?: (key: string) => void;
  onMessage?: (key: string) => void;
  onSendJobLocation?: (key: string) => void;
  theme?: Theme;
}

// There is no "Midland office" — drivers reach Field Dispatch (the on-duty dispatcher).
const DEFAULT_CONTACTS: ContactEntry[] = [
  { key: 'dispatch', role: 'On-Duty Dispatcher', name: 'Field Dispatch', phone: '(432) 555-0100' },
  { key: 'supervisor', role: 'Supervisor', name: 'Dana Whitfield', phone: '(432) 555-0123' },
  {
    key: 'emergency',
    role: 'Emergency Contact',
    name: 'Safety Line',
    phone: '(432) 555-0911',
  },
];

/** Strip a display phone down to a dialable string. */
function dialable(phone: string | undefined): string | undefined {
  if (phone === undefined) return undefined;
  const digits = phone.replace(/[^0-9+]/g, '');
  return digits.length > 0 ? digits : undefined;
}

export function ContactDispatchScreen(props: ContactDispatchProps) {
  const t = useResolvedTheme(props.theme);
  const contacts =
    props.contacts !== undefined && props.contacts.length > 0 ? props.contacts : DEFAULT_CONTACTS;

  /** Per-contact inline confirmation, keyed by contact key. */
  const [feedback, setFeedback] = useState<Record<string, { text: string; tone: Tone }>>({});

  const setLine = (key: string, text: string, tone: Tone) => {
    setFeedback((prev) => ({ ...prev, [key]: { text, tone } }));
  };

  const phoneFor = (key: string) => dialable(contacts.find((c) => c.key === key)?.phone);

  const call = (key: string) => {
    const num = phoneFor(key);
    if (num === undefined) {
      setLine(key, 'No phone number on file.', 'warning');
      return;
    }
    setLine(key, 'Calling…', 'info');
    void Linking.openURL(`tel:${num}`).catch(() =>
      setLine(key, 'Could not start the call.', 'warning'),
    );
    props.onCall?.(key);
  };
  const message = (key: string) => {
    const num = phoneFor(key);
    if (num === undefined) {
      setLine(key, 'No phone number on file.', 'warning');
      return;
    }
    setLine(key, 'Opening a message…', 'info');
    void Linking.openURL(`sms:${num}`).catch(() =>
      setLine(key, 'Could not open messages.', 'warning'),
    );
    props.onMessage?.(key);
  };
  const sendLocation = (key: string) => {
    const num = phoneFor(key);
    if (num === undefined) {
      setLine(key, 'No phone number on file.', 'warning');
      return;
    }
    setLine(key, 'Opening a message with your job location…', 'info');
    const body = encodeURIComponent('My current job location: ');
    void Linking.openURL(`sms:${num}?body=${body}`).catch(() =>
      setLine(key, 'Could not open messages.', 'warning'),
    );
    props.onSendJobLocation?.(key);
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Contact Dispatch</Text>

      {contacts.map((c) => {
        const emergency = c.key === 'emergency';
        const line = feedback[c.key];
        return (
          <Card
            key={c.key}
            theme={t}
            tone={emergency ? 'highlight' : 'default'}
            title={c.role}
            testID={`contact-${c.key}`}
          >
            {c.name !== undefined ? (
              <Text style={[styles.profileMeta, { color: t.text }]}>{c.name}</Text>
            ) : null}
            {c.phone !== undefined ? (
              <Text style={[styles.body2, { color: t.textMuted }]}>{c.phone}</Text>
            ) : null}
            <Button
              theme={t}
              variant={emergency ? 'destructive' : 'primary'}
              label="Call"
              onPress={() => call(c.key)}
              testID={`contact-call-${c.key}`}
            />
            <Button
              theme={t}
              variant="secondary"
              label="Message"
              onPress={() => message(c.key)}
              testID={`contact-message-${c.key}`}
            />
            <Button
              theme={t}
              variant="secondary"
              label="Send Job Location"
              onPress={() => sendLocation(c.key)}
              testID={`contact-location-${c.key}`}
            />
            {line !== undefined ? (
              <FeedbackLine theme={t} text={line.text} tone={line.tone} />
            ) : null}
          </Card>
        );
      })}
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* 83. Sign Out Confirmation                                          */
/* ------------------------------------------------------------------ */

export interface SignOutConfirmProps {
  /** When true, the screen warns the driver they are still on the clock. */
  punchedIn?: boolean;
  onCancel: () => void;
  onConfirmSignOut: () => void;
  theme?: Theme;
}

export function SignOutConfirmScreen(props: SignOutConfirmProps) {
  const t = useResolvedTheme(props.theme);
  const punchedIn = props.punchedIn ?? false;
  const [busy, setBusy] = useState(false);

  const confirm = () => {
    setBusy(true);
    props.onConfirmSignOut();
  };

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Sign out?</Text>

      <Card theme={t} tone="highlight" title="Sign out of the app" testID="signout-confirm">
        <Text style={[styles.body2, { color: t.text }]}>
          This only signs you out of the app. It does not punch you out.
        </Text>
        <Text style={[styles.body2, { color: t.text }]}>Saved work will stay on this phone.</Text>
      </Card>

      {punchedIn ? (
        <Card theme={t} testID="signout-punch-warning">
          <StatusBadge label="Punched In" tone="warning" />
          <Text style={[styles.body2, { color: t.text }]}>
            You are still punched in. Punch out from the Day screen when your workday is complete.
          </Text>
        </Card>
      ) : null}

      <View style={styles.actions}>
        <Button
          theme={t}
          variant="secondary"
          label="Cancel"
          onPress={props.onCancel}
          disabled={busy}
          testID="signout-cancel"
        />
        <Button
          theme={t}
          variant="destructive"
          label={busy ? 'Signing Out…' : 'Sign Out'}
          onPress={confirm}
          disabled={busy}
          testID="signout-confirm-action"
        />
      </View>
    </View>
  );
}

/* ------------------------------------------------------------------ */
/* Styles                                                             */
/* ------------------------------------------------------------------ */

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
  feedback: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  profileName: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  profileMeta: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  fieldRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingVertical: 6,
    gap: spacing.md,
  },
  fieldLabel: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  fieldValue: {
    fontSize: typeScale.body,
    fontWeight: '700',
    flexShrink: 1,
    textAlign: 'right',
  },
  navRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 48,
    paddingVertical: spacing.sm,
  },
  navLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
  chevron: {
    fontSize: typeScale.heading,
    fontWeight: '700',
  },
  optionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 52,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderWidth: 1,
    borderRadius: 10,
    gap: spacing.md,
  },
  optionText: {
    flexShrink: 1,
    gap: 2,
  },
  optionLabel: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
  optionHint: {
    fontSize: typeScale.caption,
  },
  radioOuter: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioInner: {
    width: 12,
    height: 12,
    borderRadius: 6,
  },
  switchTrack: {
    width: 48,
    height: 28,
    borderRadius: 14,
    padding: 2,
    justifyContent: 'center',
  },
  switchThumb: {
    width: 24,
    height: 24,
    borderRadius: 12,
  },
  switchThumbOn: {
    alignSelf: 'flex-end',
  },
  switchThumbOff: {
    alignSelf: 'flex-start',
  },
  pressed: {
    opacity: 0.85,
  },
  actions: {
    gap: spacing.sm,
  },
});
