/**
 * T3: theme selection is real. Choosing Dark under More → Theme flips the app-wide ThemeContext, so
 * any consumer re-renders with the dark palette. And the Language row is hidden until i18n ships
 * (no control that does nothing).
 */
import { Text } from 'react-native';

import { ThemeProvider, useTheme } from '../src/design';
import { AccountScreen, MoreHomeScreen, ThemeScreen } from '../src/screens/MoreScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

function ModeProbe() {
  const t = useTheme();
  return <Text testID="mode">{t.mode}</Text>;
}

function tap(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  const nodes = r.root.findAllByProps({ testID });
  const node = nodes.find((n) => typeof n.props.onPress === 'function') ?? nodes[0];
  act(() => node.props.onPress());
}
function has(r: import('react-test-renderer').ReactTestRenderer, testID: string): boolean {
  return r.root.findAllByProps({ testID }).length > 0;
}

describe('ThemeContext', () => {
  it('selecting Dark re-themes the whole app', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(
        <ThemeProvider>
          <ModeProbe />
          <ThemeScreen />
        </ThemeProvider>,
      );
    });
    expect(r!.root.findByProps({ testID: 'mode' }).props.children).toBe('light');
    tap(r!, 'theme-dark');
    expect(r!.root.findByProps({ testID: 'mode' }).props.children).toBe('dark');
    tap(r!, 'theme-light');
    expect(r!.root.findByProps({ testID: 'mode' }).props.children).toBe('light');
  });
});

describe('MoreHomeScreen language visibility', () => {
  const baseProps = {
    onOpenAccount: () => undefined,
    onOpenTheme: () => undefined,
    onOpenTextSize: () => undefined,
    onOpenPrinter: () => undefined,
    onOpenHelp: () => undefined,
    onOpenContactDispatch: () => undefined,
    onOpenAdminMode: () => undefined,
    onSignOut: () => undefined,
  };
  it('hides the Language row when no handler is supplied', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(<MoreHomeScreen {...baseProps} />);
    });
    expect(has(r!, 'more-language')).toBe(false);
    expect(has(r!, 'more-theme')).toBe(true);
  });

  it('uses honest profile fallbacks instead of demo driver data', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(<MoreHomeScreen {...baseProps} />);
    });
    expect(r!.root.findAllByProps({ children: 'Alex Ramirez' })).toHaveLength(0);
    expect(r!.root.findAllByProps({ children: 'Signed-in driver' }).length).toBeGreaterThan(0);
  });

  it('renders the Hub-provided driver summary when present', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(
        <MoreHomeScreen
          {...baseProps}
          driverName="Alex Rivera"
          driverRole="Driver"
          company="Operations"
        />,
      );
    });
    expect(r!.root.findAllByProps({ children: 'Alex Rivera' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'Driver' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'Operations' }).length).toBeGreaterThan(0);
  });
});

describe('AccountScreen profile values', () => {
  it('uses missing-value fallbacks instead of static demo account details', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(<AccountScreen />);
    });
    expect(r!.root.findAllByProps({ children: 'Alex Ramirez' })).toHaveLength(0);
    expect(r!.root.findAllByProps({ children: 'GV-0481' })).toHaveLength(0);
    expect(r!.root.findAllByProps({ children: 'Not provided by Hub' }).length).toBeGreaterThan(0);
  });

  it('renders Hub-provided account fields when present', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(
        <AccountScreen
          name="Cash Bailey"
          role="Developer"
          employeeId="emp-1"
          phone="(432) 555-0101"
          assignedYard="Midland Yard"
          defaultTruck="Truck 7"
          defaultTrailer="Vacuum Trailer 19"
        />,
      );
    });
    expect(r!.root.findAllByProps({ children: 'Cash Bailey' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'emp-1' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: '(432) 555-0101' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'Midland Yard' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'Truck 7' }).length).toBeGreaterThan(0);
    expect(r!.root.findAllByProps({ children: 'Vacuum Trailer 19' }).length).toBeGreaterThan(0);
  });
});
