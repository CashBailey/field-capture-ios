//
//  JobScreens.swift
//  Ported from apps/mobile/src/screens/JobScreens.tsx
//
//  Job pages (GUI Master §9 / screens 27–32) — the per-job experience for a vacuum-truck driver:
//
//    27. Jobs List            — assigned / next / completed jobs with status + filter chips
//    28. Job Overview         — the job command center (required flow + supporting actions + menu)
//    29. Job Details          — the full job sheet, driver-facing fields only
//    30. Job SOPs             — SOPs relevant to this job, grouped by relevance
//    31. Emergency Info       — fast-access emergency contacts mapped from the JHA/JSA
//    32. Stop Work / Report Concern — stop-work authority made visible + a concern report form
//
//  All six screens are presentational and props-driven. They never touch the domain/runtime/data
//  layers and never render UUIDs, hashes, snapshots, sync internals, server versions, or hub URLs
//  (GUI Master §20). Production builds fail visibly when authoritative job data or an action is
//  unavailable. Debug-only fixtures keep the screen gallery useful and are always labeled as
//  previews. Camera / GPS validation / print / directions are wired by the host shell.
//

import SwiftUI

private struct DebugJobFixtureNotice: View {
    var theme: Theme

    var body: some View {
        Card(tone: .highlight, testID: "debug-job-fixture", theme: theme) {
            Text("Preview data")
                .font(.system(size: typeScale.label, weight: .bold))
                .foregroundStyle(theme.text)
            Text("Some content and actions are debug-only fixtures for the screen gallery.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.textMuted)
        }
    }
}

private struct JobDataUnavailable: View {
    var title: String
    var message: String
    var testID: String
    var theme: Theme

    var body: some View {
        Card(title: title, tone: .highlight, testID: testID, theme: theme) {
            Text(message)
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
        }
    }
}

/* ------------------------------------------------------------------ *
 * Shared status vocabulary (GUI Master §20). Only these labels appear.
 * ------------------------------------------------------------------ */

enum JobStatusLabel: String {
    case notStarted = "Not Started"
    case inProgress = "In Progress"
    case required = "Required"
    case locked = "Locked"
    case blocked = "Blocked"
    case needsReview = "Needs Review"
    case savedOnPhone = "Saved on Phone"
    case pendingSync = "Pending Sync"
    case syncing = "Syncing"
    case synced = "Synced"
    case submitted = "Submitted"
    case complete = "Complete"
}

private let statusToneMap: [JobStatusLabel: Tone] = [
    .notStarted: .neutral,
    .inProgress: .info,
    .required: .warning,
    .locked: .neutral,
    .blocked: .danger,
    .needsReview: .warning,
    .savedOnPhone: .info,
    .pendingSync: .warning,
    .syncing: .info,
    .synced: .success,
    .submitted: .success,
    .complete: .success,
]

private func statusTone(_ label: JobStatusLabel) -> Tone {
    statusToneMap[label] ?? .neutral
}

/* ================================================================== *
 * 27. Jobs List
 * ================================================================== */

enum JobsFilter: String {
    case all
    case notStarted = "not-started"
    case inProgress = "in-progress"
    case blocked
    case completed
    case pendingSync = "pending-sync"
}

private struct JobsFilterOption {
    var key: JobsFilter
    var label: String
}

private let jobsFilters: [JobsFilterOption] = [
    JobsFilterOption(key: .all, label: "All"),
    JobsFilterOption(key: .notStarted, label: "Not Started"),
    JobsFilterOption(key: .inProgress, label: "In Progress"),
    JobsFilterOption(key: .blocked, label: "Blocked"),
    JobsFilterOption(key: .completed, label: "Completed"),
    JobsFilterOption(key: .pendingSync, label: "Pending Sync"),
]

enum JobGroup: String {
    case current
    case next
    case completed
}

/// The job's primary verb.
enum JobListPrimaryLabel: String {
    case startJob = "Start Job"
    case continueJob = "Continue Job"
    case reviewJob = "Review Job"
}

struct JobListItem {
    /// Opaque assignment key used only for navigation. It is never rendered to the driver.
    var assignmentId: String? = nil
    /// Driver-facing service-record number, e.g. "2026-000001". Never a UUID.
    var serviceRecord: String
    var customer: String
    var lease: String
    var well: String
    var jobType: String
    var group: JobGroup
    var jhaStatus: JobStatusLabel
    var ticketStatus: JobStatusLabel
    var syncStatus: JobStatusLabel
    /// The job's primary verb.
    var primaryLabel: JobListPrimaryLabel

    var navigationKey: String { assignmentId ?? serviceRecord }
}

#if DEBUG
    private let sampleJobs: [JobListItem] = [
        JobListItem(
            serviceRecord: "2026-000001",
            customer: "Acme Energy, LLC",
            lease: "Northfield Lease",
            well: "Northfield 06H",
            jobType: "Produced Water Haul",
            group: .current,
            jhaStatus: .notStarted,
            ticketStatus: .locked,
            syncStatus: .savedOnPhone,
            primaryLabel: .continueJob
        ),
        JobListItem(
            serviceRecord: "2026-000002",
            customer: "Acme Energy, LLC",
            lease: "Northfield Lease",
            well: "Northfield 114H",
            jobType: "Produced Water Haul",
            group: .next,
            jhaStatus: .notStarted,
            ticketStatus: .locked,
            syncStatus: .savedOnPhone,
            primaryLabel: .startJob
        ),
        JobListItem(
            serviceRecord: "2026-000000",
            customer: "Acme Energy, LLC",
            lease: "Northfield Lease",
            well: "Northfield 114H",
            jobType: "Produced Water Haul",
            group: .completed,
            jhaStatus: .complete,
            ticketStatus: .submitted,
            syncStatus: .synced,
            primaryLabel: .reviewJob
        ),
    ]
#endif

private let groupTitle: [JobGroup: String] = [
    .current: "Current Job",
    .next: "Next Jobs",
    .completed: "Completed Jobs",
]

private let groupOrder: [JobGroup] = [.current, .next, .completed]

/// Decide whether a job matches the active filter.
private func jobMatchesFilter(_ job: JobListItem, _ filter: JobsFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .notStarted:
        return job.jhaStatus == .notStarted
    case .inProgress:
        return job.jhaStatus == .inProgress || job.ticketStatus == .inProgress
    case .blocked:
        return job.jhaStatus == .blocked || job.ticketStatus == .blocked
    case .completed:
        return job.group == .completed
    case .pendingSync:
        return job.syncStatus == .pendingSync || job.syncStatus == .savedOnPhone
    }
}

