/**
 * JHA/JSA fixes: stop-work authority belongs to ANYONE on site (+ tailgate-meeting rule), the PPE
 * "Other" tile reveals a fill-in field, and the signatures step pre-fills the driver, drops the
 * forced Supervisor/Customer rows, and lets the driver add people (incl. Owner) who are present.
 */
import { JhaPpeScreen, JhaSignaturesScreen, JhaStopWorkScreen } from '../src/screens/JhaScreens';
import { serializeSignature } from '../src/design';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const SIGNED = serializeSignature([
  [
    { x: 0, y: 0 },
    { x: 24, y: 8 },
  ],
]);

function render(node: React.ReactElement) {
  let r: import('react-test-renderer').ReactTestRenderer;
  act(() => {
    r = TestRenderer.create(node);
  });
  return r!;
}
function tap(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  const nodes = r.root.findAllByProps({ testID });
  const node = nodes.find((n) => typeof n.props.onPress === 'function') ?? nodes[0];
  act(() => node.props.onPress());
}
function changeText(
  r: import('react-test-renderer').ReactTestRenderer,
  testID: string,
  value: string,
) {
  act(() => r.root.findByProps({ testID }).props.onChangeText(value));
}
function sign(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  const nodes = r.root.findAllByProps({ testID });
  const node = nodes.find((n) => typeof n.props.onChange === 'function') ?? nodes[0];
  act(() => node.props.onChange(SIGNED));
}
function flatText(json: unknown): string {
  if (json === null || json === undefined) return '';
  if (typeof json === 'string' || typeof json === 'number') return String(json);
  if (Array.isArray(json)) return json.map(flatText).join('');
  return flatText((json as { children?: unknown }).children);
}
function has(r: import('react-test-renderer').ReactTestRenderer, testID: string): boolean {
  return r.root.findAllByProps({ testID }).length > 0;
}

describe('JhaStopWorkScreen acknowledgement', () => {
  it('states anyone on site has stop-work authority and requires a tailgate meeting', () => {
    const text = flatText(render(<JhaStopWorkScreen onAcknowledge={() => undefined} />).toJSON());
    expect(text).toContain('Anyone on this site');
    expect(text.toLowerCase()).toContain('authority to stop work');
    expect(text.toLowerCase()).toContain('tailgate meeting');
  });
});

describe('JhaPpeScreen Other', () => {
  it('reveals a fill-in field only after Other is selected', () => {
    const r = render(<JhaPpeScreen onNext={() => undefined} />);
    expect(has(r, 'jha-ppe-other-text')).toBe(false);
    tap(r, 'jha-ppe-other');
    expect(has(r, 'jha-ppe-other-text')).toBe(true);
  });
});

describe('JhaSignaturesScreen', () => {
  it('pre-fills the driver and shows no forced Supervisor/Customer rows', () => {
    const r = render(<JhaSignaturesScreen driverName="driver-007" onContinue={() => undefined} />);
    expect(r.root.findByProps({ testID: 'jha-sig-name-driver' }).props.value).toBe('driver-007');
    const text = flatText(r.toJSON());
    expect(text).not.toContain('Customer Rep');
    expect(text).not.toContain('M. Reyes'); // the old hardcoded fake name is gone
  });

  it('lets the driver add another person on site with a selectable role', () => {
    const r = render(<JhaSignaturesScreen driverName="driver-007" onContinue={() => undefined} />);
    expect(has(r, 'jha-sig-name-person-1')).toBe(false);
    tap(r, 'jha-sig-add');
    expect(has(r, 'jha-sig-name-person-1')).toBe(true);
    expect(has(r, 'jha-sig-role-person-1-owner')).toBe(true); // Owner is an option
  });

  it('emits every signed person with the selected role', () => {
    const onContinue = jest.fn();
    const r = render(<JhaSignaturesScreen driverName="driver-007" onContinue={onContinue} />);
    tap(r, 'jha-sig-add');
    changeText(r, 'jha-sig-name-person-1', 'Casey Owner');
    tap(r, 'jha-sig-role-person-1-owner');
    sign(r, 'jha-sig-pad-driver');
    sign(r, 'jha-sig-pad-person-1');
    tap(r, 'jha-sig-continue');

    expect(onContinue).toHaveBeenCalledWith({
      signatures: [
        { signature: SIGNED, signerName: 'driver-007', signerRole: 'Driver' },
        { signature: SIGNED, signerName: 'Casey Owner', signerRole: 'Owner' },
      ],
    });
  });
});
