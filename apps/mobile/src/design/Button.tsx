/**
 * Button (GUI Master §21): primary = filled forest/field green, secondary = outlined/light fill,
 * destructive = red (always paired with a confirm modal by the caller). Full-width by default for a
 * screen's main next action; large touch target for gloved field use.
 */
import { Pressable, StyleSheet, Text } from 'react-native';

import { sizing, typeScale, type Theme } from './theme';
import { useResolvedTheme } from './ThemeContext';

export type ButtonVariant = 'primary' | 'secondary' | 'destructive';

export function Button(props: {
  label: string;
  onPress: () => void | Promise<void>;
  variant?: ButtonVariant;
  fullWidth?: boolean;
  disabled?: boolean;
  testID?: string;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const variant = props.variant ?? 'primary';
  const disabled = props.disabled ?? false;

  const bg =
    variant === 'primary' ? t.primary : variant === 'destructive' ? t.danger : 'transparent';
  const borderColor =
    variant === 'secondary' ? t.border : variant === 'destructive' ? t.danger : bg;
  const textColor =
    variant === 'primary' ? t.onPrimary : variant === 'destructive' ? t.danger : t.text;

  return (
    <Pressable
      testID={props.testID}
      onPress={() => void props.onPress()}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      accessibilityLabel={props.label}
      style={({ pressed }) => [
        styles.base,
        {
          backgroundColor: variant === 'destructive' ? 'transparent' : bg,
          borderColor,
        },
        props.fullWidth !== false ? styles.fullWidth : styles.auto,
        pressed && !disabled ? styles.pressed : null,
        disabled ? styles.disabled : null,
      ]}
    >
      <Text style={[styles.label, { color: textColor }]} numberOfLines={1}>
        {props.label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    minHeight: sizing.actionButtonHeight,
    borderRadius: sizing.radius,
    borderWidth: 1,
    paddingHorizontal: 18,
    alignItems: 'center',
    justifyContent: 'center',
  },
  fullWidth: {
    alignSelf: 'stretch',
  },
  auto: {
    alignSelf: 'flex-start',
  },
  pressed: {
    opacity: 0.85,
  },
  disabled: {
    opacity: 0.45,
  },
  label: {
    fontSize: typeScale.body,
    fontWeight: '700',
  },
});
