/**
 * Pre-Trip DVIR integrity (the safety-critical fix): a driver can no longer "complete" an inspection
 * without marking every item, and Review/Complete now reflect the REAL entered results instead of a
 * hardcoded "45/45, 0 defects".
 */
import {
  PreTripSectionScreen,
  summarizeInspection,
  type InspectionItem,
  type InspectionResult,
} from '../src/screens/PreTripScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const ITEMS: InspectionItem[] = [
  { key: 'brakes', label: 'Brakes', result: 'not-checked', group: 'truck' },
  { key: 'tires', label: 'Tires', result: 'not-checked', group: 'truck' },
  { key: 'hoses', label: 'Product Hoses', result: 'not-checked', group: 'trailer' },
];

function render(node: React.ReactElement) {
  let r: import('react-test-renderer').ReactTestRenderer;
  act(() => {
    r = TestRenderer.create(node);
  });
  return r!;
}

/** Recursively concatenate every string/number leaf so split <Text> children read as one string. */
function flatText(json: unknown): string {
  if (json === null || json === undefined) return '';
  if (typeof json === 'string' || typeof json === 'number') return String(json);
  if (Array.isArray(json)) return json.map(flatText).join('');
  const node = json as { children?: unknown };
  return flatText(node.children);
}

function tap(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  act(() => r.root.findByProps({ testID }).props.onPress());
}

describe('summarizeInspection', () => {
  it('counts checked/defects and splits truck vs trailer', () => {
    const results: Record<string, InspectionResult> = {
      brakes: 'ok',
      tires: 'defect',
      hoses: 'not-checked',
    };
    const s = summarizeInspection(ITEMS, results);
    expect(s.total).toBe(3);
    expect(s.checked).toBe(2);
    expect(s.defectCount).toBe(1);
    expect(s.truckChecked).toBe(2);
    expect(s.truckTotal).toBe(2);
    expect(s.trailerChecked).toBe(0);
    expect(s.trailerTotal).toBe(1);
    expect(s.allChecked).toBe(false);
  });

  it('allChecked only once nothing is left not-checked', () => {
    const s = summarizeInspection(ITEMS, { brakes: 'ok', tires: 'ok', hoses: 'ok' });
    expect(s.allChecked).toBe(true);
    expect(s.checked).toBe(3);
  });
});

describe('PreTripSectionScreen gate', () => {
  it('defaults every item to not-checked and disables Continue', () => {
    const r = render(<PreTripSectionScreen items={ITEMS} onContinue={() => undefined} />);
    expect(r.root.findByProps({ testID: 'pretrip-continue' }).props.disabled).toBe(true);
    expect(flatText(r.toJSON())).toContain('3 items to go');
  });

  it('the full default checklist has 62 untouched items', () => {
    const r = render(<PreTripSectionScreen onContinue={() => undefined} />);
    expect(flatText(r.toJSON())).toContain('0 of 62 items checked');
    expect(r.root.findByProps({ testID: 'pretrip-continue' }).props.disabled).toBe(true);
  });

  it('enables Continue once all marked and reports the real summary', () => {
    const onContinue = jest.fn();
    const r = render(<PreTripSectionScreen items={ITEMS} onContinue={onContinue} />);
    tap(r, 'pretrip-item-brakes-control-ok');
    tap(r, 'pretrip-item-tires-control-defect');
    // still one item (hoses) unmarked → gate holds
    expect(r.root.findByProps({ testID: 'pretrip-continue' }).props.disabled).toBe(true);
    tap(r, 'pretrip-item-hoses-control-ok');
    const continueBtn = r.root.findByProps({ testID: 'pretrip-continue' });
    expect(continueBtn.props.disabled).toBe(false);
    act(() => continueBtn.props.onPress());
    expect(onContinue).toHaveBeenCalledTimes(1);
    const summary = onContinue.mock.calls[0][0];
    expect(summary.checked).toBe(3);
    expect(summary.defectCount).toBe(1);
    expect(summary.allChecked).toBe(true);
  });
});
