/**
 * Design tokens — pure constants, no React. The single source of truth for color/spacing/type so
 * screens stop hard-coding hex. Field-readability first: large type, high contrast. Color is ALWAYS
 * paired with a text/symbol signal elsewhere (see StatusBadge) — never color-alone.
 *
 * The palette follows the Acme Oilfield Services brand (GUI Master §21): forest green +
 * brighter field green, light sky blue (info), saddle brown / amber (caution), cream surface
 * highlight, charcoal text, on a warm light-gray background. `brandGreen` stays #1F6F3A (the
 * established brand primary); the rest are added alongside it.
 */

/** Brand + semantic palette (GUI Master §21 / logo color scheme). */
export const palette = {
  // Greens
  brandGreen: '#1F6F3A', // brand primary (light mode)
  forestGreen: '#16532B', // darker forest green — header fills, pressed states
  brandGreenBright: '#34A853', // brighter field green — dark-mode primary, success highlight
  // Accents from the logo
  skyBlue: '#7DC2E8', // light sky-blue info accent (logo inner circle)
  infoBlue: '#2563EB', // saturated info (kept for the existing 'info' tone)
  saddleBrown: '#8B5A2B', // caution accent (cowboy-hat brown)
  safetyAmber: '#F59E0B', // warning
  errorRed: '#B42318', // destructive / failed
  cream: '#F5EFE3', // surface highlight (logo belly cream)
  fieldSand: '#F5EFE3', // alias kept for existing callers
  // Neutrals
  ink: '#17202A', // charcoal text
  inkMuted: '#55616D',
  warmGray: '#F2F1EC', // warm light-gray app background (light mode)
  surface: '#FFFFFF',
  surfaceMuted: '#FBFCFD',
  border: '#D7DDE2',
  onColor: '#FFFFFF',
  successText: '#1B5E20',
  // Dark mode neutrals
  charcoal: '#15191C', // dark background
  charcoalCard: '#1F262B', // elevated dark card
  darkBorder: '#33403A',
  lightText: '#F4F6F5',
} as const;

/** Semantic theme roles. Components read these so a light/dark swap is one object. */
export interface Theme {
  mode: 'light' | 'dark';
  background: string;
  card: string;
  cardMuted: string;
  primary: string;
  primaryDark: string;
  onPrimary: string;
  text: string;
  textMuted: string;
  border: string;
  info: string;
  success: string;
  warning: string;
  danger: string;
  highlight: string;
}

export const lightTheme: Theme = {
  mode: 'light',
  background: palette.warmGray,
  card: palette.surface,
  cardMuted: palette.surfaceMuted,
  primary: palette.brandGreen,
  primaryDark: palette.forestGreen,
  onPrimary: palette.onColor,
  text: palette.ink,
  textMuted: palette.inkMuted,
  border: palette.border,
  info: palette.skyBlue,
  success: palette.brandGreen,
  warning: palette.saddleBrown,
  danger: palette.errorRed,
  highlight: palette.cream,
};

export const darkTheme: Theme = {
  mode: 'dark',
  background: palette.charcoal,
  card: palette.charcoalCard,
  cardMuted: '#262E33',
  primary: palette.brandGreenBright,
  primaryDark: palette.brandGreen,
  onPrimary: '#0B1A10',
  text: palette.lightText,
  textMuted: '#9AA7A0',
  border: palette.darkBorder,
  info: palette.skyBlue,
  success: palette.brandGreenBright,
  warning: palette.safetyAmber,
  danger: '#F2675A',
  highlight: '#1E3A2A',
};

/** Default theme. A user theme toggle (GUI Master screen 78) swaps this later. */
export const theme: Theme = lightTheme;

/** Type scale — title 26–30, body 16–18 (the field-readable floor). */
export const typeScale = {
  title: 28,
  heading: 20,
  body: 17,
  label: 15,
  caption: 13,
} as const;

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
} as const;

/** Full-width field action buttons 56–64px tall; 48×48 minimum touch target. */
export const sizing = {
  actionButtonHeight: 56,
  minTouchTarget: 48,
  radius: 8,
  cardRadius: 14,
  pillRadius: 14,
} as const;

/** Semantic tone → color, used by badges/messages. Tone is reinforced by text, never color-alone. */
export type Tone = 'neutral' | 'info' | 'success' | 'warning' | 'danger';

export const toneColor: Record<Tone, string> = {
  neutral: palette.inkMuted,
  info: palette.infoBlue,
  success: palette.brandGreen,
  warning: palette.safetyAmber,
  danger: palette.errorRed,
};
