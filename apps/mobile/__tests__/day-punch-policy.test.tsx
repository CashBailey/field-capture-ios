/**
 * Terminal-only punch policy (T2): the Day dashboard shows punch status read-only and never offers a
 * Punch In / Punch Out button — clocking in/out happens only at the physical Field Time Terminal.
 * The in-app inspection launchers remain.
 */
import { buildWorkdayTimeline, DayDashboardScreen } from '../src/screens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const base = {
  jobsCount: 1,
  needsReview: 0,
  pendingSync: 0,
  primaryLabel: 'Open Jobs',
  onPrimary: () => undefined,
  onOpenJobs: () => undefined,
  onRefresh: () => undefined,
};

function buttonLabels(r: import('react-test-renderer').ReactTestRenderer): string[] {
  return r.root
    .findAll((n) => typeof (n.props as { label?: unknown }).label === 'string')
    .map((n) => (n.props as { label: string }).label);
}

describe('Day dashboard punch policy', () => {
  it('renders no Punch In / Punch Out button but keeps the inspection launchers', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(
        <DayDashboardScreen
          {...base}
          punchedIn
          clockedInSince="6:02 AM"
          onStartPreTrip={() => undefined}
          onStartPostTrip={() => undefined}
          timeline={buildWorkdayTimeline({ punchedIn: true, jobsCount: 1 })}
        />,
      );
    });
    const labels = buttonLabels(r!);
    expect(labels).toContain('Driver Pre-Trip Inspection');
    expect(labels).toContain('End Day / Post-Trip');
    expect(labels).not.toContain('Punch In');
    expect(labels).not.toContain('Punch Out');
    // status is still shown, read-only
    expect(r!.root.findAllByProps({ testID: 'day-punch-state' }).length).toBeGreaterThan(0);
  });

  it('still guides to TimeClock when not punched in', () => {
    let r: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      r = TestRenderer.create(
        <DayDashboardScreen
          {...base}
          punchedIn={false}
          timeline={buildWorkdayTimeline({ punchedIn: false, jobsCount: 1 })}
        />,
      );
    });
    expect(JSON.stringify(r!.toJSON())).toContain('TimeClock');
    expect(buttonLabels(r!)).not.toContain('Punch In');
  });
});
