/**
 * Day Dashboard (GUI Master §6 / screen 7) — the workday command center and the app's home. It
 * answers "where am I in the day, what's required next, are my jobs saved/synced?" The layout
 * follows the spec: workday status → next required step (the one highlighted card) → today's flow
 * timeline → jobs summary → sync summary. Driver-facing only: no UUIDs, hashes, or env strings.
 *
 * Honesty over theatre: punch-in state is READ from the Hub clock gate (TimeClock owns punching in),
 * so when the driver is not punched in the screen guides them to TimeClock rather than faking a
 * mobile punch-in the Hub does not yet accept.
 */
import { StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  StatusBadge,
  spacing,
  typeScale,
  useResolvedTheme,
  type Theme,
  type Tone,
} from '../design';

export type WorkdayStepState = 'complete' | 'next' | 'in-progress' | 'locked';

export interface WorkdayStep {
  key: string;
  label: string;
  state: WorkdayStepState;
}

const STEP_BADGE: Record<WorkdayStepState, { label: string; tone: Tone }> = {
  complete: { label: 'Complete', tone: 'success' },
  next: { label: 'Next', tone: 'info' },
  'in-progress': { label: 'In Progress', tone: 'info' },
  locked: { label: 'Locked', tone: 'neutral' },
};

/** Build the canonical workday timeline from the few facts we can honestly assert. */
export function buildWorkdayTimeline(input: {
  punchedIn: boolean;
  jobsCount: number;
}): WorkdayStep[] {
  const { punchedIn, jobsCount } = input;
  return [
    { key: 'punch-in', label: 'Punch In', state: punchedIn ? 'complete' : 'next' },
    {
      key: 'pre-trip',
      label: 'Pre-Trip Inspection',
      state: punchedIn ? 'next' : 'locked',
    },
    {
      key: 'jobs',
      label: jobsCount > 0 ? `Jobs (${jobsCount})` : 'Jobs',
      state: punchedIn ? 'in-progress' : 'locked',
    },
    { key: 'post-trip', label: 'Post-Trip Inspection', state: 'locked' },
    { key: 'punch-out', label: 'Punch Out', state: 'locked' },
  ];
}

export function DayDashboardScreen(props: {
  punchedIn: boolean;
  clockedInSince?: string;
  /** Plain-English guidance shown when not punched in / Hub unreachable. */
  statusDetail?: string;
  jobsCount: number;
  needsReview: number;
  pendingSync: number;
  timeline: WorkdayStep[];
  checking?: boolean;
  primaryLabel: string;
  onPrimary: () => void;
  onOpenJobs: () => void;
  onRefresh: () => void;
  /**
   * In-app inspection launchers (each shown only when provided). Punching is NOT here: clocking in
   * and out happens only at the physical Field Time Terminal (NFC badge + camera), so the app shows
   * punch status read-only and never offers a punch button.
   */
  onStartPreTrip?: () => void;
  onStartPostTrip?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const nextStepLabel = props.punchedIn
    ? 'Work your assigned jobs'
    : 'Punch in to start your workday';
  const nextStepBody = props.punchedIn
    ? 'Open Jobs to complete the JHA/JSA and field ticket for each assignment.'
    : 'Punching in is done in TimeClock. Once you are punched in, your inspections and jobs unlock here.';

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Today</Text>

      <Card theme={t} title="Workday status">
        <View style={styles.row}>
          <StatusBadge
            label={props.punchedIn ? 'Punched In' : 'Not Punched In'}
            tone={props.punchedIn ? 'success' : 'warning'}
            testID="day-punch-state"
          />
          {props.checking ? (
            <Text style={[styles.meta, { color: t.textMuted }]}>Checking…</Text>
          ) : null}
        </View>
        {props.punchedIn && props.clockedInSince !== undefined ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>
            Clocked in since {props.clockedInSince}
          </Text>
        ) : null}
        {props.statusDetail !== undefined ? (
          <Text style={[styles.meta, { color: t.textMuted }]}>{props.statusDetail}</Text>
        ) : null}
      </Card>

      <Card theme={t} tone="highlight" title="Next required step" testID="day-next-step">
        <Text style={[styles.nextTitle, { color: t.text }]}>{nextStepLabel}</Text>
        <Text style={[styles.body2, { color: t.text }]}>{nextStepBody}</Text>
        <Button
          theme={t}
          label={props.primaryLabel}
          onPress={props.onPrimary}
          testID="day-primary"
        />
      </Card>

      {props.onStartPreTrip !== undefined || props.onStartPostTrip !== undefined ? (
        <Card theme={t} title="Workday steps">
          {props.onStartPreTrip !== undefined ? (
            <Button
              theme={t}
              variant="secondary"
              label="Driver Pre-Trip Inspection"
              onPress={props.onStartPreTrip}
              testID="day-start-pretrip"
            />
          ) : null}
          {props.onStartPostTrip !== undefined ? (
            <Button
              theme={t}
              variant="secondary"
              label="End Day / Post-Trip"
              onPress={props.onStartPostTrip}
              testID="day-start-posttrip"
            />
          ) : null}
        </Card>
      ) : null}

      <Card theme={t} title="Today’s flow">
        {props.timeline.map((step) => (
          <View key={step.key} style={styles.timelineRow} testID={`timeline-${step.key}`}>
            <Text style={[styles.stepLabel, { color: t.text }]}>{step.label}</Text>
            <StatusBadge label={STEP_BADGE[step.state].label} tone={STEP_BADGE[step.state].tone} />
          </View>
        ))}
      </Card>

      <Card theme={t} title="Today’s jobs">
        <Text style={[styles.body2, { color: t.text }]}>
          {props.jobsCount === 0
            ? 'No jobs loaded yet. Pull to refresh from the Hub.'
            : `${props.jobsCount} job${props.jobsCount === 1 ? '' : 's'} assigned` +
              (props.needsReview > 0 ? ` · ${props.needsReview} need review` : '')}
        </Text>
        <Button
          theme={t}
          variant="secondary"
          label="Open Jobs"
          onPress={props.onOpenJobs}
          testID="day-open-jobs"
        />
      </Card>

      <Card theme={t} title="Sync">
        <Text style={[styles.body2, { color: t.text }]}>
          {props.pendingSync === 0
            ? 'All your work is saved and up to date.'
            : `${props.pendingSync} item${props.pendingSync === 1 ? '' : 's'} waiting to sync. Your work is safe on this phone.`}
        </Text>
        <Button
          theme={t}
          variant="secondary"
          label={props.checking ? 'Refreshing…' : 'Refresh from Hub'}
          onPress={props.onRefresh}
          testID="day-refresh"
        />
      </Card>
    </View>
  );
}

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
  },
  meta: {
    fontSize: typeScale.label,
  },
  nextTitle: {
    fontSize: typeScale.heading,
    fontWeight: '800',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  timelineRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 6,
  },
  stepLabel: {
    fontSize: typeScale.body,
    fontWeight: '600',
  },
});
