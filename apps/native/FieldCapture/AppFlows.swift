//
//  AppFlows.swift
//  Ported from apps/mobile/App.tsx (tab bodies + in-app wizard flows: Day/PreTrip/PostTrip/JHA,
//  SOPs, Sync, Admin, More). Split out of AppShell.swift for file size only — same source of truth.
//

import Foundation
import FieldAdapters
import FieldContracts
import FieldDomain
import FieldRuntime
import SwiftUI

private enum DayRoute { case home, pretrip, posttrip }

/// Day tab (GUI Master §6–8) — the Day Dashboard plus the in-app inspection flows it launches
/// (Pre-Trip, End Day / Post-Trip). Punching in/out is NOT here: it happens only at the physical
/// Field Time Terminal, so the dashboard shows punch status read-only and offers no punch button.
struct DayTab: View {
    var punchedIn: Bool
    var clockedInSince: String?
    var statusDetail: String?
    var jobsCount: Int
    var completedJobsCount: Int
    var needsReview: Int
    var pendingSync: Int
    var hasAuthoritativeAssignment: Bool
    var checking: Bool
    var onOpenJobs: () -> Void
    var onRefresh: () -> Void
    var onSubmitPreTrip: (DvirSubmissionPayload) async -> SubmitResult
    var onSubmitPostTrip: (DvirSubmissionPayload) async -> SubmitResult
    var driverName: String?
    var truck: String?
    var trailer: String?
    var odometer: String?

    @State private var route: DayRoute = .home

    var body: some View {
        switch route {
        case .pretrip:
            PreTripFlow(
                onExit: { route = .home },
                onDone: onOpenJobs,
                onSubmit: onSubmitPreTrip,
                driverName: driverName,
                truck: truck,
                trailer: trailer,
                odometer: odometer
            )
        case .posttrip:
            PostTripFlow(
                onExit: { route = .home },
                onDone: { route = .home },
                onSubmit: onSubmitPostTrip,
                driverName: driverName,
                truck: truck,
                trailer: trailer,
                odometer: odometer,
                jobsCompleted: completedJobsCount,
                jobsTotal: jobsCount,
                pendingSync: pendingSync
            )
        case .home:
            // Punching is terminal-only: inspections unlock only once the Hub clock gate says
            // punched-in, and when not punched in the primary action re-checks status with the Hub
            // rather than offering a punch.
            DayDashboardScreen(
                punchedIn: punchedIn,
                clockedInSince: clockedInSince,
                statusDetail: statusDetail,
                jobsCount: jobsCount,
                needsReview: needsReview,
                pendingSync: pendingSync,
                timeline: buildWorkdayTimeline(punchedIn: punchedIn, jobsCount: jobsCount),
                checking: checking,
                primaryLabel: punchedIn ? "Open Jobs" : "Check Punch-In Status",
                onPrimary: punchedIn ? onOpenJobs : onRefresh,
                onOpenJobs: onOpenJobs,
                onRefresh: onRefresh,
                onStartPreTrip: punchedIn && hasAuthoritativeAssignment ? { route = .pretrip } : nil,
                onStartPostTrip: punchedIn && hasAuthoritativeAssignment ? { route = .posttrip } : nil
            )
        }
    }
}

/// Driver Pre-Trip DVIR flow (GUI Master §7 / screens 12–17).
struct PreTripFlow: View {
    var onExit: () -> Void
    var onDone: () -> Void
    var onSubmit: (DvirSubmissionPayload) async -> SubmitResult
    var driverName: String?
    var truck: String?
    var trailer: String?
    var odometer: String?

    private enum Route { case overview, section, defect, review, signature, complete }

    @State private var route: Route = .overview
    @State private var msg: SubmitResult?
    @State private var items = defaultPreTripInspectionItems()
    @State private var defects: [String: DvirDefectDraft] = [:]
    @State private var selectedDefectKey: String?
    @State private var defectsCertifiedSafe: Bool?
    @State private var isSubmitting = false
    @Environment(\.fieldTheme) private var t

    private func back() {
        switch route {
        case .overview: onExit()
        case .defect: cancelDefect()
        default: route = .overview
        }
    }

