/**
 * App header (GUI Master §3): a compact branded bar — "Field Capture" with the small circular logo —
 * plus an optional thin status strip of chips (Punched In, Offline Mode, N Pending Sync, Truck 7).
 * Show ONLY the chips that matter. Never put env labels, hub URLs, or backend strings here.
 */
import { StyleSheet, Text, View } from 'react-native';

import { Logo } from './Logo';
import { useResolvedTheme } from './ThemeContext';
import { sizing, spacing, typeScale, toneColor, type Theme, type Tone } from './theme';

export interface HeaderChip {
  label: string;
  tone?: Tone;
}

function Chip({ chip, theme }: { chip: HeaderChip; theme: Theme }) {
  const color = toneColor[chip.tone ?? 'neutral'];
  return (
    <View style={[styles.chip, { borderColor: color, backgroundColor: theme.card }]}>
      <Text style={[styles.chipText, { color }]} numberOfLines={1}>
        {chip.label}
      </Text>
    </View>
  );
}

export function AppHeader(props: {
  title?: string;
  subtitle?: string;
  chips?: readonly HeaderChip[];
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const chips = props.chips ?? [];
  return (
    <View style={[styles.header, { backgroundColor: t.card, borderBottomColor: t.border }]}>
      <View style={styles.brandRow}>
        <Logo size={36} ring testID="app-logo" />
        <View style={styles.titleCol}>
          <Text style={[styles.title, { color: t.text }]}>{props.title ?? 'Field Capture'}</Text>
          {props.subtitle !== undefined ? (
            <Text style={[styles.subtitle, { color: t.textMuted }]}>{props.subtitle}</Text>
          ) : null}
        </View>
      </View>
      {chips.length > 0 ? (
        <View style={styles.strip} testID="status-strip">
          {chips.map((chip) => (
            <Chip key={chip.label} chip={chip} theme={t} />
          ))}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.sm,
    gap: spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  brandRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
  },
  titleCol: {
    flex: 1,
  },
  title: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  subtitle: {
    fontSize: typeScale.caption,
  },
  strip: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  chip: {
    borderWidth: 1,
    borderRadius: sizing.pillRadius,
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
  },
  chipText: {
    fontSize: typeScale.caption,
    fontWeight: '700',
  },
});