struct JobsListScreen: View {
    var jobs: [JobListItem]?
    var onOpenJob: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    var theme: Theme?

    init(
        jobs: [JobListItem]? = nil,
        onOpenJob: ((String) -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.jobs = jobs
        self.onOpenJob = onOpenJob
        self.onRefresh = onRefresh
        self.theme = theme
    }

    @Environment(\.fieldTheme) private var envTheme
    @State private var filter: JobsFilter = .all

    private var renderedJobs: [JobListItem]? {
        #if DEBUG
            jobs ?? sampleJobs
        #else
            jobs
        #endif
    }

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            jobs == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme
        let allJobs = renderedJobs ?? []
        let visible = allJobs.filter { jobMatchesFilter($0, filter) }

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Jobs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            if renderedJobs != nil {
                FlowLayout(spacing: spacing.sm) {
                    ForEach(jobsFilters, id: \.key) { f in
                        let selected = f.key == filter
                        Button(action: { filter = f.key }) {
                            Text(f.label)
                                .font(.system(size: typeScale.label, weight: .bold))
                                .foregroundStyle(selected ? t.onPrimary : t.textMuted)
                                .frame(minHeight: sizing.minTouchTarget)
                                .padding(.horizontal, 16)
                                .background(selected ? t.primary : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .stroke(selected ? t.primary : t.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("jobs-filter-\(f.key.rawValue)")
                    }
                }
            }

            if renderedJobs == nil {
                JobDataUnavailable(
                    title: "Jobs unavailable",
                    message:
                        "No authoritative assignment data is available. Refresh from the Hub before starting work.",
                    testID: "jobs-unavailable",
                    theme: t
                )
            } else if visible.isEmpty {
                Card(title: "No jobs match this filter", theme: t) {
                    Text("Try the \u{201C}All\u{201D} filter, or pull in the latest from the Hub.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                    FieldButton(
                        label: "Refresh from Hub",
                        onPress: { onRefresh?() },
                        variant: .secondary,
                        disabled: onRefresh == nil,
                        testID: "jobs-refresh",
                        theme: t
                    )
                }
            } else {
                ForEach(groupOrder, id: \.self) { group in
                    let groupJobs = visible.filter { $0.group == group }
                    if !groupJobs.isEmpty {
                        VStack(alignment: .leading, spacing: spacing.sm) {
                            Text(groupTitle[group] ?? "")
                                .font(.system(size: typeScale.heading, weight: .bold))
                                .foregroundStyle(t.text)
                            ForEach(groupJobs, id: \.navigationKey) { job in
                                JobCard(job: job, onOpen: onOpenJob, theme: t)
                            }
                        }
                    }
                }
            }
        }
        .padding(spacing.lg)
    }
}

private struct JobCard: View {
    var job: JobListItem
    var onOpen: ((String) -> Void)?
    var theme: Theme

    var body: some View {
        let t = theme
        Card(testID: "job-card-\(job.serviceRecord)", theme: t) {
            Text("SR \(job.serviceRecord)")
                .font(.system(size: typeScale.label, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(t.textMuted)
            Text(job.customer)
                .font(.system(size: typeScale.heading, weight: .heavy))
                .foregroundStyle(t.text)
            Text(job.lease)
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            Text(job.well)
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            Text(job.jobType)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(t.textMuted)

            VStack(spacing: spacing.xs) {
                StatusRow(label: "JHA/JSA", value: job.jhaStatus, theme: t)
                StatusRow(label: "Field Ticket", value: job.ticketStatus, theme: t)
                StatusRow(label: "Sync", value: job.syncStatus, theme: t)
            }
            .padding(.vertical, spacing.xs)

            FieldButton(
                label: job.primaryLabel.rawValue,
                onPress: { onOpen?(job.navigationKey) },
                disabled: onOpen == nil,
                testID: "job-open-\(job.serviceRecord)",
                theme: t
            )
        }
    }
}

private struct StatusRow: View {
    var label: String
    var value: JobStatusLabel
    var theme: Theme

    var body: some View {
        let t = theme
        HStack {
            Text(label)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(t.textMuted)
            Spacer()
            StatusBadge(label: value.rawValue, tone: statusTone(value))
        }
    }
}

/* ================================================================== *
 * 28. Job Overview — the job command center
 * ================================================================== */

struct JobIdentity {
    var serviceRecord: String
    var customer: String
    var lease: String
    var well: String
    var jobType: String
    var truck: String
    var trailer: String
    var destination: String
}

#if DEBUG
    private let sampleIdentity = JobIdentity(
        serviceRecord: "2026-000001",
        customer: "Acme Energy, LLC",
        lease: "Northfield Lease",
        well: "Northfield 06H",
        jobType: "Produced Water Haul",
        truck: "Truck 7",
        trailer: "Vacuum Trailer 19",
        destination: "Falcon SWD #2"
    )
#endif

enum JobFlowState: String {
    case complete
    case current
    case locked
}

struct JobFlowStep {
    var key: String
    var label: String
    var state: JobFlowState
}

private struct FlowBadge {
    var label: JobStatusLabel
    var tone: Tone
}

private let flowBadge: [JobFlowState: FlowBadge] = [
    .complete: FlowBadge(label: .complete, tone: .success),
    .current: FlowBadge(label: .required, tone: .warning),
    .locked: FlowBadge(label: .locked, tone: .neutral),
]

#if DEBUG
    private let sampleFlow: [JobFlowStep] = [
        JobFlowStep(key: "sops", label: "Review Job SOPs", state: .current),
        JobFlowStep(key: "jha", label: "Complete JHA/JSA", state: .locked),
        JobFlowStep(key: "ticket", label: "Complete Field Ticket", state: .locked),
    ]
#endif

/// Job menu rows (the overflow menu). Each maps to a callback the host wires up.
enum JobMenuKey: String {
    case details
    case sops
    case emergency
    case directions
    case dispatch
    case evidence
    case print
    case stopWork = "stop-work"
}

private struct JobMenuRow {
    var key: JobMenuKey
    var label: String
    var danger: Bool = false
}

private let jobMenu: [JobMenuRow] = [
    JobMenuRow(key: .details, label: "Job Details"),
    JobMenuRow(key: .sops, label: "Job SOPs"),
    JobMenuRow(key: .emergency, label: "Emergency Info"),
    JobMenuRow(key: .directions, label: "Directions"),
    JobMenuRow(key: .dispatch, label: "Contact Dispatch"),
    JobMenuRow(key: .print, label: "Print"),
    JobMenuRow(key: .stopWork, label: "Stop Work / Report Concern", danger: true),
]

/// Driver-facing label for the single biggest next action.
enum JobOverviewPrimaryLabel: String {
    case startJhaJsa = "Start JHA/JSA"
    case startFieldTicket = "Start Field Ticket"
    case reviewJob = "Review Job"
}

struct JobWorkStartStatus {
    var label: String
    var tone: Tone
}

struct JobOverviewScreen: View {
    var job: JobIdentity?
    var flow: [JobFlowStep]?
    var primaryLabel: JobOverviewPrimaryLabel?
    var onPrimary: (() -> Void)?
    var onStartWork: (() async -> Void)?
    var workStartStatus: JobWorkStartStatus?
    var onAddEvidence: (() -> Void)?
    var onCaptureGps: (() -> Void)?
    var onAddReceipt: (() -> Void)?
    var onPrintTicket: (() -> Void)?
    var onEmergencyInfo: (() -> Void)?
    var onStopWork: (() -> Void)?
    var onMenu: ((JobMenuKey) -> Void)?
    var theme: Theme?

    init(
        job: JobIdentity? = nil,
        flow: [JobFlowStep]? = nil,
        primaryLabel: JobOverviewPrimaryLabel? = nil,
        onPrimary: (() -> Void)? = nil,
        onStartWork: (() async -> Void)? = nil,
        workStartStatus: JobWorkStartStatus? = nil,
        onAddEvidence: (() -> Void)? = nil,
        onCaptureGps: (() -> Void)? = nil,
        onAddReceipt: (() -> Void)? = nil,
        onPrintTicket: (() -> Void)? = nil,
        onEmergencyInfo: (() -> Void)? = nil,
        onStopWork: (() -> Void)? = nil,
        onMenu: ((JobMenuKey) -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.job = job
        self.flow = flow
        self.primaryLabel = primaryLabel
        self.onPrimary = onPrimary
        self.onStartWork = onStartWork
        self.workStartStatus = workStartStatus
        self.onAddEvidence = onAddEvidence
        self.onCaptureGps = onCaptureGps
        self.onAddReceipt = onAddReceipt
        self.onPrintTicket = onPrintTicket
        self.onEmergencyInfo = onEmergencyInfo
        self.onStopWork = onStopWork
        self.onMenu = onMenu
        self.theme = theme
    }

    @Environment(\.fieldTheme) private var envTheme

    // Supporting actions navigate to their real panels (Evidence / Receipt / Print); they are no
    // longer local-counter stubs. GPS is captured automatically in the background, not on a button.
    @State private var activeMenu: JobMenuKey?

    private var renderedJob: JobIdentity? {
        #if DEBUG
            job ?? sampleIdentity
        #else
            job
        #endif
    }

    private var renderedFlow: [JobFlowStep]? {
        #if DEBUG
            flow ?? sampleFlow
        #else
            flow
        #endif
    }

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            job == nil || flow == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme
        let flowValue = renderedFlow ?? []
        let primary = primaryLabel ?? .startJhaJsa

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job Overview")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            if let jobValue = renderedJob {
                Card(testID: "job-overview-identity", theme: t) {
                    Text("SR \(jobValue.serviceRecord)")
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(t.textMuted)
                    Text(jobValue.customer)
                        .font(.system(size: typeScale.heading, weight: .heavy))
                        .foregroundStyle(t.text)
                    Text(jobValue.lease)
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text(jobValue.well)
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text(jobValue.jobType)
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                    Rectangle()
                        .fill(Color.black.opacity(Double(0x1A) / 255.0))
                        .frame(height: 0.5)
                        .padding(.vertical, spacing.xs)
                    Text("\(jobValue.truck) \u{00B7} \(jobValue.trailer)")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text("Destination: \(jobValue.destination)")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            } else {
                JobDataUnavailable(
                    title: "Job unavailable",
                    message:
                        "This assignment is no longer available on the phone. Return to Jobs and refresh from the Hub.",
                    testID: "job-overview-unavailable",
                    theme: t
                )
            }

            Card(title: "Required job flow", tone: .highlight, testID: "job-flow", theme: t) {
                if renderedFlow == nil {
                    Text("Workflow requirements were not provided for this assignment.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                }
                ForEach(Array(flowValue.enumerated()), id: \.element.key) { i, step in
                    let badge = flowBadge[step.state]
                    HStack(spacing: spacing.sm) {
                        Text("\(i + 1).")
                            .font(.system(size: typeScale.body, weight: .bold))
                            .foregroundStyle(t.textMuted)
                            .frame(width: 22)
                        Text(step.label)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StatusBadge(label: badge?.label.rawValue ?? "", tone: badge?.tone ?? .neutral)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("job-flow-\(step.key)")
                }
                FieldButton(
                    label: primary.rawValue,
                    onPress: { onPrimary?() },
                    disabled: onPrimary == nil,
                    testID: "job-primary",
                    theme: t
                )
                FieldButton(
                    label: "Start Work",
                    onPress: { Task { await onStartWork?() } },
                    variant: .secondary,
                    disabled: onStartWork == nil,
                    testID: "job-start-work",
                    theme: t
                )
                if let workStartStatus {
                    StatusBadge(
                        label: workStartStatus.label, tone: workStartStatus.tone, testID: "job-work-start-status")
                }
            }

            Card(title: "Supporting actions", theme: t) {
                FieldButton(
                    label: "Add Evidence",
                    onPress: { onAddEvidence?() },
                    variant: .secondary,
                    disabled: onAddEvidence == nil,
                    testID: "job-add-evidence",
                    theme: t
                )
                FieldButton(
                    label: "Add Receipt",
                    onPress: { onAddReceipt?() },
                    variant: .secondary,
                    disabled: onAddReceipt == nil,
                    testID: "job-add-receipt",
                    theme: t
                )
                FieldButton(
                    label: "Print Ticket",
                    onPress: { onPrintTicket?() },
                    variant: .secondary,
                    disabled: onPrintTicket == nil,
                    testID: "job-print-ticket",
                    theme: t
                )
                FieldButton(
                    label: "Emergency Info",
                    onPress: { onEmergencyInfo?() },
                    variant: .secondary,
                    disabled: onEmergencyInfo == nil,
                    testID: "job-emergency-info",
                    theme: t
                )
                FieldButton(
                    label: "Stop Work / Report Concern",
                    onPress: { onStopWork?() },
                    variant: .destructive,
                    disabled: onStopWork == nil,
                    testID: "job-stop-work",
                    theme: t
                )
                Text("GPS validation is captured from the Location panel when required.")
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.textMuted)
                    .accessibilityIdentifier("job-gps-auto")
            }

            Card(title: "Job menu", theme: t) {
                ForEach(jobMenu, id: \.key) { row in
                    let active = row.key == activeMenu
                    Button(action: {
                        activeMenu = row.key
                        onMenu?(row.key)
                    }) {
                        HStack {
                            Text(row.label)
                                .font(.system(size: typeScale.body, weight: .semibold))
                                .foregroundStyle(row.danger ? t.danger : t.text)
                            Spacer()
                            Text("\u{203A}")
                                .font(.system(size: typeScale.heading, weight: .bold))
                                .foregroundStyle(t.textMuted)
                        }
                        .padding(.horizontal, spacing.sm)
                        .frame(minHeight: sizing.minTouchTarget)
                        .background(active ? t.cardMuted : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: sizing.radius)
                                .stroke(active ? t.primary : t.border, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    }
                    .buttonStyle(ChipPressStyle())
                    .disabled(onMenu == nil)
                    .accessibilityLabel(row.label)
                    .accessibilityIdentifier("job-menu-\(row.key.rawValue)")
                }
            }
        }
        .padding(spacing.lg)
    }
}

/* ================================================================== *
 * 29. Job Details — full job sheet, driver-facing fields only
 * ================================================================== */

struct JobDetails {
    var serviceRecord: String
    var customer: String
    var lease: String
    var well: String
    var county: String
    var material: String
    var jobType: String
    var truck: String
    var trailer: String
    var driver: String
    var destination: String
    var orderedBy: String
    var dispatchNotes: String
    var customerNotes: String
}

#if DEBUG
    private let sampleDetails = JobDetails(
        serviceRecord: "2026-000001",
        customer: "Acme Energy, LLC",
        lease: "Northfield Lease",
        well: "Northfield 06H",
        county: "Reeves County, TX",
        material: "Produced Water",
        jobType: "Produced Water Haul",
        truck: "Truck 7",
        trailer: "Vacuum Trailer 19",
        driver: "You",
        destination: "Falcon SWD #2",
        orderedBy: "Dispatch \u{2014} Acme Oilfield",
        dispatchNotes: "Load at the Northfield 06H tank battery. Gate code on the Emergency Info screen.",
        customerNotes: "Check in with the company man before backing to the tanks."
    )
#endif

struct JobDetailsScreen: View {
    var details: JobDetails?
    var theme: Theme?

    init(details: JobDetails? = nil, theme: Theme? = nil) {
        self.details = details
        self.theme = theme
    }

    @Environment(\.fieldTheme) private var envTheme

    private var renderedDetails: JobDetails? {
        #if DEBUG
            details ?? sampleDetails
        #else
            details
        #endif
    }

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            details == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job Details")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            if let d = renderedDetails {
                let rows: [(label: String, value: String)] = [
                    (label: "Service Record", value: "SR \(d.serviceRecord)"),
                    (label: "Customer", value: d.customer),
                    (label: "Lease", value: d.lease),
                    (label: "Well", value: d.well),
                    (label: "County", value: d.county),
                    (label: "Material", value: d.material),
                    (label: "Job Type", value: d.jobType),
                    (label: "Truck", value: d.truck),
                    (label: "Trailer", value: d.trailer),
                    (label: "Driver", value: d.driver),
                    (label: "Destination / SWD", value: d.destination),
                    (label: "Ordered By", value: d.orderedBy),
                ]

                Card(title: "Job information", theme: t) {
                    ForEach(rows, id: \.label) { r in
                        DetailRow(label: r.label, value: r.value, theme: t)
                    }
                }

                Card(title: "Dispatch Notes", theme: t) {
                    Text(d.dispatchNotes)
                        .font(.system(size: typeScale.body))
                        .lineSpacing(3)
                        .foregroundStyle(t.text)
                }

                Card(title: "Customer Notes", theme: t) {
                    Text(d.customerNotes)
                        .font(.system(size: typeScale.body))
                        .lineSpacing(3)
                        .foregroundStyle(t.text)
                }
            } else {
                JobDataUnavailable(
                    title: "Job details unavailable",
                    message:
                        "The Hub did not provide details for this assignment. Return to Jobs and refresh before relying on this screen.",
                    testID: "job-details-unavailable",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

private struct DetailRow: View {
    var label: String
    var value: String
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: typeScale.caption, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.textMuted)
            Text(value)
                .font(.system(size: typeScale.body, weight: .semibold))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("detail-\(label)")
    }
}

/* ================================================================== *
 * 30. Job SOPs — SOPs relevant to this job
 * ================================================================== */

enum SopSection: String {
    case required
    case recommended
    case emergency
    case siteRules = "site-rules"
}

enum SopAckStatus: String {
    case acknowledged = "Acknowledged"
    case reviewRequired = "Review Required"
    case notStarted = "Not Started"
}

struct JobSopItem {
    var key: String
    var title: String
    var role: String
    var availableOffline: Bool
    var status: SopAckStatus
    var section: SopSection
}

private let sopSectionTitle: [SopSection: String] = [
    .required: "Required Before Work",
    .recommended: "Recommended for This Job",
    .emergency: "Emergency SOPs",
    .siteRules: "Customer / Site Rules",
]

private let sopSectionOrder: [SopSection] = [.required, .recommended, .emergency, .siteRules]

private let sopAckTone: [SopAckStatus: Tone] = [
    .acknowledged: .success,
    .reviewRequired: .warning,
    .notStarted: .neutral,
]

#if DEBUG
    private let sampleSops: [JobSopItem] = [
        JobSopItem(
            key: "loading",
            title: "Vacuum Truck Loading and Unloading",
            role: "Driver Role",
            availableOffline: true,
            status: .reviewRequired,
            section: .required
        ),
        JobSopItem(
            key: "h2s",
            title: "H2S Awareness and Response",
            role: "Driver Role",
            availableOffline: true,
            status: .acknowledged,
            section: .required
        ),
        JobSopItem(
            key: "backing",
            title: "Safe Backing and Spotting",
            role: "Driver Role",
            availableOffline: true,
            status: .acknowledged,
            section: .recommended
        ),
        JobSopItem(
            key: "spill",
            title: "Spill Response and Containment",
            role: "Driver Role",
            availableOffline: true,
            status: .acknowledged,
            section: .emergency
        ),
        JobSopItem(
            key: "site",
            title: "Acme Energy Site Access Rules",
            role: "Site Rule",
            availableOffline: true,
            status: .reviewRequired,
            section: .siteRules
        ),
    ]
#endif

struct JobSopsScreen: View {
    var sops: [JobSopItem]?
    var onOpenSop: ((String) -> Void)?
    var theme: Theme?

    init(sops: [JobSopItem]? = nil, onOpenSop: ((String) -> Void)? = nil, theme: Theme? = nil) {
        self.sops = sops
        self.onOpenSop = onOpenSop
        self.theme = theme
    }

    @Environment(\.fieldTheme) private var envTheme

    // Track which SOPs the driver has opened on this phone so a tap visibly flips
    // the status to "Acknowledged" in the debug gallery. Production requires a host callback.
    @State private var opened: [String: Bool] = [:]

    private var renderedSops: [JobSopItem]? {
        #if DEBUG
            sops ?? sampleSops
        #else
            sops
        #endif
    }

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            sops == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme
        let sopsValue = renderedSops ?? []

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            if renderedSops == nil {
                JobDataUnavailable(
                    title: "Job SOPs unavailable",
                    message:
                        "No authoritative SOP list is attached to this assignment. Use only verified company procedures and refresh from the Hub.",
                    testID: "job-sops-unavailable",
                    theme: t
                )
            }

            ForEach(sopSectionOrder, id: \.self) { section in
                let items = sopsValue.filter { $0.section == section }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: spacing.sm) {
                        Text(sopSectionTitle[section] ?? "")
                            .font(.system(size: typeScale.heading, weight: .bold))
                            .foregroundStyle(t.text)
                        ForEach(items, id: \.key) { sop in
                            let isOpened = opened[sop.key] == true
                            let status: SopAckStatus = isOpened ? .acknowledged : sop.status
                            let reviewNeeded = status == .reviewRequired

                            Card(testID: "sop-\(sop.key)", theme: t) {
                                Text(sop.title)
                                    .font(.system(size: typeScale.heading, weight: .heavy))
                                    .foregroundStyle(t.text)
                                Text(sop.role)
                                    .font(.system(size: typeScale.label, weight: .semibold))
                                    .foregroundStyle(t.textMuted)
                                if sop.availableOffline {
                                    Text("Available Offline")
                                        .font(.system(size: typeScale.label))
                                        .foregroundStyle(t.textMuted)
                                }
                                HStack(spacing: spacing.sm) {
                                    Text("Status")
                                        .font(.system(size: typeScale.label, weight: .semibold))
                                        .foregroundStyle(t.textMuted)
                                    StatusBadge(label: status.rawValue, tone: sopAckTone[status] ?? .neutral)
                                }
                                FieldButton(
                                    label: reviewNeeded ? "Review Required" : (isOpened ? "Opened" : "Open SOP"),
                                    onPress: {
                                        if let onOpenSop {
                                            opened[sop.key] = true
                                            onOpenSop(sop.key)
                                        } else if isShowingDebugFixture {
                                            opened[sop.key] = true
                                        }
                                    },
                                    variant: reviewNeeded ? .primary : .secondary,
                                    disabled: onOpenSop == nil && !isShowingDebugFixture,
                                    testID: "sop-open-\(sop.key)",
                                    theme: t
                                )
                            }
                        }
                    }
                }
            }

            if renderedSops != nil, onOpenSop == nil, !isShowingDebugFixture {
                Text("Opening SOP documents is not configured for this job.")
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.textMuted)
                    .accessibilityIdentifier("job-sops-actions-unavailable")
            }
        }
        .padding(spacing.lg)
    }
}

/* ================================================================== *
 * 31. Emergency Info — fast-access emergency details (maps to JHA/JSA)
 * ================================================================== */

struct EmergencyInfo {
    var emergencyContact: String
    var siteContact: String
    var customerSafetyContact: String
    var nearestHospital: String
    var musterPoint: String
    var spillResponseContact: String
    var h2sEmergencyContact: String
    var access911: String
    var gateCodes: String
}

#if DEBUG
    private let sampleEmergency = EmergencyInfo(
        emergencyContact: "Acme Oilfield Dispatch \u{00B7} (432) 555-0142",
        siteContact: "Company Man \u{2014} Northfield 06H \u{00B7} (432) 555-0188",
        customerSafetyContact: "Acme Energy HSE \u{00B7} (432) 555-0107",
        nearestHospital: "Pecos Valley Medical Center \u{00B7} 14 mi NE",
        musterPoint: "North gate, by the lease entrance sign",
        spillResponseContact: "Field Spill Response \u{00B7} (432) 555-0150",
        h2sEmergencyContact: "Site H2S Safety \u{00B7} (432) 555-0199",
        access911: "Give lease name \u{201C}Northfield 06H\u{201D} and the gate GPS to the 911 operator.",
        gateCodes: "Main gate code 4417. Follow the caliche lease road 1.2 mi to the tank battery."
    )
#endif

struct EmergencyInfoScreen: View {
    var info: EmergencyInfo?
    var onCallEmergencyContact: (() -> Void)?
    var onCallDispatch: (() -> Void)?
    var onOpenDirections: (() -> Void)?
    var onViewEmergencySops: (() -> Void)?
    var theme: Theme?

