/**
 * SignaturePad — the one finger-drawable signature surface, reused by Pre-Trip, Post-Trip, JHA, and
 * Evidence. Tapping the inline pad opens a full-screen LANDSCAPE modal (rotated 90° rather than a
 * native orientation lock) with a real
 * PanResponder canvas: the driver signs with their finger, edge to edge, then Done / Clear / Cancel.
 *
 * Dependency-free by design — no SVG, no gesture-handler, no native modules (all of which would
 * force a native rebuild). Ink is the dense dot-cloud from {@link inkDots}; the captured signature is
 * the serialized vector from {@link serializeSignature}, which the host persists as the artifact.
 */
import { useState } from 'react';
import {
  Modal,
  PanResponder,
  Pressable,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
  type LayoutChangeEvent,
} from 'react-native';

import { Button } from './Button';
import {
  deserializeSignature,
  inkDots,
  isEmpty,
  serializeSignature,
  type SigPoint,
  type SigStroke,
} from './signatureModel';
import { useResolvedTheme } from './ThemeContext';
import { sizing, spacing, typeScale, type Theme } from './theme';

/** The captured signature: the serialized vector, or null when unsigned. */
export type SignatureValue = string;

/** Renders a stroke set as a dot cloud, optionally scaled to fit a measured box (for previews). */
function Ink(props: {
  strokes: readonly SigStroke[];
  color: string;
  dotSize?: number;
  fit?: boolean;
}) {
  const [box, setBox] = useState<{ w: number; h: number }>({ w: 0, h: 0 });
  const dots = inkDots(props.strokes);
  const size = props.dotSize ?? 2.6;

  let scale = 1;
  let ox = 0;
  let oy = 0;
  if (props.fit && dots.length > 0 && box.w > 0 && box.h > 0) {
    const xs = dots.map((d) => d.x);
    const ys = dots.map((d) => d.y);
    const minX = Math.min(...xs);
    const minY = Math.min(...ys);
    const w = Math.max(1, Math.max(...xs) - minX);
    const h = Math.max(1, Math.max(...ys) - minY);
    const pad = 8;
    scale = Math.min((box.w - pad * 2) / w, (box.h - pad * 2) / h, 1);
    ox = pad - minX * scale;
    oy = pad - minY * scale;
  }

  const onLayout = (e: LayoutChangeEvent) =>
    setBox({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height });

  return (
    <View style={StyleSheet.absoluteFill} onLayout={onLayout} pointerEvents="none">
      {dots.map((d: SigPoint, i: number) => (
        <View
          key={i}
          style={{
            position: 'absolute',
            left: d.x * scale + ox - size / 2,
            top: d.y * scale + oy - size / 2,
            width: size,
            height: size,
            borderRadius: size / 2,
            backgroundColor: props.color,
          }}
        />
      ))}
    </View>
  );
}

/** Full-screen landscape drawing modal. Owns the in-progress strokes; reports them on Done. */
function SignatureModal(props: {
  visible: boolean;
  theme: Theme;
  initial: readonly SigStroke[];
  onDone: (strokes: SigStroke[]) => void;
  onCancel: () => void;
  testID?: string;
}) {
  const t = props.theme;
  const { width, height } = useWindowDimensions();
  const [strokes, setStrokes] = useState<SigStroke[]>(() => props.initial.map((s) => s.slice()));

  // Rebuild the canvas state each time the modal opens so a re-sign starts from the prior ink.
  const [openedWith, setOpenedWith] = useState(props.initial);
  if (props.visible && openedWith !== props.initial) {
    setOpenedWith(props.initial);
    setStrokes(props.initial.map((s) => s.slice()));
  }

  const pan = PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => {
      const { locationX, locationY } = e.nativeEvent;
      setStrokes((prev) => [...prev, [{ x: locationX, y: locationY }]]);
    },
    onPanResponderMove: (e) => {
      const { locationX, locationY } = e.nativeEvent;
      setStrokes((prev) => {
        if (prev.length === 0) return [[{ x: locationX, y: locationY }]];
        const next = prev.map((s) => s.slice());
        next[next.length - 1].push({ x: locationX, y: locationY });
        return next;
      });
    },
  });

  // Landscape: a container sized to the swapped dimensions, rotated 90°, centered over the screen.
  const land = {
    position: 'absolute' as const,
    width: height,
    height: width,
    top: (height - width) / 2,
    left: (width - height) / 2,
    transform: [{ rotate: '90deg' }],
  };

  return (
    <Modal
      visible={props.visible}
      animationType="slide"
      onRequestClose={props.onCancel}
      testID={props.testID}
    >
      <View style={[styles.modalRoot, { backgroundColor: t.background }]}>
        <View style={land}>
          <View style={styles.modalHeader}>
            <Text style={[styles.modalTitle, { color: t.text }]}>Sign below</Text>
            <Text style={[styles.modalHint, { color: t.textMuted }]}>
              Turn the phone sideways and sign with your finger.
            </Text>
          </View>
          <View
            testID={props.testID !== undefined ? `${props.testID}-canvas` : undefined}
            style={[styles.canvas, { borderColor: t.border, backgroundColor: t.card }]}
            {...pan.panHandlers}
          >
            <Ink strokes={strokes} color={t.text} />
            <View style={styles.baseline} />
          </View>
          <View style={styles.modalActions}>
            <Button
              theme={t}
              variant="secondary"
              fullWidth={false}
              label="Cancel"
              onPress={props.onCancel}
              testID={props.testID !== undefined ? `${props.testID}-cancel` : undefined}
            />
            <Button
              theme={t}
              variant="secondary"
              fullWidth={false}
              label="Clear"
              onPress={() => setStrokes([])}
              testID={props.testID !== undefined ? `${props.testID}-clear` : undefined}
            />
            <Button
              theme={t}
              fullWidth={false}
              label="Done"
              onPress={() => props.onDone(strokes)}
              disabled={isEmpty(strokes)}
              testID={props.testID !== undefined ? `${props.testID}-done` : undefined}
            />
          </View>
        </View>
      </View>
    </Modal>
  );
}