    private var summary: InspectionSummary {
        summarizeInspection(
            items: items,
            results: Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.result) })
        )
    }

    private var defectCount: Int { summary.defectCount }

    private var defectRemarks: String {
        items.compactMap { defects[$0.key]?.note }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var selectedDefect: DvirDefectDraft {
        selectedDefectKey.flatMap { defects[$0] } ?? DvirDefectDraft()
    }

    private var hasUnsafeDefect: Bool {
        items.contains { item in
            item.result == .defect && defects[item.key]?.severity == .unsafe
        }
    }

    private func setResult(_ key: String, _ result: InspectionResult) {
        let previous = items.first(where: { $0.key == key })?.result
        items = items.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.result = result
            return updated
        }
        if previous == .defect || result == .defect {
            defectsCertifiedSafe = nil
        }
        if result != .defect {
            defects.removeValue(forKey: key)
            if !items.contains(where: { $0.result == .defect }) {
                defectsCertifiedSafe = nil
            }
        }
    }

    private func cancelDefect() {
        guard let selectedDefectKey else {
            route = .section
            return
        }
        setResult(selectedDefectKey, .notChecked)
        defects.removeValue(forKey: selectedDefectKey)
        self.selectedDefectKey = nil
        route = .section
    }

    private func submit(_ signature: PreTripSignaturePayload) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let payload = DvirSubmissionPayload(
            signature: signature.signature,
            signerName: signature.signerName,
            items: contractInspectionItems(items, defects: defects),
            defectsCertifiedSafe: defectCount > 0 ? defectsCertifiedSafe : nil
        )
        Task {
            let result = await onSubmit(payload)
            msg = result
            isSubmitting = false
            if result.ok { route = .complete }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: back) {
                Text("‹ Back").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pretrip-back")

            if let msg {
                Text(msg.message)
                    .font(.system(size: typeScale.label, weight: msg.ok ? .bold : .regular))
                    .foregroundStyle(msg.ok ? t.success : t.danger)
            }

            switch route {
            case .overview:
                PreTripOverviewScreen(
                    truck: truck,
                    trailer: trailer,
                    odometerBegin: odometer,
                    onBeginInspection: { route = .section }
                )
            case .section:
                PreTripSectionScreen(
                    items: items,
                    onSetResult: setResult,
                    onOpenDefect: { key in
                        selectedDefectKey = key
                        route = .defect
                    },
                    onContinue: { _ in route = .review }
                )
            case .defect:
                DefectDetailScreen(
                    itemName: items.first(where: { $0.key == selectedDefectKey })?.label,
                    remarks: selectedDefect.note,
                    requiresReview: selectedDefect.requiresReview,
                    showSeverity: true,
                    severity: selectedDefect.severity,
                    photoCount: selectedDefect.photoCount,
                    onSaveDetails: { details in
                        guard let selectedDefectKey else { return }
                        defects[selectedDefectKey] = DvirDefectDraft(
                            note: details.note,
                            requiresReview: details.requiresReview,
                            severity: details.severity,
                            photoCount: details.photoCount
                        )
                        defectsCertifiedSafe = details.severity == .unsafe ? false : nil
                    },
                    onSaveDefect: {
                        selectedDefectKey = nil
                        route = .section
                    },
                    onCancel: cancelDefect
                )
            case .review:
                PreTripReviewScreen(
                    truckChecked: summary.truckChecked,
                    truckTotal: summary.truckTotal,
                    trailerChecked: summary.trailerChecked,
                    trailerTotal: summary.trailerTotal,
                    defectCount: summary.defectCount,
                    remarks: defectRemarks.isEmpty ? "No visible defects" : defectRemarks,
                    defectsCertifiedSafe: defectsCertifiedSafe,
                    safeCertificationAllowed: !hasUnsafeDefect,
                    onChangeDefectsCertifiedSafe: { defectsCertifiedSafe = hasUnsafeDefect ? false : $0 },
                    onContinueToSignature: { route = .signature }
                )
            case .signature:
                PreTripSignatureScreen(
                    driverName: driverName,
                    truck: truck,
                    trailer: trailer,
                    certificationText: DVIR_PRETRIP_CERTIFICATION_TEXT,
                    onCompletePreTrip: submit
                )
            case .complete:
                PreTripCompleteScreen(
                    hasDefects: defectCount > 0,
                    defectCount: defectCount,
                    truck: truck,
                    trailer: trailer,
                    onStartNextJob: onDone
                )
            }
        }
    }
}