    init(
        info: EmergencyInfo? = nil,
        onCallEmergencyContact: (() -> Void)? = nil,
        onCallDispatch: (() -> Void)? = nil,
        onOpenDirections: (() -> Void)? = nil,
        onViewEmergencySops: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.info = info
        self.onCallEmergencyContact = onCallEmergencyContact
        self.onCallDispatch = onCallDispatch
        self.onOpenDirections = onOpenDirections
        self.onViewEmergencySops = onViewEmergencySops
        self.theme = theme
    }

    @Environment(\.fieldTheme) private var envTheme

    // Inline confirmation for the placeholder actions (dialing / maps are wired
    // elsewhere). Buttons without a real callback are disabled outside the debug gallery.
    @State private var actionNote: String?

    private var renderedInfo: EmergencyInfo? {
        #if DEBUG
            info ?? sampleEmergency
        #else
            info
        #endif
    }

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            info == nil
        #else
            false
        #endif
    }

    private var hasAnyAction: Bool {
        isShowingDebugFixture || onCallEmergencyContact != nil || onCallDispatch != nil || onOpenDirections != nil
            || onViewEmergencySops != nil
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Emergency Info")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            if let infoValue = renderedInfo {
                let rows: [(label: String, value: String)] = [
                    (label: "Emergency Contact", value: infoValue.emergencyContact),
                    (label: "Site Contact / Company Man", value: infoValue.siteContact),
                    (label: "Customer Safety Contact", value: infoValue.customerSafetyContact),
                    (label: "Nearest Hospital / Clinic", value: infoValue.nearestHospital),
                    (label: "Muster Point", value: infoValue.musterPoint),
                    (label: "Spill Response Contact", value: infoValue.spillResponseContact),
                    (label: "H2S Emergency Contact", value: infoValue.h2sEmergencyContact),
                    (label: "911 Access Instructions", value: infoValue.access911),
                    (label: "Gate Codes / Lease Road Directions", value: infoValue.gateCodes),
                ]

                Card(tone: .highlight, theme: t) {
                    Text(
                        "In an emergency, stop work and make the area safe first, then use these contacts. This information comes from the job\u{2019}s JHA/JSA emergency section."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                }

                Card(title: "Emergency details", theme: t) {
                    ForEach(rows, id: \.label) { r in
                        DetailRow(label: r.label, value: r.value, theme: t)
                    }
                }

                if hasAnyAction {
                    Card(title: "Actions", theme: t) {
                        FieldButton(
                            label: "Call Emergency Contact",
                            onPress: {
                                if let onCallEmergencyContact {
                                    actionNote = "Opening the emergency contact\u{2026}"
                                    onCallEmergencyContact()
                                } else if isShowingDebugFixture {
                                    actionNote = "Preview only \u{2014} no call was placed."
                                }
                            },
                            disabled: onCallEmergencyContact == nil && !isShowingDebugFixture,
                            testID: "emergency-call-contact",
                            theme: t
                        )
                        FieldButton(
                            label: "Call Dispatch",
                            onPress: {
                                if let onCallDispatch {
                                    actionNote = "Opening the dispatch contact\u{2026}"
                                    onCallDispatch()
                                } else if isShowingDebugFixture {
                                    actionNote = "Preview only \u{2014} no call was placed."
                                }
                            },
                            variant: .secondary,
                            disabled: onCallDispatch == nil && !isShowingDebugFixture,
                            testID: "emergency-call-dispatch",
                            theme: t
                        )
                        FieldButton(
                            label: "Open Directions",
                            onPress: {
                                if let onOpenDirections {
                                    actionNote = "Opening directions\u{2026}"
                                    onOpenDirections()
                                } else if isShowingDebugFixture {
                                    actionNote = "Preview only \u{2014} directions were not opened."
                                }
                            },
                            variant: .secondary,
                            disabled: onOpenDirections == nil && !isShowingDebugFixture,
                            testID: "emergency-directions",
                            theme: t
                        )
                        FieldButton(
                            label: "View Emergency SOPs",
                            onPress: {
                                if let onViewEmergencySops {
                                    actionNote = "Opening emergency SOPs\u{2026}"
                                    onViewEmergencySops()
                                } else if isShowingDebugFixture {
                                    actionNote = "Preview only \u{2014} no SOP was opened."
                                }
                            },
                            variant: .secondary,
                            disabled: onViewEmergencySops == nil && !isShowingDebugFixture,
                            testID: "emergency-sops",
                            theme: t
                        )
                        if let actionNote {
                            Text(actionNote)
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.info)
                                .accessibilityIdentifier("emergency-action-status")
                        }
                    }
                } else {
                    JobDataUnavailable(
                        title: "Contact actions unavailable",
                        message:
                            "This screen has no verified phone or directions actions. Use the authoritative contact details above through your normal device tools.",
                        testID: "emergency-actions-unavailable",
                        theme: t
                    )
                }
            } else {
                JobDataUnavailable(
                    title: "Emergency information unavailable",
                    message:
                        "The Hub did not provide verified emergency contacts, hospital, muster point, or site access details for this job. Stop work and use your verified company emergency process.",
                    testID: "emergency-info-unavailable",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ================================================================== *
 * 32. Stop Work / Report Concern — stop-work authority made visible
 * ================================================================== */

enum StopWorkTrigger: String, CaseIterable {
    case h2sAlarm = "H2S Alarm"
    case uncontrolledLeakOrSpill = "Uncontrolled Leak or Spill"
    case fire = "Fire"
    case lightning = "Lightning"
    case heatIllnessSymptoms = "Heat Illness Symptoms"
    case failedEquipment = "Failed Equipment"
    case unsafeRoadCondition = "Unsafe Road Condition"
    case missingPPE = "Missing PPE"
    case unsafeBackingCondition = "Unsafe Backing Condition"
    case workerConcern = "Worker Concern"
    case other = "Other"
}

private let stopWorkTriggers: [StopWorkTrigger] = StopWorkTrigger.allCases

struct StopWorkReport {
    var trigger: StopWorkTrigger
    var description: String
    var notifyDispatch: Bool
}

struct StopWorkScreen: View {
    var triggers: [StopWorkTrigger]?
    /// Whether a GPS fix has already been captured for this report.
    var gpsCaptured: Bool?
    var gpsLabel: String?
    /// Number of photos already attached to this report.
    var photoCount: Int?
    var onAddPhoto: (() -> Void)?
    var onCaptureGps: (() -> Void)?
    var onReportConcern: ((StopWorkReport) -> Void)?
    var onCallEmergencyContact: (() -> Void)?
    var theme: Theme?

    init(
        triggers: [StopWorkTrigger]? = nil,
        gpsCaptured: Bool? = nil,
        gpsLabel: String? = nil,
        photoCount: Int? = nil,
        onAddPhoto: (() -> Void)? = nil,
        onCaptureGps: (() -> Void)? = nil,
        onReportConcern: ((StopWorkReport) -> Void)? = nil,
        onCallEmergencyContact: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.triggers = triggers
        self.gpsCaptured = gpsCaptured
        self.gpsLabel = gpsLabel
        self.photoCount = photoCount
        self.onAddPhoto = onAddPhoto
        self.onCaptureGps = onCaptureGps
        self.onReportConcern = onReportConcern
        self.onCallEmergencyContact = onCallEmergencyContact
        self.theme = theme
        // Self-managing evidence/GPS seeded from the optional props so taps visibly respond.
        _gpsCapturedState = State(initialValue: gpsCaptured ?? false)
        _photoCountState = State(initialValue: photoCount ?? 0)
    }

    @Environment(\.fieldTheme) private var envTheme

    @State private var selected: StopWorkTrigger?
    @State private var description: String = ""
    @State private var notifyDispatch: Bool = true
    // Named distinctly from the `gpsCaptured` / `photoCount` props they're seeded from: the TS
    // source shadows the prop name with the local `useState` binding, which Swift can't do for two
    // stored properties on the same struct.
    @State private var gpsCapturedState: Bool
    @State private var photoCountState: Int
    @State private var emergencyNote: String?

    private var isShowingDebugFixture: Bool {
        #if DEBUG
            onAddPhoto == nil && onCaptureGps == nil && onReportConcern == nil && onCallEmergencyContact == nil
        #else
            false
        #endif
    }

    private var canPresentReportForm: Bool {
        onReportConcern != nil || isShowingDebugFixture
    }

    var body: some View {
        let t = theme ?? envTheme
        let triggersValue = triggers ?? stopWorkTriggers
        let canReport = selected != nil && canPresentReportForm

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Stop Work / Report Concern")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingDebugFixture {
                DebugJobFixtureNotice(theme: t)
            }

            Card(tone: .highlight, theme: t) {
                Text("You have stop-work authority.")
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(t.text)
                Text(
                    "If a job is unsafe, stop work and make the area safe first. Report the concern through a verified company channel before work resumes."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                if onCallEmergencyContact != nil || isShowingDebugFixture {
                    FieldButton(
                        label: "Call Emergency Contact",
                        onPress: {
                            if let onCallEmergencyContact {
                                emergencyNote = "Opening the emergency contact\u{2026}"
                                onCallEmergencyContact()
                            } else if isShowingDebugFixture {
                                emergencyNote = "Preview only \u{2014} no call was placed."
                            }
                        },
                        variant: .destructive,
                        testID: "stopwork-call-emergency",
                        theme: t
                    )
                } else {
                    Text(
                        "No verified emergency call action is configured for this job. Use your company emergency process."
                    )
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.danger)
                }
                if let emergencyNote {
                    Text(emergencyNote)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.danger)
                        .accessibilityIdentifier("stopwork-call-emergency-status")
                }
            }

            if canPresentReportForm {
                Card(title: "Concern Type", theme: t) {
                    FlowLayout(spacing: spacing.xs) {
                        ForEach(triggersValue, id: \.self) { trigger in
                            let isSelected = trigger == selected
                            Button(action: { selected = trigger }) {
                                Text(trigger.rawValue)
                                    .font(.system(size: typeScale.label, weight: .bold))
                                    .foregroundStyle(isSelected ? t.onPrimary : t.text)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: sizing.minTouchTarget)
                                    .background(isSelected ? t.danger : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isSelected ? t.danger : t.border, lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(trigger.rawValue)
                            .accessibilityIdentifier("stopwork-trigger-\(trigger.rawValue)")
                        }
                    }
                }

                Card(title: "Description", theme: t) {
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("Describe what you saw and what you did to make it safe.")
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.textMuted)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $description)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                            .scrollContentBackground(.hidden)
                    }
                    .padding(spacing.sm)
                    .frame(minHeight: 96)
                    .background(t.cardMuted)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(t.border, lineWidth: 1)
                    )
                    .accessibilityIdentifier("stopwork-description")
                }

