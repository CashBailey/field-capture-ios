/**
 * StatusBadge (spec 8.6): a status pill that is legible WITHOUT color — it always shows a text
 * label plus a leading symbol, with color only reinforcing. Dep-free: the leading glyph stands in
 * for a future native line icon; swapping the
 * glyph for an `<Icon>` won't change the contract. Never render status as color-alone.
 */
import { StyleSheet, Text, View } from 'react-native';

import { palette, sizing, toneColor, typeScale, type Tone } from './theme';

/** Tone → a dep-free leading glyph. Replaced by a line icon on-device; the label carries meaning. */
const TONE_GLYPH: Record<Tone, string> = {
  neutral: '•',
  info: 'i',
  success: '✓',
  warning: '!',
  danger: '✕',
};

export function StatusBadge(props: { label: string; tone?: Tone; testID?: string }) {
  const tone = props.tone ?? 'neutral';
  const color = toneColor[tone];
  return (
    <View
      style={[styles.badge, { borderColor: color }]}
      testID={props.testID}
      accessibilityRole="text"
      accessibilityLabel={`${tone}: ${props.label}`}
    >
      <Text style={[styles.glyph, { color }]} accessibilityElementsHidden>
        {TONE_GLYPH[tone]}
      </Text>
      <Text style={[styles.label, { color }]}>{props.label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    alignSelf: 'flex-start',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: sizing.pillRadius,
    borderWidth: 1,
    backgroundColor: palette.surface,
  },
  glyph: {
    fontSize: typeScale.caption,
    fontWeight: '700',
  },
  label: {
    fontSize: typeScale.caption,
    fontWeight: '700',
  },
});