/// End Day + Post-Trip DVIR flow (GUI Master §8 / screens 18–23).
struct PostTripFlow: View {
    var onExit: () -> Void
    var onDone: () -> Void
    var onSubmit: (DvirSubmissionPayload) async -> SubmitResult
    var driverName: String?
    var truck: String?
    var trailer: String?
    var odometer: String?
    var jobsCompleted: Int?
    var jobsTotal: Int?
    var pendingSync: Int?

    private enum Route { case endday, overview, section, review, signature, complete }

    @State private var route: Route = .endday
    @State private var msg: SubmitResult?
    @State private var items = defaultPostTripInspectionItems()
    @State private var defectsCertifiedSafe: Bool?
    @State private var isSubmitting = false
    @Environment(\.fieldTheme) private var t

    private func back() {
        if route == .endday { onExit() } else { route = .endday }
    }

    private var defectCount: Int {
        items.filter { $0.result == .defect }.count
    }

    private var defectRemarks: String {
        items.filter { $0.result == .defect }.map { "\($0.label): \($0.note)" }.joined(separator: "\n")
    }

    private var truckItems: [PostTripItem] { items.filter { $0.group == .truck } }
    private var trailerItems: [PostTripItem] { items.filter { $0.group == .trailer } }

    private func setResult(_ key: String, _ result: InspectionResult) {
        let previous = items.first(where: { $0.key == key })?.result
        items = items.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.result = result
            if result != .defect { updated.note = "" }
            return updated
        }
        if previous == .defect || result == .defect {
            defectsCertifiedSafe = nil
        }
        if !items.contains(where: { $0.result == .defect }) {
            defectsCertifiedSafe = nil
        }
    }

    private func setNote(_ key: String, _ note: String) {
        items = items.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.note = note
            return updated
        }
        defectsCertifiedSafe = nil
    }

    private func submit(_ signature: PostTripSignaturePayload) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let payload = DvirSubmissionPayload(
            signature: signature.signature,
            signerName: signature.signerName,
            items: contractInspectionItems(items),
            defectsCertifiedSafe: defectCount > 0 ? defectsCertifiedSafe : nil
        )
        Task {
            let result = await onSubmit(payload)
            msg = result
            isSubmitting = false
            if result.ok { route = .complete }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: back) {
                Text("‹ Back").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("posttrip-back")

            if let msg {
                Text(msg.message)
                    .font(.system(size: typeScale.label, weight: msg.ok ? .bold : .regular))
                    .foregroundStyle(msg.ok ? t.success : t.danger)
            }

            switch route {
            case .endday:
                EndDayReviewScreen(
                    jobsCompleted: jobsCompleted,
                    jobsTotal: jobsTotal,
                    pendingSync: pendingSync,
                    onStartPostTrip: { route = .overview }
                )
            case .overview:
                PostTripOverviewScreen(
                    truck: truck,
                    trailer: trailer,
                    odometerEnd: odometer,
                    onBegin: { route = .section }
                )
            case .section:
                PostTripSectionScreen(
                    sectionTitle: "Vehicle Inspection",
                    sectionIndex: 1,
                    sectionCount: 1,
                    items: items,
                    onChangeItem: setResult,
                    onChangeNote: setNote,
                    onContinue: { route = .review }
                )
            case .review:
                PostTripReviewScreen(
                    truckChecked: truckItems.filter { $0.result != .notChecked }.count,
                    truckTotal: truckItems.count,
                    trailerChecked: trailerItems.filter { $0.result != .notChecked }.count,
                    trailerTotal: trailerItems.count,
                    defects: defectCount,
                    remarks: defectRemarks,
                    defectsCertifiedSafe: defectsCertifiedSafe,
                    onChangeDefectsCertifiedSafe: { defectsCertifiedSafe = $0 },
                    onContinue: { route = .signature }
                )
            case .signature:
                PostTripSignatureScreen(
                    driverName: driverName,
                    certificationText: DVIR_POSTTRIP_CERTIFICATION_TEXT,
                    onComplete: submit
                )
            case .complete:
                PostTripCompleteScreen(defects: defectCount, onDone: onDone)
            }
        }
    }
}

