/**
 * Design tokens + StatusBadge (workstream b / spec 8.2, 8.3, 8.6). The badge must be legible
 * WITHOUT color — a text label + symbol always present — so this pins that contract.
 */
import { palette, sizing, StatusBadge, toneColor, typeScale } from '../src/design';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

function textOf(renderer: import('react-test-renderer').ReactTestRenderer): string {
  return JSON.stringify(renderer.toJSON());
}

describe('design tokens', () => {
  it('uses Field Green (not the old teal) and the spec palette', () => {
    expect(palette.brandGreen).toBe('#1F6F3A');
    expect(palette.safetyAmber).toBe('#F59E0B');
    expect(palette.errorRed).toBe('#B42318');
    expect(palette.infoBlue).toBe('#2563EB');
    // The pre-design-system teal must not be the brand color.
    expect(Object.values(palette)).not.toContain('#1f6f8b');
  });

  it('meets the field-readable type scale + touch-target floors', () => {
    expect(typeScale.title).toBeGreaterThanOrEqual(26);
    expect(typeScale.body).toBeGreaterThanOrEqual(16);
    expect(sizing.actionButtonHeight).toBeGreaterThanOrEqual(56);
    expect(sizing.minTouchTarget).toBeGreaterThanOrEqual(48);
  });

  it('maps each tone to a distinct reinforcing color', () => {
    expect(toneColor.danger).toBe(palette.errorRed);
    expect(toneColor.success).toBe(palette.brandGreen);
    expect(new Set(Object.values(toneColor)).size).toBe(Object.keys(toneColor).length);
  });
});

describe('StatusBadge (never color-alone)', () => {
  it('renders the label text plus a leading symbol', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<StatusBadge label="on_hold" tone="warning" testID="b" />);
    });
    const text = textOf(renderer!);
    expect(text).toContain('on_hold'); // the label carries meaning without color
    expect(text).toContain('!'); // the warning symbol reinforces it
  });

  // testID is on both the StatusBadge composite and its host View; pick the host (the one that
  // actually carries accessibilityLabel).
  const a11yLabel = (
    renderer: import('react-test-renderer').ReactTestRenderer,
  ): string | undefined =>
    renderer.root
      .findAllByProps({ testID: 'b' })
      .map((n) => n.props.accessibilityLabel)
      .find((label): label is string => typeof label === 'string');

  it('exposes an accessibility label combining tone and text', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<StatusBadge label="rejected" tone="danger" testID="b" />);
    });
    expect(a11yLabel(renderer!)).toBe('danger: rejected');
  });

  it('defaults to a neutral tone', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<StatusBadge label="assigned" testID="b" />);
    });
    expect(a11yLabel(renderer!)).toBe('neutral: assigned');
  });
});