                Card(title: "Evidence", theme: t) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.black.opacity(Double(0x2A) / 255.0))
                        Text(
                            photoCountState == 0
                                ? "No photo added yet."
                                : "\(photoCountState) photo\(photoCountState == 1 ? "" : "s") added."
                        )
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                    }
                    .frame(minHeight: 96)
                    .padding(spacing.md)

                    FieldButton(
                        label: "Add Photo",
                        onPress: {
                            if let onAddPhoto {
                                photoCountState += 1
                                onAddPhoto()
                            } else if isShowingDebugFixture {
                                photoCountState += 1
                            }
                        },
                        variant: .secondary,
                        disabled: onAddPhoto == nil && !isShowingDebugFixture,
                        testID: "stopwork-add-photo",
                        theme: t
                    )

                    HStack {
                        Text("GPS Capture")
                            .font(.system(size: typeScale.label, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                        Spacer()
                        StatusBadge(
                            label: gpsCapturedState ? "Synced" : "Not Started",
                            tone: gpsCapturedState ? .success : .neutral
                        )
                    }

                    if gpsCapturedState {
                        Text(gpsLabel ?? "Location captured on this phone")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }

                    FieldButton(
                        label: gpsCapturedState ? "Recapture GPS" : "GPS Capture",
                        onPress: {
                            if let onCaptureGps {
                                gpsCapturedState = true
                                onCaptureGps()
                            } else if isShowingDebugFixture {
                                gpsCapturedState = true
                            }
                        },
                        variant: .secondary,
                        disabled: onCaptureGps == nil && !isShowingDebugFixture,
                        testID: "stopwork-capture-gps",
                        theme: t
                    )
                }

                Card(title: "Notify Dispatch", theme: t) {
                    Button(action: { notifyDispatch.toggle() }) {
                        HStack {
                            Text("Notify Dispatch right away")
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.text)
                            Spacer()
                            StatusBadge(
                                label: notifyDispatch ? "In Progress" : "Not Started",
                                tone: notifyDispatch ? .info : .neutral
                            )
                        }
                        .padding(.horizontal, spacing.sm)
                        .frame(minHeight: sizing.minTouchTarget)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(t.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Notify Dispatch")
                    .accessibilityValue(notifyDispatch ? "On" : "Off")
                    .accessibilityAddTraits(notifyDispatch ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("stopwork-notify-toggle")
                }

                FieldButton(
                    label: isShowingDebugFixture ? "Preview Report" : "Report Concern",
                    onPress: {
                        guard let selected else { return }
                        onReportConcern?(
                            StopWorkReport(
                                trigger: selected, description: description, notifyDispatch: notifyDispatch))
                    },
                    variant: .destructive,
                    disabled: !canReport,
                    testID: "stopwork-report",
                    theme: t
                )
                if !canReport {
                    Text("Pick a concern type to report.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            } else {
                JobDataUnavailable(
                    title: "Concern reporting unavailable",
                    message:
                        "This job has no connected reporting action. Stop work, make the area safe, and report through your verified company channel. Nothing entered on this screen would be sent.",
                    testID: "stopwork-report-unavailable",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ------------------------------------------------------------------ *
 * Layout helpers
 * ------------------------------------------------------------------ */

/// Pressed-state opacity (0.7), matching the RN job-menu row's `pressed ? styles.menuRowPressed :
/// null` style. Filter/trigger chips and the notify toggle don't apply that in the RN source, so
/// they use plain `.buttonStyle(.plain)` instead.
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for filter/trigger chip rows,
/// mirroring the same `Layout` used for the app-header chip strip. Native `Layout` protocol, no
/// dependency.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth.isFinite ? maxWidth : x
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