/// JHA/JSA flow (GUI Master §10 / screens 33–43) — the per-job safety review as an 11-step guided
/// wizard reached from Job Overview. A shared back link steps backward (or exits to the job at the
/// first step); Complete hands off to the Field Ticket flow.
struct JhaFlow: View {
    var onExit: () -> Void
    var onStartFieldTicket: () -> Void
    var onSubmit: (JhaSubmissionPayload) async -> SubmitResult
    var driverName: String?
    var srNumber: String? = nil
    var customer: String? = nil
    var lease: String? = nil
    var jobSiteFields: [JhaField]? = nil
    var emergencyFields: [JhaField]? = nil
    var dvirCompleted = false

    @State private var step = 0
    @State private var msg: SubmitResult?
    @State private var preJobGroups = defaultJhaPreJobGroups()
    @State private var ppe = defaultJhaPpe()
    @State private var otherPpe = ""
    @State private var hazards = defaultJhaHazards()
    @State private var jobSteps = defaultJhaJobSteps()
    @State private var stopWorkAcknowledged = false
    @State private var signatures: [SignatureSubmitPayload] = []
    @State private var signaturePeople: [JhaSigner]?
    @State private var capturedSignatures: [String: SignatureValue] = [:]
    @State private var isSubmitting = false
    @Environment(\.fieldTheme) private var t

    private func next() { step += 1 }
    private func back() { if step == 0 { onExit() } else { step -= 1 } }

    private func setPreJobItem(_ groupKey: String, _ itemKey: String, _ ok: Bool) {
        preJobGroups = preJobGroups.map { group in
            guard group.key == groupKey else { return group }
            var updated = group
            updated.items = group.items.map { item in
                guard item.key == itemKey else { return item }
                var updatedItem = item
                updatedItem.ok = ok
                return updatedItem
            }
            return updated
        }
    }

    private func setPpe(_ key: String, _ selected: Bool) {
        ppe = ppe.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.selected = selected
            return updated
        }
    }

    private func setHazard(_ key: String, _ selected: Bool) {
        hazards = hazards.map { hazard in
            guard hazard.key == key else { return hazard }
            var updated = hazard
            updated.selected = selected
            return updated
        }
    }

    private func setJobStep(_ updated: JhaJobStep) {
        jobSteps = jobSteps.map { $0.key == updated.key ? updated : $0 }
    }

    private func submitJha() {
        guard !isSubmitting else { return }
        isSubmitting = true
        let payload = JhaSubmissionPayload(
            hazards: contractJhaHazards(
                preJobGroups: preJobGroups,
                dvirCompleted: dvirCompleted,
                ppe: ppe,
                otherPpe: otherPpe,
                selectedHazards: hazards,
                jobSteps: jobSteps,
                stopWorkAcknowledged: stopWorkAcknowledged
            ),
            signatures: signatures
        )
        Task {
            let result = await onSubmit(payload)
            msg = result
            isSubmitting = false
            if result.ok { step = 10 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: back) {
                Text("‹ Back").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("jha-back")

            if let msg {
                Text(msg.message)
                    .font(.system(size: typeScale.label, weight: msg.ok ? .bold : .regular))
                    .foregroundStyle(msg.ok ? t.success : t.danger)
            }

            switch step {
            case 0:
                JhaOverviewScreen(srNumber: srNumber, customer: customer, lease: lease, onBegin: next)
            case 1:
                JhaJobAndSiteScreen(fields: jobSiteFields, onNext: next)
            case 2:
                JhaEmergencyInfoScreen(fields: emergencyFields, onNext: next)
            case 3:
                JhaPreJobSafetyScreen(
                    groups: preJobGroups,
                    dvirCompleted: dvirCompleted,
                    onSetItemOk: setPreJobItem,
                    onNext: next
                )
            case 4:
                JhaPpeScreen(
                    items: ppe,
                    otherText: otherPpe,
                    onToggle: setPpe,
                    onChangeOther: { otherPpe = $0 },
                    onNext: next
                )
            case 5:
                JhaHazardsScreen(hazards: hazards, onToggle: setHazard, onNext: next)
            case 6:
                JhaJobStepsScreen(steps: jobSteps, onChangeStep: setJobStep, onNext: next)
            case 7:
                JhaStopWorkScreen(
                    acknowledged: stopWorkAcknowledged,
                    onAcknowledge: {
                        stopWorkAcknowledged = true
                        next()
                    }
                )
            case 8:
                JhaSignaturesScreen(
                    driverName: driverName,
                    people: signaturePeople,
                    capturedSignatures: capturedSignatures,
                    onChangeDraft: { people, values in
                        signaturePeople = people
                        capturedSignatures = values
                    },
                    certificationText: JHA_CERTIFICATION_TEXT,
                    onContinue: { payload in
                        signatures = payload.signatures.map {
                            SignatureSubmitPayload(
                                signature: $0.signature, signerName: $0.signerName, signerRole: $0.signerRole)
                        }
                        next()
                    }
                )
            case 9:
                JhaReviewScreen(
                    submitting: isSubmitting,
                    onComplete: submitJha
                )
            case 10:
                JhaCompleteScreen(srNumber: srNumber, onStartFieldTicket: onStartFieldTicket)
            default:
                EmptyView()
            }
        }
    }
}

