/**
 * App-wide theme context — makes the light/dark choice real and reactive. Screens read the resolved
 * Theme from here (via `useResolvedTheme(props.theme)`) instead of the static `theme` import, so a
 * change under More → Theme re-renders the whole app. The choice persists across launches in the
 * device keystore, and "System" follows the OS appearance live.
 */
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { Appearance } from 'react-native';
import * as Keychain from 'react-native-keychain';

import { darkTheme, lightTheme, type Theme } from './theme';

export type ThemeChoice = 'system' | 'light' | 'dark';

const STORE_KEY = 'field.themeChoice';

const ThemeContext = createContext<Theme>(lightTheme);
const ThemeChoiceContext = createContext<{
  choice: ThemeChoice;
  setChoice: (choice: ThemeChoice) => void;
}>({ choice: 'system', setChoice: () => undefined });

/** The resolved theme to render with (default light when no provider is mounted, e.g. in tests). */
export function useTheme(): Theme {
  return useContext(ThemeContext);
}

/** Prefer an explicit `theme` prop, else fall back to the app-wide resolved theme. */
export function useResolvedTheme(override?: Theme): Theme {
  const ctx = useContext(ThemeContext);
  return override ?? ctx;
}

/** The current choice + setter — for the More → Theme settings screen. */
export function useThemeChoice(): {
  choice: ThemeChoice;
  setChoice: (choice: ThemeChoice) => void;
} {
  return useContext(ThemeChoiceContext);
}

/** Appearance can report 'unspecified'/null — treat anything not explicitly dark as light. */
function normalizeScheme(scheme: unknown): 'light' | 'dark' {
  return scheme === 'dark' ? 'dark' : 'light';
}

function resolve(choice: ThemeChoice, system: 'light' | 'dark'): Theme {
  if (choice === 'dark') return darkTheme;
  if (choice === 'light') return lightTheme;
  return system === 'dark' ? darkTheme : lightTheme;
}

export function ThemeProvider(props: { children: ReactNode }) {
  const [choice, setChoiceState] = useState<ThemeChoice>('system');
  const [system, setSystem] = useState<'light' | 'dark'>(
    normalizeScheme(Appearance.getColorScheme()),
  );

  useEffect(() => {
    let alive = true;
    void Keychain.getGenericPassword({ service: STORE_KEY }).then((credentials) => {
      const stored = credentials === false ? null : credentials.password;
      if (alive && (stored === 'system' || stored === 'light' || stored === 'dark')) {
        setChoiceState(stored);
      }
    });
    const sub = Appearance.addChangeListener(({ colorScheme }) =>
      setSystem(normalizeScheme(colorScheme)),
    );
    return () => {
      alive = false;
      sub.remove();
    };
  }, []);

  const setChoice = (next: ThemeChoice) => {
    setChoiceState(next);
    void Keychain.setGenericPassword('fieldcapture', next, {
      service: STORE_KEY,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    }).catch(() => undefined);
  };

  const resolved = resolve(choice, system);

  return (
    <ThemeChoiceContext.Provider value={{ choice, setChoice }}>
      <ThemeContext.Provider value={resolved}>{props.children}</ThemeContext.Provider>
    </ThemeChoiceContext.Provider>
  );
}
