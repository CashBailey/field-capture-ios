/**
 * SOPs are just SOPs (no "Emergency" category): the one list carries emergency-type procedures
 * (H2S, Spill, Stop Work) inline, Search no longer offers an "Emergency" filter, and the same
 * browser is reachable before sign-in for safety procedures.
 */
import { SignInView } from '../App';
import { RequiredDriverSopsScreen, SopSearchScreen } from '../src/screens/SopExtraScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

function render(node: React.ReactElement) {
  let r: import('react-test-renderer').ReactTestRenderer;
  act(() => {
    r = TestRenderer.create(node);
  });
  return r!;
}
function has(r: import('react-test-renderer').ReactTestRenderer, testID: string): boolean {
  return r.root.findAllByProps({ testID }).length > 0;
}
function flatText(json: unknown): string {
  if (json === null || json === undefined) return '';
  if (typeof json === 'string' || typeof json === 'number') return String(json);
  if (Array.isArray(json)) return json.map(flatText).join('');
  return flatText((json as { children?: unknown }).children);
}

describe('SOPs single list', () => {
  it('renders one "SOPs" list that includes emergency-type procedures', () => {
    const r = render(<RequiredDriverSopsScreen title="SOPs" onOpenSop={() => undefined} />);
    const text = flatText(r.toJSON());
    expect(text).toContain('SOPs');
    expect(text).toContain('H2S Safety');
    expect(text).toContain('Spill Response');
    expect(text).toContain('Stop Work Authority');
  });

  it('Search has no Emergency filter category', () => {
    const r = render(<SopSearchScreen onOpenSop={() => undefined} />);
    expect(has(r, 'sop-search-filter-all')).toBe(true);
    expect(has(r, 'sop-search-filter-emergency')).toBe(false);
  });

  it('lets drivers read SOPs before signing in', () => {
    const r = render(
      <SignInView
        username=""
        password=""
        message={null}
        onUsername={() => undefined}
        onPassword={() => undefined}
        onSubmit={() => undefined}
      />,
    );
    const button = r.root.findByProps({ testID: 'signin-sops' });

    act(() => button.props.onPress());

    const text = flatText(r.toJSON());
    expect(text).toContain('SOPs');
    expect(text).toContain('H2S Safety');
    expect(text).toContain('Stop Work Authority');
  });
});
