/**
 * Dead-handler sweep: the "Call Dispatch / Supervisor" buttons (Help, sign-in Help) and the End-Day
 * Contact Dispatch actually dial the OS instead of being no-ops, via the shared contacts helpers.
 */
import { Linking } from 'react-native';

import { callDispatch, callNumber, DISPATCH_PHONE, SUPERVISOR_PHONE } from '../src/config/contacts';
import { HelpSupportScreen } from '../src/screens/MoreScreens';
import { SignInHelpScreen } from '../src/screens/UnauthScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

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

describe('contacts helpers', () => {
  it('dial the right numbers', () => {
    const spy = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    callDispatch();
    expect(spy).toHaveBeenLastCalledWith(`tel:${DISPATCH_PHONE}`);
    callNumber(SUPERVISOR_PHONE);
    expect(spy).toHaveBeenLastCalledWith(`tel:${SUPERVISOR_PHONE}`);
    spy.mockRestore();
  });
});

describe('Help call buttons actually dial', () => {
  it('Help & Support Call Dispatch dials the dispatcher', () => {
    const spy = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const r = render(<HelpSupportScreen />);
    tap(r, 'help-call-dispatch');
    expect(spy).toHaveBeenCalledWith(`tel:${DISPATCH_PHONE}`);
    spy.mockRestore();
  });

  it('Sign-in Help Call Dispatch dials the dispatcher', () => {
    const spy = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const r = render(<SignInHelpScreen onBack={() => undefined} />);
    tap(r, 'help-call-dispatch');
    expect(spy).toHaveBeenCalledWith(`tel:${DISPATCH_PHONE}`);
    spy.mockRestore();
  });
});
