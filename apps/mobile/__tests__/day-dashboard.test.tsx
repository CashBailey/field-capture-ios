/**
 * Day Dashboard (GUI Master §6) — pins the honest workday model: the timeline reflects only what we
 * can assert (punch-in from the Hub clock gate), and the screen never claims "punched in" when the
 * gate says otherwise.
 */
import { buildWorkdayTimeline, DayDashboardScreen } from '../src/screens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const baseProps = {
  jobsCount: 1,
  needsReview: 0,
  pendingSync: 0,
  primaryLabel: 'Open Jobs',
  onPrimary: () => undefined,
  onOpenJobs: () => undefined,
  onRefresh: () => undefined,
};

function textOf(renderer: import('react-test-renderer').ReactTestRenderer): string {
  return JSON.stringify(renderer.toJSON());
}

describe('buildWorkdayTimeline', () => {
  it('locks everything past punch-in until the driver is punched in', () => {
    const steps = buildWorkdayTimeline({ punchedIn: false, jobsCount: 2 });
    expect(steps.find((s) => s.key === 'punch-in')?.state).toBe('next');
    expect(steps.find((s) => s.key === 'pre-trip')?.state).toBe('locked');
    expect(steps.find((s) => s.key === 'jobs')?.state).toBe('locked');
  });

  it('advances the flow once punched in', () => {
    const steps = buildWorkdayTimeline({ punchedIn: true, jobsCount: 2 });
    expect(steps.find((s) => s.key === 'punch-in')?.state).toBe('complete');
    expect(steps.find((s) => s.key === 'pre-trip')?.state).toBe('next');
    expect(steps.find((s) => s.key === 'jobs')?.state).toBe('in-progress');
  });
});

describe('DayDashboardScreen', () => {
  it('shows Not Punched In and guides to TimeClock when the gate is locked', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <DayDashboardScreen
          {...baseProps}
          punchedIn={false}
          timeline={buildWorkdayTimeline({ punchedIn: false, jobsCount: 1 })}
        />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('Not Punched In');
    expect(text).toContain('TimeClock');
  });

  it('shows Punched In and fires the primary action when unlocked', () => {
    const onPrimary = jest.fn();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <DayDashboardScreen
          {...baseProps}
          punchedIn
          clockedInSince="2026-06-16T06:02:00Z"
          onPrimary={onPrimary}
          timeline={buildWorkdayTimeline({ punchedIn: true, jobsCount: 1 })}
        />,
      );
    });
    expect(textOf(renderer!)).toContain('Punched In');
    act(() => {
      renderer!.root.findByProps({ testID: 'day-primary' }).props.onPress();
    });
    expect(onPrimary).toHaveBeenCalledTimes(1);
  });
});