private enum SopRoute { case list, search }

/// Displays only an authoritative, callback-backed SOP catalog. Until the Hub supplies that data,
/// the runtime presents an explicit unavailable state instead of preview procedures.
struct SopBrowser: View {
    var catalog: [SopSummary]? = nil
    var onOpenSop: ((String) -> Void)? = nil

    @State private var route: SopRoute = .list
    @Environment(\.fieldTheme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            if let catalog, let onOpenSop {
                let searching = route == .search
                FieldButton(
                    label: searching ? "‹ Browse all SOPs" : "Search SOPs",
                    onPress: { route = searching ? .list : .search },
                    variant: .secondary,
                    testID: "sop-search-toggle",
                    theme: t
                )
                if searching {
                    SopSearchScreen(results: catalog, onOpenSop: onOpenSop)
                } else {
                    RequiredDriverSopsScreen(sops: catalog, title: "SOPs", onOpenSop: onOpenSop)
                }
            } else {
                SopCatalogUnavailableScreen(theme: t)
            }
        }
    }
}

struct SopsTab: View {
    var body: some View { SopBrowser() }
}

/// Compatibility route for the retired presentational evidence gallery. Production capture and
/// persistence live in the job's Evidence panel; this route must never imply that placeholder
/// camera, receipt, signature, or print interactions saved work.
struct EvidenceFlow: View {
    var onExit: () -> Void

    @Environment(\.fieldTheme) private var t

    init(onExit: @escaping () -> Void, captureMethod _: TicketCaptureMethod? = nil, jobType _: String? = nil) {
        self.onExit = onExit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: onExit) {
                Text("‹ Back to job").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("evidence-flow-back")

            Card(title: "Evidence gallery unavailable", tone: .highlight, theme: t) {
                Text(
                    "This gallery is not connected to saved job records. Return to the job and open its Evidence panel to capture and save photos or signatures."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            }
        }
    }
}

private enum SyncRoute { case home, pending, failed, detail }

/// Sync tab (GUI Master §14) — plain-English saved/synced status. Home shows the real outbox rollup
/// (pending / failed / synced counts from the durable stores); View Pending / View Failed drill into
/// the item lists. No payloads, queues, acks, or server versions.
struct SyncTab: View {
    var pendingCount: Int
    var failedCount: Int
    var syncedCount: Int
    var offline: Bool
    var lastSyncedAt: String?
    var syncing: Bool
    var pendingItems: [SyncItem]
    var statusError: String? = nil
    var onSyncNow: () -> Void

    @State private var route: SyncRoute = .home
    @State private var selectedItemKey: String?
    @Environment(\.fieldTheme) private var t

    private var overall: SyncOverallState {
        if offline { return .offlineMode }
        if failedCount > 0 { return .syncFailed }
        if pendingCount > 0 { return .pendingSync }
        if syncedCount > 0 { return .allWorkSynced }
        return .savedOnPhone
    }

    private var selectedItem: SyncItem? {
        guard let selectedItemKey else { return nil }
        return pendingItems.first { $0.key == selectedItemKey }
    }

