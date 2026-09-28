/**
 * Card (GUI Master §21): rounded surface for workday status, next action, job summary, inspection
 * sections, SOPs, sync items, evidence. Optional title + a 'highlight' tone (cream surface) to mark
 * the single most-important card on a screen (e.g. Next Required Step).
 */
import { type ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { sizing, spacing, typeScale, type Theme } from './theme';
import { useResolvedTheme } from './ThemeContext';

export function Card(props: {
  title?: string;
  children?: ReactNode;
  tone?: 'default' | 'highlight';
  testID?: string;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const highlight = props.tone === 'highlight';
  return (
    <View
      testID={props.testID}
      style={[
        styles.card,
        {
          backgroundColor: highlight ? t.highlight : t.card,
          borderColor: t.border,
        },
      ]}
    >
      {props.title !== undefined ? (
        <Text style={[styles.title, { color: t.text }]}>{props.title}</Text>
      ) : null}
      {props.children}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: sizing.cardRadius,
    borderWidth: StyleSheet.hairlineWidth,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  title: {
    fontSize: typeScale.heading,
    fontWeight: '700',
  },
});
