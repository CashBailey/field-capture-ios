/**
 * SignatureField — the finger-drawable pad reused across DVIR/JHA/Evidence. The drawing gesture
 * itself is PanResponder (covered by signature-model.test); here we pin the host-facing contract:
 * unsigned vs captured rendering, opening the landscape modal, and Clear emitting null.
 */
import { SignatureField, serializeSignature, deserializeSignature } from '../src/design';

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

describe('SignatureField', () => {
  it('shows "Tap to sign" and a disabled Clear when unsigned', () => {
    const r = render(<SignatureField value={null} onChange={() => undefined} testID="sig" />);
    expect(JSON.stringify(r.toJSON())).toContain('Tap to sign');
    expect(r.root.findByProps({ testID: 'sig-clear' }).props.disabled).toBe(true);
    expect(r.root.findByProps({ testID: 'sig-capture' }).props.label).toBe('Sign');
  });

  it('renders captured ink and enables Re-sign / Clear when a value is present', () => {
    const r = render(<SignatureField value={SIGNED} onChange={() => undefined} testID="sig" />);
    expect(r.root.findByProps({ testID: 'sig-capture' }).props.label).toBe('Re-sign');
    expect(r.root.findByProps({ testID: 'sig-clear' }).props.disabled).toBe(false);
    expect(JSON.stringify(r.toJSON())).not.toContain('Tap to sign');
  });

  it('Clear emits null to the host', () => {
    const onChange = jest.fn();
    const r = render(<SignatureField value={SIGNED} onChange={onChange} testID="sig" />);
    act(() => r.root.findByProps({ testID: 'sig-clear' }).props.onPress());
    expect(onChange).toHaveBeenCalledWith(null);
  });

  it('tapping the pad opens the landscape signing modal', () => {
    const r = render(<SignatureField value={null} onChange={() => undefined} testID="sig" />);
    expect(r.root.findByProps({ testID: 'sig-modal' }).props.visible).toBe(false);
    act(() => r.root.findByProps({ testID: 'sig-pad' }).props.onPress());
    expect(r.root.findByProps({ testID: 'sig-modal' }).props.visible).toBe(true);
  });

  // Drive the real PanResponder on the modal canvas, then Done, and assert the emitted payload.
  // panHandlers spreads onResponderGrant/onResponderMove onto the canvas View; we call them with
  // synthetic responder events the way RN does. PanResponder's wrapper computes a centroid from
  // event.touchHistory before delegating to the component, so we hand it an empty (no active
  // touches) history — the component itself only reads nativeEvent.locationX/locationY.
  // Each event needs a distinct, increasing mostRecentTimeStamp or PanResponder dedupes the move.
  let ts = 0;
  const evt = (x: number, y: number) => ({
    nativeEvent: { locationX: x, locationY: y },
    touchHistory: {
      numberActiveTouches: 0,
      indexOfSingleActiveTouch: 0,
      touchBank: [],
      mostRecentTimeStamp: ++ts,
    },
  });
  const grant = (canvas: any, x: number, y: number) => canvas.props.onResponderGrant(evt(x, y));
  const move = (canvas: any, x: number, y: number) => canvas.props.onResponderMove(evt(x, y));

  it('drawing a stroke then Done emits a serialized signature matching the model shape', () => {
    const onChange = jest.fn();
    const r = render(<SignatureField value={null} onChange={onChange} testID="sig" />);
    act(() => r.root.findByProps({ testID: 'sig-pad' }).props.onPress());

    const canvas = r.root.findByProps({ testID: 'sig-modal-canvas' });
    act(() => {
      grant(canvas, 5, 5);
      move(canvas, 40, 12);
      move(canvas, 80, 6);
    });
    act(() => r.root.findByProps({ testID: 'sig-modal-done' }).props.onPress());

    expect(onChange).toHaveBeenCalledTimes(1);
    const payload = onChange.mock.calls[0][0];
    expect(typeof payload).toBe('string');
    // Payload is the same serialized vector the model produces from those points (rounded ints).
    expect(payload).toBe(
      serializeSignature([
        [
          { x: 5, y: 5 },
          { x: 40, y: 12 },
          { x: 80, y: 6 },
        ],
      ]),
    );
    expect(deserializeSignature(payload)).toEqual([
      [
        { x: 5, y: 5 },
        { x: 40, y: 12 },
        { x: 80, y: 6 },
      ],
    ]);
  });

  it('drawing then Clear in the modal then Done emits null (nothing drawn)', () => {
    const onChange = jest.fn();
    const r = render(<SignatureField value={null} onChange={onChange} testID="sig" />);
    act(() => r.root.findByProps({ testID: 'sig-pad' }).props.onPress());

    const canvas = r.root.findByProps({ testID: 'sig-modal-canvas' });
    act(() => {
      grant(canvas, 5, 5);
      move(canvas, 40, 12);
    });
    // Done is enabled once something is drawn; Clear wipes the canvas back to empty.
    expect(r.root.findByProps({ testID: 'sig-modal-done' }).props.disabled).toBe(false);
    act(() => r.root.findByProps({ testID: 'sig-modal-clear' }).props.onPress());
    expect(r.root.findByProps({ testID: 'sig-modal-done' }).props.disabled).toBe(true);

    act(() => r.root.findByProps({ testID: 'sig-modal-done' }).props.onPress());
    expect(onChange).toHaveBeenCalledWith(null);
  });
});
