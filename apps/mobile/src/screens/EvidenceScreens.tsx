/**
 * Evidence, photo, receipt, GPS, signature, and print screens
 * (GUI Master §12 / screens 53–61):
 *
 *   53. Job Evidence          — evidence categories + Add Evidence menu
 *   54. Camera Capture        — placeholder camera viewfinder + capture
 *   55. Photo Review          — review a just-captured photo, save/retake/delete
 *   56. Receipt Capture       — capture / choose / skip a receipt image
 *   57. Receipt Form          — vendor / amount / category for a receipt
 *   58. Signature Capture      — signer details + placeholder signature pad
 *   59. GPS Capture           — driver-safe location evidence (coords hidden)
 *   60. Print Ticket          — driver-safe printing of ticket / summary / receipt
 *   61. Job Complete Review   — end-of-job summary + start next / end day
 *
 * Presentational only. No camera/signature/GPS/print native modules — each capture surface is a
 * bordered placeholder frame; the real capture is wired elsewhere. Driver-facing language only:
 * never render UUIDs, coordinates by default, sync internals, or any storage/transport wording
 * (GUI Master §20). Statuses use the approved label set, mapped to StatusBadge tones.
 *
 * Every interactive control here is SELF-MANAGING: its highlighted/selected state lives in internal
 * useState (seeded from the matching optional prop when present) so a tap always re-renders the
 * control. Optional callbacks are still invoked when provided; required navigation callbacks
 * (onStartNextJob / onEndDay) are passed straight through so the app can drive navigation. Action
 * buttons that have no real effect yet flip a small internal flag and show an inline confirmation
 * line — never a silent no-op.
 */
import { useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { isFlowbackJob, type TicketCaptureMethod } from '../domain';
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
  type Tone,
} from '../design';

/* ------------------------------------------------------------------ shared */

/** The approved status labels this file uses, mapped to a reinforcing badge tone (GUI Master §20). */
type EvidenceStatus =
  | 'Not Started'
  | 'In Progress'
  | 'Required'
  | 'Needs Review'
  | 'Saved on Phone'
  | 'Pending Sync'
  | 'Syncing'
  | 'Synced'
  | 'Submitted'
  | 'Complete';

const STATUS_TONE: Record<EvidenceStatus, Tone> = {
  'Not Started': 'neutral',
  'In Progress': 'info',
  Required: 'warning',
  'Needs Review': 'warning',
  'Saved on Phone': 'info',
  'Pending Sync': 'info',
  Syncing: 'info',
  Synced: 'success',
  Submitted: 'success',
  Complete: 'success',
};

function StatusPill(props: { status: EvidenceStatus; testID?: string }) {
  return (
    <StatusBadge
      label={props.status}
      tone={STATUS_TONE[props.status]}
      {...(props.testID !== undefined ? { testID: props.testID } : {})}
    />
  );
}

/**
 * An inline confirmation line for actions whose real effect lands elsewhere ("Photo added",
 * "Saved on this phone"). Reuses the muted meta text + a success badge so the feedback is never
 * color-alone. Renders nothing until the action has fired.
 */
function FeedbackLine(props: { theme: Theme; message?: string; testID?: string }) {
  if (props.message === undefined) return null;
  const t = props.theme;
  return (
    <View style={styles.rowBetween} testID={props.testID}>
      <Text style={[styles.meta, { color: t.textMuted }]}>{props.message}</Text>
      <StatusBadge label="Done" tone="success" />
    </View>
  );
}

/**
 * A bordered, dashed placeholder where a native capture surface (camera/pad/map) lands later.
 * When `onPress` is supplied it becomes tappable so the driver gets a visible response (e.g. the
 * signature pad "captures" a mark) even though the real surface is wired elsewhere.
 */
function PlaceholderFrame(props: {
  theme: Theme;
  label: string;
  hint?: string;
  testID?: string;
  onPress?: () => void;
  active?: boolean;
}) {
  const t = props.theme;
  const frameStyle = [
    styles.frame,
    { borderColor: props.active ? t.primary : t.border, backgroundColor: t.cardMuted },
  ];
  const body = (
    <>
      <Text style={[styles.frameLabel, { color: t.textMuted }]}>{props.label}</Text>
      {props.hint !== undefined ? (
        <Text style={[styles.frameHint, { color: t.textMuted }]}>{props.hint}</Text>
      ) : null}
    </>
  );

  if (props.onPress !== undefined) {
    const onPress = props.onPress;
    return (
      <Pressable
        testID={props.testID}
        onPress={onPress}
        accessibilityRole="button"
        accessibilityLabel={props.label}
        style={({ pressed }) => [...frameStyle, pressed ? styles.framePressed : null]}
      >
        {body}
      </Pressable>
    );
  }

  return (
    <View
      testID={props.testID}
      style={frameStyle}
      accessibilityRole="image"
      accessibilityLabel={props.label}
    >
      {body}
    </View>
  );
}

