//
//  DayScreens.swift
//  Ported from apps/mobile/src/screens/DayScreens.tsx
//
//  Day Dashboard (GUI Master §6 / screen 7) — the workday command center and the app's home. It
//  answers "where am I in the day, what's required next, are my jobs saved/synced?" The layout
//  follows the spec: workday status → next required step (the one highlighted card) → today's flow
//  timeline → jobs summary → sync summary. Driver-facing only: no UUIDs, hashes, or env strings.
//
//  Honesty over theatre: punch-in state is READ from the Hub clock gate (TimeClock owns punching in),
//  so when the driver is not punched in the screen guides them to TimeClock rather than faking a
//  mobile punch-in the Hub does not yet accept.
//

import SwiftUI

enum WorkdayStepState: String {
    case complete
    case next
    case inProgress = "in-progress"
    case locked
}

struct WorkdayStep {
    var key: String
    var label: String
    var state: WorkdayStepState
}

private struct StepBadgeSpec {
    var label: String
    var tone: Tone
}

private let stepBadge: [WorkdayStepState: StepBadgeSpec] = [
    .complete: StepBadgeSpec(label: "Complete", tone: .success),
    .next: StepBadgeSpec(label: "Next", tone: .info),
    .inProgress: StepBadgeSpec(label: "In Progress", tone: .info),
    .locked: StepBadgeSpec(label: "Locked", tone: .neutral),
]

/// Build the canonical workday timeline from the few facts we can honestly assert.
func buildWorkdayTimeline(punchedIn: Bool, jobsCount: Int) -> [WorkdayStep] {
    [
        WorkdayStep(key: "punch-in", label: "Punch In", state: punchedIn ? .complete : .next),
        WorkdayStep(
            key: "pre-trip",
            label: "Pre-Trip Inspection",
            state: punchedIn ? .next : .locked
        ),
        WorkdayStep(
            key: "jobs",
            label: jobsCount > 0 ? "Jobs (\(jobsCount))" : "Jobs",
            state: punchedIn ? .inProgress : .locked
        ),
        WorkdayStep(key: "post-trip", label: "Post-Trip Inspection", state: .locked),
        WorkdayStep(key: "punch-out", label: "Punch Out", state: .locked),
    ]
}

struct DayDashboardScreen: View {
    var punchedIn: Bool
    var clockedInSince: String?
    /// Plain-English guidance shown when not punched in / Hub unreachable.
    var statusDetail: String?
    var jobsCount: Int
    var needsReview: Int
    var pendingSync: Int
    var timeline: [WorkdayStep]
    var checking: Bool = false
    var primaryLabel: String
    var onPrimary: () -> Void
    var onOpenJobs: () -> Void
    var onRefresh: () -> Void
    /// In-app inspection launchers (each shown only when provided). Punching is NOT here: clocking in
    /// and out happens only at the physical Field Time Terminal (NFC badge + camera), so the app shows
    /// punch status read-only and never offers a punch button.
    var onStartPreTrip: (() -> Void)?
    var onStartPostTrip: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let nextStepLabel =
            punchedIn
            ? "Work your assigned jobs"
            : "Punch in to start your workday"
        let nextStepBody =
            punchedIn
            ? "Open Jobs to complete the JHA/JSA and field ticket for each assignment."
            : "Punching in is done in TimeClock. Once you are punched in, your inspections and jobs unlock here."

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Today")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Workday status", theme: t) {
                HStack(alignment: .center, spacing: spacing.sm) {
                    StatusBadge(
                        label: punchedIn ? "Punched In" : "Not Punched In",
                        tone: punchedIn ? .success : .warning,
                        testID: "day-punch-state"
                    )
                    if checking {
                        Text("Checking…")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                }
                if punchedIn, let clockedInSince {
                    Text("Clocked in since \(clockedInSince)")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                if let statusDetail {
                    Text(statusDetail)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            Card(title: "Next required step", tone: .highlight, testID: "day-next-step", theme: t) {
                Text(nextStepLabel)
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(t.text)
                Text(nextStepBody)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    .lineSpacing(3)
                FieldButton(label: primaryLabel, onPress: onPrimary, testID: "day-primary", theme: t)
            }

            if onStartPreTrip != nil || onStartPostTrip != nil {
                Card(title: "Workday steps", theme: t) {
                    if let onStartPreTrip {
                        FieldButton(
                            label: "Driver Pre-Trip Inspection",
                            onPress: onStartPreTrip,
                            variant: .secondary,
                            testID: "day-start-pretrip",
                            theme: t
                        )
                    }
                    if let onStartPostTrip {
                        FieldButton(
                            label: "End Day / Post-Trip",
                            onPress: onStartPostTrip,
                            variant: .secondary,
                            testID: "day-start-posttrip",
                            theme: t
                        )
                    }
                }
            }

            Card(title: "Today’s flow", theme: t) {
                ForEach(timeline, id: \.key) { step in
                    HStack(alignment: .center) {
                        Text(step.label)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.text)
                        Spacer(minLength: spacing.sm)
                        StatusBadge(
                            label: stepBadge[step.state]?.label ?? "",
                            tone: stepBadge[step.state]?.tone ?? .neutral
                        )
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("timeline-\(step.key)")
                }
            }

            Card(title: "Today’s jobs", theme: t) {
                Text(
                    jobsCount == 0
                        ? "No jobs loaded yet. Pull to refresh from the Hub."
                        : "\(jobsCount) job\(jobsCount == 1 ? "" : "s") assigned"
                            + (needsReview > 0 ? " · \(needsReview) need review" : "")
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .lineSpacing(3)
                FieldButton(
                    label: "Open Jobs",
                    onPress: onOpenJobs,
                    variant: .secondary,
                    testID: "day-open-jobs",
                    theme: t
                )
            }

            Card(title: "Sync", theme: t) {
                Text(
                    pendingSync == 0
                        ? "All your work is saved and up to date."
                        : "\(pendingSync) item\(pendingSync == 1 ? "" : "s") waiting to sync. Your work is safe on this phone."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .lineSpacing(3)
                FieldButton(
                    label: checking ? "Refreshing…" : "Refresh from Hub",
                    onPress: onRefresh,
                    variant: .secondary,
                    testID: "day-refresh",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}
