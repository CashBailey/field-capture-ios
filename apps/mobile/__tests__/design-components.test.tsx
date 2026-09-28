/**
 * Field-brand component kit (GUI Master §3, §21): Button, Card, AppHeader. Pins the driver-facing
 * contract — buttons fire and carry their label, cards title their content, and the header shows
 * the brand plus only the status chips it was given (never backend strings).
 */
import { AppHeader, Button, Card } from '../src/design';
import { Text } from 'react-native';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

function textOf(renderer: import('react-test-renderer').ReactTestRenderer): string {
  return JSON.stringify(renderer.toJSON());
}

describe('Button', () => {
  it('renders its label and fires onPress', () => {
    const onPress = jest.fn();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <Button label="Start Pre-Trip" onPress={onPress} testID="b" />,
      );
    });
    expect(textOf(renderer!)).toContain('Start Pre-Trip');
    act(() => {
      renderer!.root.findByProps({ testID: 'b' }).props.onPress();
    });
    expect(onPress).toHaveBeenCalledTimes(1);
  });

  it('does not fire when disabled', () => {
    const onPress = jest.fn();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <Button label="Punch Out" onPress={onPress} disabled testID="b" />,
      );
    });
    expect(renderer!.root.findByProps({ testID: 'b' }).props.disabled).toBe(true);
    expect(onPress).not.toHaveBeenCalled();
  });
});

describe('Card', () => {
  it('renders its title and children', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <Card title="Next Required Step">
          <Text>Complete Driver Pre-Trip Inspection</Text>
        </Card>,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('Next Required Step');
    expect(text).toContain('Complete Driver Pre-Trip Inspection');
  });
});

describe('AppHeader (driver-facing chrome only)', () => {
  it('shows the brand and only the chips it was given', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <AppHeader chips={[{ label: 'Punched In', tone: 'success' }]} />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('Field Capture');
    expect(text).toContain('Punched In');
    // Never leak backend identifiers into the header.
    expect(text).not.toContain('hub');
    expect(text).not.toContain('snapshot');
  });
});
