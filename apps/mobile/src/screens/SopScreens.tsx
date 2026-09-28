/**
 * SOP Library (GUI Master §13 / §22) — role-based SOP access with filter chips. This is the
 * scaffold: the filters and the offline-first empty state are real; SOP content syncs from the Hub
 * as that slice lands (no fake SOPs are shown). Emergency SOPs are always reachable from here.
 */
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Card, spacing, typeScale, useResolvedTheme, type Theme } from '../design';

export type SopFilter =
  | 'all'
  | 'required'
  | 'job'
  | 'emergency'
  | 'ack-needed'
  | 'offline'
  | 'recent';

const SOP_FILTERS: readonly { key: SopFilter; label: string }[] = [
  { key: 'all', label: 'All SOPs' },
  { key: 'required', label: 'Required for Driver' },
  { key: 'job', label: 'Job SOPs' },
  { key: 'emergency', label: 'Emergency SOPs' },
  { key: 'ack-needed', label: 'Acknowledgement Needed' },
  { key: 'offline', label: 'Available Offline' },
  { key: 'recent', label: 'Recently Updated' },
];

export function SopLibraryScreen(props: { theme?: Theme }) {
  const t = useResolvedTheme(props.theme);
  const [filter, setFilter] = useState<SopFilter>('all');
  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>SOPs</Text>
      <View style={styles.filters}>
        {SOP_FILTERS.map((f) => {
          const selected = f.key === filter;
          return (
            <Pressable
              key={f.key}
              testID={`sop-filter-${f.key}`}
              onPress={() => setFilter(f.key)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              style={[
                styles.chip,
                { borderColor: selected ? t.primary : t.border },
                selected ? { backgroundColor: t.primary } : null,
              ]}
            >
              <Text style={[styles.chipText, { color: selected ? t.onPrimary : t.textMuted }]}>
                {f.label}
              </Text>
            </Pressable>
          );
        })}
      </View>
      <Card theme={t} title="Procedures for your role">
        <Text style={[styles.body2, { color: t.textMuted }]}>
          Standard operating procedures sync to this phone so they are available in the field — even
          offline. None are downloaded yet; they will appear here once your role’s SOPs sync from
          Ops Hub.
        </Text>
      </Card>
      <Card theme={t} tone="highlight" title="Emergency information">
        <Text style={[styles.body2, { color: t.text }]}>
          In an emergency, stop work and make the area safe first. Emergency contacts and procedures
          are reachable from the Day screen, every job, and Help.
        </Text>
      </Card>
    </View>
  );
}

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  filters: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xs,
  },
  chip: {
    borderWidth: 1,
    borderRadius: 16,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  chipText: {
    fontSize: typeScale.caption,
    fontWeight: '600',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 24,
  },
});