    var body: some View {
        Group {
            if let statusError {
                VStack(alignment: .leading, spacing: spacing.md) {
                    Card(title: "Sync status unavailable", tone: .highlight, theme: t) {
                        Text(statusError)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    }
                    FieldButton(
                        label: syncing ? "Checking…" : "Try Sync Again",
                        onPress: onSyncNow,
                        disabled: syncing,
                        testID: "sync-status-retry",
                        theme: t
                    )
                }
            } else {
                switch route {
                case .home:
                    SyncHomeScreen(
                        overallState: overall, pendingCount: pendingCount, failedCount: failedCount,
                        syncedCount: syncedCount,
                        lastHubContactAt: lastSyncedAt, syncing: syncing, onSyncNow: onSyncNow,
                        onViewPending: { route = .pending }, onViewFailed: { route = .failed }
                    )
                default:
                    VStack(alignment: .leading, spacing: spacing.md) {
                        Button(action: { route = .home }) {
                            Text("‹ Sync").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(
                                t.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sync-back")
                        switch route {
                        case .pending:
                            PendingSyncItemsScreen(
                                items: pendingItems, reportedPendingCount: pendingCount, syncing: syncing,
                                onSyncNow: onSyncNow,
                                onOpenItem: { key in
                                    selectedItemKey = key
                                    route = .detail
                                })
                        case .failed:
                            SyncFailedItemsScreen(
                                items: [], reportedCount: failedCount, onRetry: nil, onViewDetails: nil,
                                onContactSupport: nil, onRetryAll: onSyncNow)
                        case .detail:
                            SyncItemDetailScreen(itemLabel: selectedItem?.label, status: selectedItem?.status)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

private enum AdminRoute { case lock, dash, environment, sync, printer, logs, supervisor, mechanic, override }

/// Admin Mode (GUI Master §16 / screens 84–92) — the protected, non-driver area: PIN lock →
/// dashboard → diagnostics (environment, sync, printer, logs) and the supervisor/mechanic defect
/// chain. This is the ONLY place technical detail is shown, and only after the lock. Diagnostic
/// actions are presentational here; the real device actions wire in as those slices land.
struct AdminFlow: View {
    var envInfo: EnvironmentInfo
    var validatePin: ((String) -> Bool)? = nil
    var onExit: () -> Void

    @State private var route: AdminRoute = .lock
    @Environment(\.fieldTheme) private var t

    var body: some View {
        switch route {
        case .lock:
            VStack(alignment: .leading, spacing: spacing.md) {
                Button(action: onExit) {
                    Text("‹ Back").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("admin-exit")
                if let validatePin {
                    AdminModeLockScreen(
                        onUnlock: { pin in
                            if validatePin(pin) { route = .dash }
                        },
                        onCancel: onExit
                    )
                } else {
                    Card(title: "Admin Mode unavailable", tone: .highlight, theme: t) {
                        Text("This account does not have a Hub-verified Admin Mode capability.")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    }
                }
            }
        case .dash:
            VStack(alignment: .leading, spacing: spacing.md) {
                Button(action: { route = .lock }) {
                    Text("‹ Lock").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("admin-lock")
                AdminDashboardScreen(
                    onOpenSection: { key in
                        switch key {
                        case .sync: route = .sync
                        case .printer: route = .printer
                        case .logs: route = .logs
                        case .role: route = .supervisor
                        default: route = .environment
                        }
                    },
                    onLockAdmin: onExit
                )
            }
        default:
            VStack(alignment: .leading, spacing: spacing.md) {
                Button(action: { route = .dash }) {
                    Text("‹ Admin").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("admin-back")
                switch route {
                case .environment: EnvironmentDetailsScreen(environment: envInfo)
                case .sync: SyncDiagnosticsScreen()
                case .printer: PrinterDiagnosticsScreen()
                case .logs: LogsExportScreen()
                case .supervisor: SupervisorDefectReviewScreen(onDecision: { _ in route = .mechanic })
                case .mechanic: MechanicDefectResolutionScreen(onSelect: { _ in route = .override })
                case .override: SupervisorOverrideScreen(onApply: { _ in route = .dash })
                default: EmptyView()
                }
            }
        }
    }
}

private let DEFAULT_PRINTER_NAME = "PT-210"

struct PrinterUiState {
    var name: String
    var connected: Bool
    var connectionMessage: String
    var actionMessage: String?
    var actionTone: Tone
    var reconnecting: Bool
    var printing: Bool
}

private func defaultPrinterUiState() -> PrinterUiState {
    PrinterUiState(
        name: DEFAULT_PRINTER_NAME,
        connected: false,
        connectionMessage: "Printer not connected. Reconnect when you are near it to print field tickets.",
        actionMessage: nil,
        actionTone: .info,
        reconnecting: false,
        printing: false
    )
}

func printerIsReady(_ status: Pt210Status) -> Bool { status.connected && status.ready }

func printerName(_ status: Pt210Status, _ fallback: String = DEFAULT_PRINTER_NAME) -> String {
    status.deviceName ?? fallback
}

func printerConnectionMessage(_ name: String, _ connected: Bool) -> String {
    connected
        ? "\(name) is connected and ready for field tickets."
        : "Printer not connected. Reconnect when you are near it to print field tickets."
}

func printerStatusActionMessage(_ status: Pt210Status, _ readyMessage: String?) -> String? {
    guard let readyMessage else { return nil }
    if printerIsReady(status) { return readyMessage }
    let name = printerName(status)
    if status.connected { return "\(name) is connected but not ready to print yet." }
    return status.message ?? "Printer is not connected yet."
}

private enum MoreRoute { case home, account, theme, textsize, printer, help, contact, signout, adminlock }

/// More tab (GUI Master §15/§16) — a self-contained settings stack: home menu → the settings
/// sub-pages, plus the Admin lock that gates Environment Details (the technical hub/env info that
/// never appears on driver screens). Theme is app-wide and persisted; unsupported accessibility
/// overrides are disclosed instead of simulated. Sign-out routes to the real controller logout and
/// preserves unsynced work.
struct MoreTab: View {
    var onSignOut: () async throws -> Void
    var onOpenSops: () -> Void
    var punchedIn: Bool
    var syncSummary: String
    var syncTone: Tone
    var driverName: String?
    var driverRole: String?
    var department: String?
    var employeeId: String?
    var phone: String?
    var assignedYard: String?
    var defaultTruck: String?
    var defaultTrailer: String?
    var envInfo: EnvironmentInfo

    @State private var route: MoreRoute = .home
    @State private var printerTransportRef: Pt210PrinterTransport?
    @State private var printerUi: PrinterUiState = defaultPrinterUiState()
    @Environment(\.fieldTheme) private var t

    private func printerTransport() -> Pt210PrinterTransport {
        if let printerTransportRef { return printerTransportRef }
        let created = Pt210PrinterTransport()
        printerTransportRef = created
        return created
    }

    @discardableResult
    private func applyPrinterStatus(_ status: Pt210Status, _ actionMessage: String? = nil) -> Bool {
        let connected = printerIsReady(status)
        let name = printerName(status)
        printerUi.name = name
        printerUi.connected = connected
        printerUi.connectionMessage = printerConnectionMessage(name, connected)
        printerUi.actionMessage = printerStatusActionMessage(status, actionMessage)
        printerUi.actionTone = connected ? .success : .warning
        return connected
    }

    private func refreshPrinterStatus() async {
        do {
            let status = try await printerTransport().status(timeoutMs: 3_000)
            applyPrinterStatus(status)
        } catch {
            let normalized = normalizePt210NativeError(error)
            printerUi.connected = false
            printerUi.connectionMessage = printerConnectionMessage(printerUi.name, false)
            printerUi.actionMessage =
                normalized.code == .printerNotImplemented
                ? "This app build does not include PT-210 printing."
                : normalized.message
            printerUi.actionTone = .warning
        }
    }

    private func connectPrinterToPt210() async -> Bool {
        printerUi.reconnecting = true
        printerUi.actionMessage = "Looking for your printer…"
        printerUi.actionTone = .info
        defer { printerUi.reconnecting = false }

        let transport = printerTransport()

        // Continue into reconnect/discovery on failure — the final catch below surfaces actionable
        // failures.
        if let current = try? await transport.status(timeoutMs: 3_000),
            applyPrinterStatus(current, "\(printerName(current)) is already connected.")
        {
            return true
        }
        // A fresh app launch has no prior device id, so a failed reconnect falls back to discovery.
        if let reconnected = try? await transport.reconnect(timeoutMs: 10_000),
            applyPrinterStatus(reconnected, "Connected to \(printerName(reconnected)).")
        {
            return true
        }

        do {
            let found = try await transport.discover(timeoutMs: 10_000, includeUnpaired: true)
            guard let device = found.first else {
                printerUi.connected = false
                printerUi.connectionMessage = printerConnectionMessage(printerUi.name, false)
                printerUi.actionMessage = "No PT-210 printer found nearby. Make sure it is on and near this phone."
                printerUi.actionTone = .warning
                return false
            }
            try await transport.connect(device.deviceId)
            let connected = try await transport.status(timeoutMs: 3_000)
            let ready = printerIsReady(connected)
            let name = printerName(connected, device.name)
            printerUi.name = name
            printerUi.connected = ready
            printerUi.connectionMessage = printerConnectionMessage(name, ready)
            printerUi.actionMessage = ready ? "Connected to \(name)." : "\(name) was found but is not ready yet."
            printerUi.actionTone = ready ? .success : .warning
            return ready
        } catch {
            let normalized = normalizePt210NativeError(error)
            printerUi.connected = false
            printerUi.connectionMessage = printerConnectionMessage(printerUi.name, false)
            printerUi.actionMessage =
                normalized.code == .printerNotImplemented
                ? "This app build does not include PT-210 printing."
                : normalized.message
            printerUi.actionTone = .danger
            return false
        }
    }

    private func printPrinterTestPage() async {
        printerUi.printing = true
        printerUi.actionMessage = "Printing test page…"
        printerUi.actionTone = .info
        defer { printerUi.printing = false }
        do {
            let transport = printerTransport()
            if !transport.isConnected() {
                let connected = await connectPrinterToPt210()
                guard connected else { return }
            }
            try await transport.writeBytes(try createPt210SignatureBitmapTest())
            if let status = try? await transport.status(timeoutMs: 3_000) {
                applyPrinterStatus(status, "Test page sent to printer.")
            } else {
                printerUi.connected = true
                printerUi.connectionMessage = printerConnectionMessage(printerUi.name, true)
                printerUi.actionMessage = "Test page sent to printer."
                printerUi.actionTone = .success
            }
        } catch {
            let normalized = normalizePt210NativeError(error)
            printerUi.actionMessage = normalized.message
            printerUi.actionTone = .danger
        }
    }

    private func reconnectPrinter() async {
        _ = await connectPrinterToPt210()
    }

    var body: some View {
        Group {
            switch route {
            case .home:
                MoreHomeScreen(
                    driverName: driverName, driverRole: driverRole, department: department,
                    syncSummary: syncSummary, syncTone: syncTone,
                    showAdminMode: false,
                    onOpenAccount: { route = .account },
                    onOpenTheme: { route = .theme },
                    onOpenTextSize: { route = .textsize },
                    onOpenPrinter: { route = .printer },
                    onOpenHelp: { route = .help },
                    onOpenContactDispatch: { route = .contact },
                    onOpenAdminMode: { route = .adminlock },
                    onSignOut: { route = .signout }
                )
            case .adminlock:
                AdminFlow(envInfo: envInfo, onExit: { route = .home })
            default:
                VStack(alignment: .leading, spacing: spacing.md) {
                    Button(action: { route = .home }) {
                        Text("‹ Back").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("more-back")
                    moreDetailContent
                }
            }
        }
        .task(id: route) {
            if route == .printer { await refreshPrinterStatus() }
        }
    }

    @ViewBuilder
    private var moreDetailContent: some View {
        switch route {
        case .account:
            AccountScreen(
                name: driverName, role: driverRole, employeeId: employeeId, phone: phone,
                assignedYard: assignedYard, defaultTruck: defaultTruck, defaultTrailer: defaultTrailer)
        case .theme:
            ThemeScreen()
        case .textsize:
            TextSizeScreen()
        case .printer:
            PrinterSettingsScreen(
                printerName: printerUi.name, connected: printerUi.connected,
                connectionMessage: printerUi.connectionMessage,
                reconnecting: printerUi.reconnecting, printing: printerUi.printing,
                actionMessage: printerUi.actionMessage,
                actionTone: printerUi.actionMessage != nil ? printerUi.actionTone : nil,
                onReconnect: { Task { await reconnectPrinter() } },
                onPrintTestPage: { Task { await printPrinterTestPage() } }
            )
        case .help:
            HelpSupportScreen(onViewSops: onOpenSops, onEmergencyContacts: { route = .contact })
        case .contact:
            ContactDispatchScreen()
        case .signout:
            SignOutConfirmScreen(
                punchedIn: punchedIn, onCancel: { route = .home }, onConfirmSignOut: onSignOut)
        default:
            EmptyView()
        }
    }
}
