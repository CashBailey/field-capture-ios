/**
 * Signature screens wiring (Task 4): the three driver-facing signature screens (pre-trip DVIR,
 * post-trip DVIR, JHA) must (a) keep Complete/Continue disabled until a signature is drawn and
 * (b) emit the captured SignatureValue + signer name up to the host, and they render a
 * certificationText prop that defaults to the canonical contract constant.
 *
 * The repo tests with react-test-renderer (no @testing-library/react-native installed), so we drive
 * the SignatureField via its onChange prop (the realistic equivalent of firing its onChange event)
 * and read button `disabled`/press handlers off the rendered tree.
 */
import { fieldwork } from '@fieldcapture/contracts';

import { PreTripSignatureScreen } from '../src/screens/PreTripScreens';
import { PostTripSignatureScreen } from '../src/screens/PostTripScreens';
import { JhaSignaturesScreen } from '../src/screens/JhaScreens';
import { serializeSignature } from '../src/design';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const SIGNED = serializeSignature([
  [
    { x: 0, y: 0 },
    { x: 40, y: 10 },
    { x: 80, y: 0 },
  ],
]);

function render(node: React.ReactElement) {
  let r: import('react-test-renderer').ReactTestRenderer;
  act(() => {
    r = TestRenderer.create(node);
  });
  return r!;
}

/** First node carrying this testID that also has a function `prop`. */
function nodeWith(
  r: import('react-test-renderer').ReactTestRenderer,
  testID: string,
  prop: string,
) {
  const nodes = r.root.findAllByProps({ testID });
  return nodes.find((n) => typeof n.props[prop] === 'function') ?? nodes[0];
}

function press(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  act(() => nodeWith(r, testID, 'onPress').props.onPress());
}

function sign(r: import('react-test-renderer').ReactTestRenderer, testID: string, value: string) {
  act(() => nodeWith(r, testID, 'onChange').props.onChange(value));
}

function flatText(json: unknown): string {
  if (json === null || json === undefined) return '';
  if (typeof json === 'string' || typeof json === 'number') return String(json);
  if (Array.isArray(json)) return json.map(flatText).join('');
  return flatText((json as { children?: unknown }).children);
}

describe('PreTripSignatureScreen', () => {
  it('Complete is disabled until a signature is captured, then emits it', () => {
    const onComplete = jest.fn();
    const r = render(
      <PreTripSignatureScreen driverName="Alex Rivera" onCompletePreTrip={onComplete} />,
    );
    // Primary Complete is disabled before a signature is drawn.
    expect(r.root.findByProps({ testID: 'signature-complete' }).props.disabled).toBe(true);

    // Drive the SignatureField onChange (the testID surface the host wires).
    sign(r, 'pretrip-signature', SIGNED);

    // Now enabled — open the confirm card, then complete.
    expect(r.root.findByProps({ testID: 'signature-complete' }).props.disabled).toBe(false);
    press(r, 'signature-complete');
    press(r, 'signature-confirm-complete');

    expect(onComplete).toHaveBeenCalledWith(
      expect.objectContaining({ signature: SIGNED, signerName: 'Alex Rivera' }),
    );
  });

  it('renders the default pre-trip certification text and an override', () => {
    const def = render(
      <PreTripSignatureScreen driverName="d" onCompletePreTrip={() => undefined} />,
    );
    expect(flatText(def.toJSON())).toContain(fieldwork.DVIR_PRETRIP_CERTIFICATION_TEXT);

    const over = render(
      <PreTripSignatureScreen
        driverName="d"
        certificationText="Custom pre-trip attestation."
        onCompletePreTrip={() => undefined}
      />,
    );
    expect(flatText(over.toJSON())).toContain('Custom pre-trip attestation.');
  });
});

describe('PostTripSignatureScreen', () => {
  it('Complete is disabled until signed, then emits the captured value + signer', () => {
    const onComplete = jest.fn();
    const r = render(<PostTripSignatureScreen driverName="Marcus Hill" onComplete={onComplete} />);
    expect(r.root.findByProps({ testID: 'post-trip-complete' }).props.disabled).toBe(true);

    sign(r, 'post-trip-signature', SIGNED);
    expect(r.root.findByProps({ testID: 'post-trip-complete' }).props.disabled).toBe(false);
    press(r, 'post-trip-complete');

    expect(onComplete).toHaveBeenCalledWith(
      expect.objectContaining({ signature: SIGNED, signerName: 'Marcus Hill' }),
    );
  });

  it('renders the default post-trip certification text', () => {
    const r = render(<PostTripSignatureScreen driverName="d" onComplete={() => undefined} />);
    expect(flatText(r.toJSON())).toContain(fieldwork.DVIR_POSTTRIP_CERTIFICATION_TEXT);
  });
});

describe('JhaSignaturesScreen', () => {
  it('Continue is disabled until the driver signs, then emits the driver signature', () => {
    const onContinue = jest.fn();
    const r = render(<JhaSignaturesScreen driverName="driver-007" onContinue={onContinue} />);
    expect(r.root.findByProps({ testID: 'jha-sig-continue' }).props.disabled).toBe(true);

    sign(r, 'jha-sig-pad-driver', SIGNED);
    expect(r.root.findByProps({ testID: 'jha-sig-continue' }).props.disabled).toBe(false);
    press(r, 'jha-sig-continue');

    expect(onContinue).toHaveBeenCalledWith({
      signatures: [{ signature: SIGNED, signerName: 'driver-007', signerRole: 'Driver' }],
    });
  });

  it('renders the default JHA certification text', () => {
    const r = render(<JhaSignaturesScreen driverName="d" onContinue={() => undefined} />);
    expect(flatText(r.toJSON())).toContain(fieldwork.JHA_CERTIFICATION_TEXT);
  });
});