/** A simple labeled chip row used to pick a category / type. Selection is presentational. */
function ChipPicker(props: {
  theme: Theme;
  options: readonly string[];
  selected: string;
  onSelect: (value: string) => void;
  idPrefix: string;
}) {
  const t = props.theme;
  return (
    <View style={styles.chipRow}>
      {props.options.map((option) => {
        const selected = option === props.selected;
        return (
          <Pressable
            key={option}
            testID={`${props.idPrefix}-${option}`}
            onPress={() => props.onSelect(option)}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            accessibilityLabel={option}
            style={[
              styles.chip,
              { borderColor: selected ? t.primary : t.border },
              selected ? { backgroundColor: t.primary } : null,
            ]}
          >
            <Text style={[styles.chipText, { color: selected ? t.onPrimary : t.textMuted }]}>
              {option}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

function Field(props: {
  theme: Theme;
  label: string;
  value: string;
  onChangeText: (value: string) => void;
  placeholder: string;
  testID: string;
  keyboardType?: 'default' | 'numeric';
}) {
  const t = props.theme;
  return (
    <View style={styles.field}>
      <Text style={[styles.fieldLabel, { color: t.textMuted }]}>{props.label}</Text>
      <TextInput
        testID={props.testID}
        style={[styles.input, { borderColor: t.border, color: t.text, backgroundColor: t.card }]}
        value={props.value}
        onChangeText={props.onChangeText}
        placeholder={props.placeholder}
        placeholderTextColor={t.textMuted}
        accessibilityLabel={props.label}
        {...(props.keyboardType !== undefined ? { keyboardType: props.keyboardType } : {})}
      />
    </View>
  );
}

/* --------------------------------------------------------- 53. Job Evidence */

export interface EvidenceCategory {
  key: string;
  /** Driver-facing category name, e.g. "Field Photos". */
  label: string;
  count: number;
  status: EvidenceStatus;
  /** Plain time of last capture, e.g. "Today 8:47 AM". Absent if nothing captured yet. */
  lastCaptured?: string;
}

const DEFAULT_EVIDENCE_CATEGORIES: readonly EvidenceCategory[] = [
  {
    key: 'field-photos',
    label: 'Field Photos',
    count: 2,
    status: 'Saved on Phone',
    lastCaptured: 'Today 8:47 AM',
  },
  { key: 'disposal-photos', label: 'Disposal Photos', count: 0, status: 'Not Started' },
  {
    key: 'ticket-photos',
    label: 'Ticket Photos',
    count: 1,
    status: 'Saved on Phone',
    lastCaptured: 'Today 9:02 AM',
  },
  {
    key: 'receipt-images',
    label: 'Receipt Images',
    count: 1,
    status: 'Pending Sync',
    lastCaptured: 'Today 9:10 AM',
  },
  { key: 'signatures', label: 'Signatures', count: 0, status: 'Required' },
  { key: 'other', label: 'Other', count: 0, status: 'Not Started' },
];

/** A single add-evidence menu entry. `key` is reported verbatim to `onAddEvidence`. */
interface EvidenceMenuItem {
  key: string;
  label: string;
}

export type EvidenceMenuRoute = 'camera' | 'receipt' | 'signature';

export function evidenceRouteForMenuKey(key: string): EvidenceMenuRoute {
  switch (key) {
    case 'receipt-photo':
      return 'receipt';
    case 'signature':
    case 'customer-signature':
      return 'signature';
    default:
      return 'camera';
  }
}

/**
 * The add-evidence menu the driver sees, derived from the job context so the offered items match
 * what this job actually needs (items 5–8):
 *  - `ticket-photo` is offered ONLY when the ticket's captureMethod is 'hybrid'.
 *  - `customer-signature` is offered ONLY for flowback jobs (driver signature is always available).
 *  - `gps-event` is NOT offered — location evidence is captured automatically (background geofence),
 *    never a manual driver step.
 *  - an OPTIONAL `photo` item is always offered so the driver can add multiple captioned photos.
 */
export function buildEvidenceMenu(ctx?: {
  captureMethod?: TicketCaptureMethod;
  jobType?: string;
}): EvidenceMenuItem[] {
  const flowback = isFlowbackJob(ctx?.jobType);
  const menu: EvidenceMenuItem[] = [
    { key: 'field-photo', label: 'Field Photo' },
    { key: 'disposal-photo', label: 'Disposal Photo' },
  ];
  if (ctx?.captureMethod === 'hybrid') {
    menu.push({ key: 'ticket-photo', label: 'Ticket Photo' });
  }
  menu.push({ key: 'receipt-photo', label: 'Receipt Photo' });
  menu.push({ key: 'signature', label: 'Driver Signature' });
  if (flowback) {
    menu.push({ key: 'customer-signature', label: 'Customer Signature' });
  }
  // GPS event intentionally omitted — captured automatically, not a driver step (item 7).
  menu.push({ key: 'photo', label: 'Add Photo (optional)' });
  menu.push({ key: 'other', label: 'Other' });
  return menu;
}

export function JobEvidenceScreen(props: {
  jobLabel?: string;
  categories?: readonly EvidenceCategory[];
  /** The ticket's capture method — gates whether Ticket Photo is offered (item 5). */
  captureMethod?: TicketCaptureMethod;
  /** The SR's job type — gates whether Customer Signature is offered (item 6, flowback only). */
  jobType?: string;
  /** Called with the menu item key (e.g. "field-photo") when the driver picks what to add. */
  onAddEvidence?: (key: string) => void;
  /** Called when the driver adds an optional, self-titled photo (item 8). Never required. */
  onAddPhoto?: (photo: { title: string }) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const categories = props.categories ?? DEFAULT_EVIDENCE_CATEGORIES;
  const menuItems = buildEvidenceMenu({
    ...(props.captureMethod !== undefined ? { captureMethod: props.captureMethod } : {}),
    ...(props.jobType !== undefined ? { jobType: props.jobType } : {}),
  });
  const [menuOpen, setMenuOpen] = useState(false);
  const [picked, setPicked] = useState<string | undefined>(undefined);
  // Optional photos the driver titles themselves — multiple allowed, never required (item 8).
  const [photoTitle, setPhotoTitle] = useState('');
  const [optionalPhotos, setOptionalPhotos] = useState<string[]>([]);

  const addOptionalPhoto = () => {
    const title = photoTitle.trim();
    if (title === '') return;
    setOptionalPhotos((prev) => [...prev, title]);
    setPhotoTitle('');
    setPicked(`Added optional photo "${title}"`);
    props.onAddPhoto?.({ title });
  };

  return (
    <View style={styles.body} testID="job-evidence">
      <Text style={[styles.h1, { color: t.text }]}>Job Evidence</Text>
      <Text style={[styles.subtitle, { color: t.textMuted }]}>
        {props.jobLabel ?? 'Acme Energy · Northfield 114H'}
      </Text>

      {categories.map((cat) => (
        <Card key={cat.key} theme={t} title={cat.label} testID={`evidence-cat-${cat.key}`}>
          <View style={styles.rowBetween}>
            <Text style={[styles.body2, { color: t.text }]}>
              {cat.count === 0
                ? 'Nothing captured yet'
                : `${cat.count} item${cat.count === 1 ? '' : 's'}`}
            </Text>
            <StatusPill status={cat.status} testID={`evidence-status-${cat.key}`} />
          </View>
          {cat.lastCaptured !== undefined ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>
              Last captured {cat.lastCaptured}
            </Text>
          ) : null}
        </Card>
      ))}

      <Card theme={t} title="Optional photos" testID="optional-photos">
        <Text style={[styles.meta, { color: t.textMuted }]}>
          Add as many photos as you like and title each one. These are optional.
        </Text>
        {optionalPhotos.map((title, index) => (
          <View
            key={`${title}-${index}`}
            style={styles.rowBetween}
            testID={`optional-photo-${index}`}
          >
            <Text style={[styles.body2, { color: t.text }]}>{title}</Text>
            <StatusBadge label="Optional" tone="neutral" />
          </View>
        ))}
        <Field
          theme={t}
          label="Photo title"
          value={photoTitle}
          onChangeText={setPhotoTitle}
          placeholder="e.g. Tank gauge before load"
          testID="optional-photo-title-input"
        />
        <Button
          theme={t}
          variant="secondary"
          label="Add Photo"
          onPress={addOptionalPhoto}
          testID="optional-photo-add"
        />
      </Card>

      <Card theme={t} tone="highlight" title="Add evidence">
        {menuOpen ? (
          <View style={styles.menu}>
            {menuItems.map((item) => (
              <Button
                key={item.key}
                theme={t}
                variant="secondary"
                label={item.label}
                onPress={() => {
                  setMenuOpen(false);
                  setPicked(`${item.label} ready to capture`);
                  props.onAddEvidence?.(item.key);
                }}
                testID={`evidence-add-${item.key}`}
              />
            ))}
            <Button
              theme={t}
              variant="secondary"
              label="Cancel"
              onPress={() => setMenuOpen(false)}
              testID="evidence-add-cancel"
            />
          </View>
        ) : (
          <Button
            theme={t}
            label="Add Evidence"
            onPress={() => setMenuOpen(true)}
            testID="evidence-add-open"
          />
        )}
        <FeedbackLine theme={t} message={picked} testID="evidence-add-feedback" />
      </Card>
    </View>
  );
}

/* ------------------------------------------------------- 54. Camera Capture */

export function CameraCaptureScreen(props: {
  categoryLabel?: string;
  /** Called when the driver presses the shutter; the captured photo is reviewed elsewhere. */
  onCapture?: () => void;
  onCancel?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [flashOn, setFlashOn] = useState(false);
  const [captured, setCaptured] = useState(false);

  return (
    <View style={styles.body} testID="camera-capture">
      <Text style={[styles.h1, { color: t.text }]}>Take Photo</Text>
      <Text style={[styles.subtitle, { color: t.textMuted }]}>
        {props.categoryLabel ?? 'Field Photo'}
      </Text>

      <PlaceholderFrame
        theme={t}
        label="Camera view"
        hint="Point the camera at the subject, then press Capture."
        active={captured}
        testID="camera-viewfinder"
      />

      <View style={styles.rowBetween}>
        <Text style={[styles.body2, { color: t.text }]}>Flash</Text>
        <StatusBadge
          label={flashOn ? 'On' : 'Off'}
          tone={flashOn ? 'info' : 'neutral'}
          testID="camera-flash-state"
        />
      </View>
      <Button
        theme={t}
        variant="secondary"
        label={flashOn ? 'Turn Flash Off' : 'Turn Flash On'}
        onPress={() => setFlashOn((on) => !on)}
        testID="camera-flash-toggle"
      />

      <Button
        theme={t}
        label="Capture"
        onPress={() => {
          setCaptured(true);
          props.onCapture?.();
        }}
        testID="camera-capture-btn"
      />
      <FeedbackLine
        theme={t}
        message={captured ? 'Photo captured' : undefined}
        testID="camera-feedback"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Cancel"
        onPress={() => props.onCancel?.()}
        testID="camera-cancel"
      />
    </View>
  );
}

/* --------------------------------------------------------- 55. Photo Review */

const PHOTO_CATEGORIES = [
  'Field Photo',
  'Disposal Photo',
  'Ticket Photo',
  'Receipt Photo',
  'Other',
] as const;

export function PhotoReviewScreen(props: {
  category?: string;
  caption?: string;
  jobLabel?: string;
  timestamp?: string;
  gpsAttached?: boolean;
  /** Status after the driver presses Use Photo; shown once saved. */
  savedStatus?: EvidenceStatus;
  onChangeCategory?: (category: string) => void;
  onChangeCaption?: (caption: string) => void;
  onUsePhoto?: () => void;
  onRetake?: () => void;
  onDelete?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [category, setCategory] = useState(props.category ?? 'Field Photo');
  const [caption, setCaption] = useState(props.caption ?? '');
  const [savedStatus, setSavedStatus] = useState<EvidenceStatus | undefined>(props.savedStatus);
  const [actionMessage, setActionMessage] = useState<string | undefined>(undefined);
  const [gpsAttached, setGpsAttached] = useState(props.gpsAttached ?? true);

  return (
    <View style={styles.body} testID="photo-review">
      <Text style={[styles.h1, { color: t.text }]}>Photo Review</Text>

      <PlaceholderFrame theme={t} label="Photo preview" testID="photo-preview" />

      {savedStatus !== undefined ? (
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>Saved</Text>
          <StatusPill status={savedStatus} testID="photo-saved-status" />
        </View>
      ) : null}

      <Card theme={t} title="Details">
        <Text style={[styles.fieldLabel, { color: t.textMuted }]}>Category</Text>
        <ChipPicker
          theme={t}
          options={PHOTO_CATEGORIES}
          selected={category}
          onSelect={(value) => {
            setCategory(value);
            props.onChangeCategory?.(value);
          }}
          idPrefix="photo-category"
        />
        <Field
          theme={t}
          label="Caption"
          value={caption}
          onChangeText={(value) => {
            setCaption(value);
            props.onChangeCaption?.(value);
          }}
          placeholder="Add a short caption"
          testID="photo-caption-input"
        />
        <View style={styles.rowBetween}>
          <Text style={[styles.meta, { color: t.textMuted }]}>Job</Text>
          <Text style={[styles.metaValue, { color: t.text }]}>
            {props.jobLabel ?? 'Northfield 114H'}
          </Text>
        </View>
        <View style={styles.rowBetween}>
          <Text style={[styles.meta, { color: t.textMuted }]}>Timestamp</Text>
          <Text style={[styles.metaValue, { color: t.text }]}>
            {props.timestamp ?? 'Today 8:47 AM'}
          </Text>
        </View>
        <Pressable
          testID="photo-gps-toggle"
          onPress={() => setGpsAttached((on) => !on)}
          accessibilityRole="switch"
          accessibilityState={{ checked: gpsAttached }}
          accessibilityLabel="GPS attached"
          style={styles.rowBetween}
        >
          <Text style={[styles.meta, { color: t.textMuted }]}>GPS attached</Text>
          <StatusBadge
            label={gpsAttached ? 'Yes' : 'No'}
            tone={gpsAttached ? 'success' : 'neutral'}
            testID="photo-gps-attached"
          />
        </Pressable>
      </Card>

      <Button
        theme={t}
        label="Use Photo"
        onPress={() => {
          setSavedStatus('Saved on Phone');
          setActionMessage('Saved on this phone');
          props.onUsePhoto?.();
        }}
        testID="photo-use"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Retake"
        onPress={() => {
          setSavedStatus(undefined);
          setActionMessage('Ready to retake');
          props.onRetake?.();
        }}
        testID="photo-retake"
      />
      <Button
        theme={t}
        variant="destructive"
        label="Delete"
        onPress={() => {
          setSavedStatus(undefined);
          setActionMessage('Photo deleted');
          props.onDelete?.();
        }}
        testID="photo-delete"
      />
      <FeedbackLine theme={t} message={actionMessage} testID="photo-feedback" />
    </View>
  );
}

/* ------------------------------------------------------ 56. Receipt Capture */

export function ReceiptCaptureScreen(props: {
  onCaptureReceipt?: () => void;
  onChooseFromPhotos?: () => void;
  onSkipPhoto?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [captured, setCaptured] = useState(false);
  const [message, setMessage] = useState<string | undefined>(undefined);

  return (
    <View style={styles.body} testID="receipt-capture">
      <Text style={[styles.h1, { color: t.text }]}>Receipt Photo</Text>
      <Text style={[styles.subtitle, { color: t.textMuted }]}>
        Capture the receipt so it stays with this job.
      </Text>

      <PlaceholderFrame
        theme={t}
        label="Receipt image"
        hint="Lay the receipt flat and fill the frame."
        active={captured}
        testID="receipt-frame"
      />

      <Button
        theme={t}
        label="Capture Receipt"
        onPress={() => {
          setCaptured(true);
          setMessage('Receipt captured');
          props.onCaptureReceipt?.();
        }}
        testID="receipt-capture-btn"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Choose from Photos"
        onPress={() => {
          setCaptured(true);
          setMessage('Receipt chosen from photos');
          props.onChooseFromPhotos?.();
        }}
        testID="receipt-choose"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Skip Photo"
        onPress={() => {
          setCaptured(false);
          setMessage('Skipped for now');
          props.onSkipPhoto?.();
        }}
        testID="receipt-skip"
      />
      <FeedbackLine theme={t} message={message} testID="receipt-capture-feedback" />
    </View>
  );
}

/* --------------------------------------------------------- 57. Receipt Form */

const RECEIPT_CATEGORIES = ['Disposal', 'Fuel', 'Parts', 'Other'] as const;

export function ReceiptFormScreen(props: {
  category?: string;
  vendor?: string;
  receiptNumber?: string;
  amount?: string;
  notes?: string;
  hasPhoto?: boolean;
  onSave?: (receipt: {
    category: string;
    vendor: string;
    receiptNumber: string;
    amount: string;
    notes: string;
  }) => void;
  onAddPhoto?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [category, setCategory] = useState(props.category ?? 'Disposal');
  const [vendor, setVendor] = useState(props.vendor ?? '');
  const [receiptNumber, setReceiptNumber] = useState(props.receiptNumber ?? '');
  const [amount, setAmount] = useState(props.amount ?? '');
  const [notes, setNotes] = useState(props.notes ?? '');
  const [hasPhoto, setHasPhoto] = useState(props.hasPhoto ?? false);
  const [savedMessage, setSavedMessage] = useState<string | undefined>(undefined);

  return (
    <View style={styles.body} testID="receipt-form">
      <Text style={[styles.h1, { color: t.text }]}>Receipt</Text>

      <Card theme={t} title="Receipt details">
        <Text style={[styles.fieldLabel, { color: t.textMuted }]}>Category</Text>
        <ChipPicker
          theme={t}
          options={RECEIPT_CATEGORIES}
          selected={category}
          onSelect={setCategory}
          idPrefix="receipt-category"
        />
        <Field
          theme={t}
          label="Vendor"
          value={vendor}
          onChangeText={setVendor}
          placeholder="e.g. Acme Disposal Yard"
          testID="receipt-vendor-input"
        />
        <Field
          theme={t}
          label="Receipt Number"
          value={receiptNumber}
          onChangeText={setReceiptNumber}
          placeholder="e.g. 2026-000001"
          testID="receipt-number-input"
        />
        <Field
          theme={t}
          label="Amount"
          value={amount}
          onChangeText={setAmount}
          placeholder="0.00"
          keyboardType="numeric"
          testID="receipt-amount-input"
        />
        <Field
          theme={t}
          label="Notes"
          value={notes}
          onChangeText={setNotes}
          placeholder="Anything worth noting"
          testID="receipt-notes-input"
        />
      </Card>

      <Card theme={t} title="Receipt Photo">
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>
            {hasPhoto ? 'Photo attached' : 'No photo attached yet'}
          </Text>
          <StatusBadge
            label={hasPhoto ? 'Attached' : 'Optional'}
            tone={hasPhoto ? 'success' : 'neutral'}
            testID="receipt-photo-state"
          />
        </View>
        <Button
          theme={t}
          variant="secondary"
          label={hasPhoto ? 'Replace Photo' : 'Add Photo'}
          onPress={() => {
            setHasPhoto(true);
            props.onAddPhoto?.();
          }}
          testID="receipt-add-photo"
        />
      </Card>

      <Button
        theme={t}
        label="Save Receipt"
        onPress={() => {
          setSavedMessage('Saved on this phone');
          props.onSave?.({
            category,
            vendor: vendor.trim(),
            receiptNumber: receiptNumber.trim(),
            amount: amount.trim(),
            notes: notes.trim(),
          });
        }}
        testID="receipt-save"
      />
      <FeedbackLine theme={t} message={savedMessage} testID="receipt-save-feedback" />
    </View>
  );
}

/* ----------------------------------------------------- 58. Signature Capture */

const SIGNATURE_TYPES = ['Customer', 'Driver', 'Disposal Site', 'Supervisor', 'Other'] as const;

export function SignatureCaptureScreen(props: {
  signatureType?: string;
  signerName?: string;
  company?: string;
  role?: string;
  dateTime?: string;
  /** True once the driver has drawn something on the pad placeholder. */
  hasSignature?: boolean;
  onClear?: () => void;
  onSave?: (signature: {
    signatureType: string;
    signerName: string;
    company: string;
    role: string;
  }) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [signatureType, setSignatureType] = useState(props.signatureType ?? 'Customer');
  const [signerName, setSignerName] = useState(props.signerName ?? '');
  const [company, setCompany] = useState(props.company ?? '');
  const [role, setRole] = useState(props.role ?? '');
  const [signature, setSignature] = useState<SignatureValue | null>(null);
  const hasSignature = signature !== null;
  const [savedMessage, setSavedMessage] = useState<string | undefined>(undefined);

  return (
    <View style={styles.body} testID="signature-capture">
      <Text style={[styles.h1, { color: t.text }]}>Signature</Text>

      <Card theme={t} title="Signature type">
        <ChipPicker
          theme={t}
          options={SIGNATURE_TYPES}
          selected={signatureType}
          onSelect={setSignatureType}
          idPrefix="signature-type"
        />
      </Card>

      <Card theme={t} title="Signer">
        <Field
          theme={t}
          label="Signer Name"
          value={signerName}
          onChangeText={setSignerName}
          placeholder="Full name"
          testID="signature-name-input"
        />
        <Field
          theme={t}
          label="Company"
          value={company}
          onChangeText={setCompany}
          placeholder="e.g. Acme Energy"
          testID="signature-company-input"
        />
        <Field
          theme={t}
          label="Role"
          value={role}
          onChangeText={setRole}
          placeholder="e.g. Pumper"
          testID="signature-role-input"
        />
      </Card>

      <Card theme={t} title="Signature Pad">
        <SignatureField
          theme={t}
          value={signature}
          onChange={(next) => {
            setSignature(next);
            setSavedMessage(undefined);
            if (next === null) props.onClear?.();
          }}
          testID="signature-pad"
        />
      </Card>

      <View style={styles.rowBetween}>
        <Text style={[styles.meta, { color: t.textMuted }]}>Date / Time</Text>
        <Text style={[styles.metaValue, { color: t.text }]}>
          {props.dateTime ?? 'Today 9:20 AM'}
        </Text>
      </View>

      <Button
        theme={t}
        label="Save Signature"
        disabled={!hasSignature}
        onPress={() => {
          setSavedMessage('Saved on this phone');
          props.onSave?.({
            signatureType,
            signerName: signerName.trim(),
            company: company.trim(),
            role: role.trim(),
          });
        }}
        testID="signature-save"
      />
      <FeedbackLine theme={t} message={savedMessage} testID="signature-feedback" />
    </View>
  );
}

/* ----------------------------------------------------------- 59. GPS Capture */

// Yard Arrival/Departure are intentionally absent: yard events are captured automatically by the
// background geofence, not chosen by the driver (items 4 & 7). Only job/disposal events remain for
// any residual manual classification, and "out"/departure is the final event in the sequence.
const GPS_EVENT_TYPES = [
  'Job Arrival',
  'Disposal Arrival',
  'Disposal Departure',
  'Job Departure',
  'Other',
] as const;

export function GpsCaptureScreen(props: {
  eventType?: string;
  /** Whether the last capture confirmed the driver is in the expected area. */
  verified?: boolean;
  withinArea?: boolean;
  /** Plain accuracy text, e.g. "18 ft". */
  accuracy?: string;
  capturedAt?: string;
  /** Human-readable coordinates, only revealed under "Show Details". */
  coordinates?: string;
  /** Plain area name, e.g. "well-site area". */
  areaName?: string;
  onChangeEventType?: (eventType: string) => void;
  onCapture?: () => void;
  /** Called when the driver could not verify and saves with a written reason. */
  onSaveUnverified?: (reason: string) => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const [eventType, setEventType] = useState(props.eventType ?? 'Job Arrival');
  const [showDetails, setShowDetails] = useState(false);
  const [reason, setReason] = useState('');
  const [verified, setVerified] = useState(props.verified ?? true);
  const [captureMessage, setCaptureMessage] = useState<string | undefined>(undefined);
  const [savedMessage, setSavedMessage] = useState<string | undefined>(undefined);

  const withinArea = props.withinArea ?? true;
  const areaName = props.areaName ?? 'well-site area';

  return (
    <View style={styles.body} testID="gps-capture">
      <Text style={[styles.h1, { color: t.text }]}>Capture Location</Text>
      <Text style={[styles.subtitle, { color: t.textMuted }]}>
        This records where you are for this job. No map reading needed.
      </Text>

      <Card theme={t} title="Event">
        <ChipPicker
          theme={t}
          options={GPS_EVENT_TYPES}
          selected={eventType}
          onSelect={(value) => {
            setEventType(value);
            props.onChangeEventType?.(value);
          }}
          idPrefix="gps-event"
        />
      </Card>

      {verified ? (
        <Card theme={t} tone="highlight" title="GPS Captured" testID="gps-result">
          <View style={styles.rowBetween}>
            <Text style={[styles.body2, { color: t.text }]}>
              {withinArea ? `Within ${areaName}` : `Outside ${areaName}`}
            </Text>
            <StatusBadge
              label={withinArea ? 'Verified' : 'Needs Review'}
              tone={withinArea ? 'success' : 'warning'}
              testID="gps-verify-state"
            />
          </View>
          <Text style={[styles.meta, { color: t.textMuted }]}>
            Accuracy: {props.accuracy ?? '18 ft'}
          </Text>
          <Text style={[styles.meta, { color: t.textMuted }]}>
            Captured {props.capturedAt ?? 'today at 8:47 AM'}
          </Text>
          <Button
            theme={t}
            variant="secondary"
            label={showDetails ? 'Hide Details' : 'Show Details'}
            onPress={() => setShowDetails((open) => !open)}
            testID="gps-show-details"
          />
          {showDetails ? (
            <Text style={[styles.meta, { color: t.textMuted }]} testID="gps-coordinates">
              {props.coordinates ?? '31.8457° N, 102.3676° W'}
            </Text>
          ) : null}
        </Card>
      ) : (
        <Card theme={t} title="Could not verify location" testID="gps-unverified">
          <Text style={[styles.body2, { color: t.text }]}>
            We could not confirm your location for this event. Add a short reason and you can still
            save it.
          </Text>
          <Field
            theme={t}
            label="Reason required"
            value={reason}
            onChangeText={setReason}
            placeholder="Why couldn’t we verify?"
            testID="gps-reason-input"
          />
          <Button
            theme={t}
            label="Save Unverified Location"
            onPress={() => {
              setSavedMessage('Saved on this phone with your reason');
              props.onSaveUnverified?.(reason.trim());
            }}
            disabled={reason.trim() === ''}
            testID="gps-save-unverified"
          />
          <FeedbackLine theme={t} message={savedMessage} testID="gps-unverified-feedback" />
        </Card>
      )}

      <Button
        theme={t}
        label="Capture GPS"
        onPress={() => {
          setVerified(true);
          setCaptureMessage('Location captured');
          props.onCapture?.();
        }}
        testID="gps-capture-btn"
      />
      <FeedbackLine theme={t} message={captureMessage} testID="gps-capture-feedback" />
    </View>
  );
}

/* ---------------------------------------------------------- 60. Print Ticket */

export interface PrintDocument {
  key: string;
  label: string;
}

const DEFAULT_PRINT_DOCS: readonly PrintDocument[] = [
  { key: 'field-ticket', label: 'Field Ticket TKT-10488' },
  { key: 'job-summary', label: 'Job Summary' },
  { key: 'receipt-copy', label: 'Receipt Copy' },
];

export function PrintTicketScreen(props: {
  printerName?: string;
  printerConnected?: boolean;
  documents?: readonly PrintDocument[];
  selectedDocumentKey?: string;
  onSelectDocument?: (key: string) => void;
  onPrintTicket?: () => void;
  onReprintLast?: () => void;
  onPrinterHelp?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const documents = props.documents ?? DEFAULT_PRINT_DOCS;
  const connected = props.printerConnected ?? true;
  const [selected, setSelected] = useState(props.selectedDocumentKey ?? documents[0]?.key ?? '');
  const [printMessage, setPrintMessage] = useState<string | undefined>(undefined);

  return (
    <View style={styles.body} testID="print-ticket">
      <Text style={[styles.h1, { color: t.text }]}>Print</Text>

      <Card theme={t} title="Printer">
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>{props.printerName ?? 'PT-210'}</Text>
          <StatusBadge
            label={connected ? 'Connected' : 'Offline Mode'}
            tone={connected ? 'success' : 'warning'}
            testID="printer-state"
          />
        </View>
      </Card>

      <Card theme={t} title="Documents">
        {documents.map((doc) => {
          const isSelected = doc.key === selected;
          return (
            <Pressable
              key={doc.key}
              testID={`print-doc-${doc.key}`}
              onPress={() => {
                setSelected(doc.key);
                props.onSelectDocument?.(doc.key);
              }}
              accessibilityRole="button"
              accessibilityState={{ selected: isSelected }}
              accessibilityLabel={doc.label}
              style={[
                styles.docRow,
                { borderColor: isSelected ? t.primary : t.border },
                isSelected ? { backgroundColor: t.cardMuted } : null,
              ]}
            >
              <Text style={[styles.docLabel, { color: t.text }]}>{doc.label}</Text>
              {isSelected ? <StatusBadge label="Selected" tone="info" /> : null}
            </Pressable>
          );
        })}
      </Card>

      <Button
        theme={t}
        label="Print Ticket"
        onPress={() => {
          setPrintMessage('Sent to printer');
          props.onPrintTicket?.();
        }}
        disabled={!connected}
        testID="print-ticket-btn"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Reprint Last"
        onPress={() => {
          setPrintMessage('Reprinting last document');
          props.onReprintLast?.();
        }}
        testID="print-reprint"
      />
      <Button
        theme={t}
        variant="secondary"
        label="Printer Help"
        onPress={() => {
          setPrintMessage('Opening printer help');
          props.onPrinterHelp?.();
        }}
        testID="print-help"
      />
      <FeedbackLine theme={t} message={printMessage} testID="print-feedback" />
    </View>
  );
}

/* ------------------------------------------------- 61. Job Complete Review */

export function JobCompleteReviewScreen(props: {
  jobLabel?: string;
  jhaStatus?: EvidenceStatus;
  ticketStatus?: EvidenceStatus;
  evidenceCount?: number;
  pendingSync?: number;
  /** When false, the day is done and End Day is shown instead of Start Next Job. */
  hasMoreJobs?: boolean;
  onStartNextJob?: () => void;
  onEndDay?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const jhaStatus = props.jhaStatus ?? 'Complete';
  const ticketStatus = props.ticketStatus ?? 'Submitted';
  const evidenceCount = props.evidenceCount ?? 4;
  const pendingSync = props.pendingSync ?? 2;
  const hasMoreJobs = props.hasMoreJobs ?? true;

  return (
    <View style={styles.body} testID="job-complete-review">
      <Text style={[styles.h1, { color: t.text }]}>Job Complete</Text>
      <Text style={[styles.subtitle, { color: t.textMuted }]}>
        {props.jobLabel ?? 'Acme Energy · Northfield 114H'}
      </Text>

      <Card theme={t} tone="highlight" title="Summary">
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>JHA/JSA</Text>
          <StatusPill status={jhaStatus} testID="complete-jha-status" />
        </View>
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>Field Ticket</Text>
          <StatusPill status={ticketStatus} testID="complete-ticket-status" />
        </View>
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>Evidence</Text>
          <Text style={[styles.metaValue, { color: t.text }]}>
            {evidenceCount} item{evidenceCount === 1 ? '' : 's'}
          </Text>
        </View>
        <View style={styles.rowBetween}>
          <Text style={[styles.body2, { color: t.text }]}>Sync</Text>
          <StatusBadge
            label={pendingSync === 0 ? 'Synced' : 'Pending Sync'}
            tone={pendingSync === 0 ? 'success' : 'info'}
            testID="complete-sync-status"
          />
        </View>
        {pendingSync > 0 ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>
            {pendingSync} item{pendingSync === 1 ? '' : 's'} waiting to sync. Your work is safe on
            this phone.
          </Text>
        ) : null}
      </Card>

      {hasMoreJobs ? (
        <Button
          theme={t}
          label="Start Next Job"
          onPress={() => props.onStartNextJob?.()}
          testID="complete-start-next"
        />
      ) : (
        <Button
          theme={t}
          label="End Day"
          onPress={() => props.onEndDay?.()}
          testID="complete-end-day"
        />
      )}
    </View>
  );
}

/* ---------------------------------------------------------------- styles */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
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
  metaValue: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  rowBetween: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: spacing.sm,
  },
  menu: {
    gap: spacing.sm,
  },
  frame: {
    borderWidth: 1,
    borderStyle: 'dashed',
    borderRadius: sizing.radius,
    minHeight: 200,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.lg,
    gap: spacing.xs,
  },
  framePressed: {
    opacity: 0.85,
  },
  frameLabel: {
    fontSize: typeScale.heading,
    fontWeight: '700',
  },
  frameHint: {
    fontSize: typeScale.label,
    textAlign: 'center',
  },
  chipRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  chip: {
    borderWidth: 1,
    borderRadius: 16,
    paddingHorizontal: 12,
    paddingVertical: 8,
    minHeight: 40,
    justifyContent: 'center',
  },
  chipText: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  field: {
    gap: spacing.xs,
  },
  fieldLabel: {
    fontSize: typeScale.label,
    fontWeight: '600',
  },
  input: {
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    minHeight: 48,
    fontSize: typeScale.body,
  },
  docRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderWidth: 1,
    borderRadius: sizing.radius,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    minHeight: 48,
  },
  docLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
});