/**
 * Inline signature field: a preview box + Sign / Clear, opening the landscape modal. Drop-in for the
 * old placeholder pads. `value` is the serialized signature (or null); `onChange(null)` clears it.
 */
export function SignatureField(props: {
  theme?: Theme;
  value?: SignatureValue | null;
  onChange: (next: SignatureValue | null) => void;
  testID?: string;
}) {
  const t = useResolvedTheme(props.theme);
  const testID = props.testID ?? 'signature';
  const [open, setOpen] = useState(false);

  const strokes = props.value != null ? deserializeSignature(props.value) : [];
  const captured = !isEmpty(strokes);

  return (
    <View style={styles.fieldWrap}>
      <Pressable
        testID={`${testID}-pad`}
        accessibilityRole="button"
        accessibilityLabel={captured ? 'Signature captured — tap to re-sign' : 'Tap to sign'}
        onPress={() => setOpen(true)}
        style={[
          styles.padBox,
          { borderColor: captured ? t.primary : t.border, backgroundColor: t.cardMuted },
        ]}
      >
        {captured ? (
          <Ink strokes={strokes} color={t.text} fit />
        ) : (
          <Text style={[styles.padHint, { color: t.textMuted }]}>Tap to sign</Text>
        )}
      </Pressable>
      <View style={styles.fieldRow}>
        <Button
          theme={t}
          variant="secondary"
          fullWidth={false}
          label={captured ? 'Re-sign' : 'Sign'}
          onPress={() => setOpen(true)}
          testID={`${testID}-capture`}
        />
        <Button
          theme={t}
          variant="secondary"
          fullWidth={false}
          label="Clear"
          onPress={() => props.onChange(null)}
          disabled={!captured}
          testID={`${testID}-clear`}
        />
      </View>
      <SignatureModal
        visible={open}
        theme={t}
        initial={strokes}
        onCancel={() => setOpen(false)}
        onDone={(next) => {
          setOpen(false);
          props.onChange(isEmpty(next) ? null : serializeSignature(next));
        }}
        testID={`${testID}-modal`}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  fieldWrap: { gap: spacing.sm },
  padBox: {
    minHeight: 140,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderRadius: sizing.radius,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  padHint: { fontSize: typeScale.body, fontWeight: '600' },
  fieldRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  modalRoot: { flex: 1 },
  modalHeader: { paddingHorizontal: spacing.lg, paddingTop: spacing.md, gap: spacing.xs },
  modalTitle: { fontSize: typeScale.heading, fontWeight: '800' },
  modalHint: { fontSize: typeScale.label },
  canvas: {
    flex: 1,
    margin: spacing.lg,
    borderWidth: 1,
    borderRadius: sizing.radius,
    overflow: 'hidden',
  },
  baseline: {
    position: 'absolute',
    left: spacing.xl,
    right: spacing.xl,
    bottom: '28%',
    height: 1,
    backgroundColor: '#9AA7A0',
    opacity: 0.5,
  },
  modalActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.sm,
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.lg,
  },
});
