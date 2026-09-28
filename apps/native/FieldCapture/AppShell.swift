//
//  AppShell.swift
//  Ported from apps/mobile/App.tsx (app shell: boot machine, tab shell, submit plumbing).
//
//  Every screen state is a member of a finite set — locked (with the reason Hub gave), unlocked,
//  signed-out, or boot-failed. Hub calls underneath are wall-clock-bounded, so "Checking…" always
//  resolves into one of these states; there is no unbounded spinner anywhere.
//
//  Once signed in, the field runtime is a plain state-driven bottom-tab shell (Day / Jobs / SOPs /
//  Sync / More per GUI Master §2) that mounts the built screens — deliberately NOT a navigation-
//  stack, matching the TS source's own state machine. Driver-facing chrome only — env labels, hub
//  URLs, and backend strings never appear in the header (GUI Master §20); they live under More.
//
//  Wizard flows, tabs, and Admin/More live in AppFlows.swift (same port, split for file size).
//

import Foundation
import FieldAdapters
import FieldContracts
import FieldData
import FieldDomain
import FieldRuntime
import SwiftUI
import UIKit

/// UUIDs for locally-authored work (ticket/receipt drafts, location evidence).
let identity = CaptureIdentity(generateUuid: randomUuid)

/// App version for the More screen (from the native bundle).
private let appVersion = nativeAppVersion

/// The native photo/import capture seam CaptureEvidenceScreen drives for non-signature kinds.
let captureEvidenceDevice: CaptureEvidenceDevice = { input in
    let source: EvidenceImageSource
    switch input.source {
    case .camera: source = .camera
    case .importSource: source = .import
    case .signaturePad: return nil
    }
    guard let captured = try await captureEvidenceImage(source) else { return nil }
    return CapturedEvidenceBytes(bytes: captured.bytes, mimeType: captured.mimeType, source: input.source)
}

/// Result of a wizard's "submit" — drives the inline confirmation + whether to advance.
struct SubmitResult {
    var ok: Bool
    var message: String
}

/// Shown when signature capture/persist throws (disk full, permission, I/O) rather than returning a
/// status. The signature is not finalized and the form is not submitted; the inline message keeps the
/// button alive so the driver can retry.
let signatureCaptureFailure = SubmitResult(
    ok: false,
    message: "Could not finalize the signature on this phone. Check storage and try again."
)

func workflowPersistenceFailure(_ workType: String) -> SubmitResult {
    SubmitResult(
        ok: false,
        message: "Could not save the \(workType) on this phone. Check storage and try again."
    )
}

/// Outcome of persisting a captured signature as a blob + building its SignatureRecord.
enum SignatureRecordResult {
    case ok(record: SignatureRecord)
    case locked(reason: String)
}

struct SignatureSubmitPayload {
    var signature: SignatureValue
    var signerName: String
    var signerRole: String?
}

/// Map a workflow save/submit result to the wizard's inline confirmation.
func workflowSubmitResult<T>(_ res: WorkflowActionResult<T>, _ okMessage: String) -> SubmitResult {
    switch res {
    case .ok:
        return SubmitResult(ok: true, message: okMessage)
    case .locked(let reason):
        return SubmitResult(ok: false, message: "Field work is locked: \(reason).")
    case .invalid(let errors):
        return SubmitResult(ok: false, message: errors.joined(separator: ", "))
    case .frozen(_, let recordStatus):
        return SubmitResult(ok: false, message: "Already \(recordStatus.rawValue) — nothing to resubmit.")
    case .notFound:
        return SubmitResult(ok: false, message: "Could not submit. Your work is saved on this phone.")
    }
}

/// Map a cached Hub assignment to the driver-facing Jobs-list item (no UUIDs/hashes).
private let assignmentValueUnavailable = "Not provided by Hub"

func assignmentDisplayValue(_ value: String?) -> String {
    guard let value else { return assignmentValueUnavailable }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? assignmentValueUnavailable : trimmed
}

func wellsLabel(_ a: HubAssignment) -> String {
    let names = (a.details?.wells ?? []).map(\.name).filter { !$0.isEmpty }
    return names.isEmpty ? assignmentValueUnavailable : names.joined(separator: ", ")
}

func srSyncLabel(_ state: SrSyncState?) -> JobStatusLabel {
    switch state {
    case .needsReview: return .needsReview
    case .needsSync: return .pendingSync
    case .synced: return .synced
    default: return .savedOnPhone
    }
}

func toJobListItem(_ a: HubAssignment, _ sync: SrSyncState?) -> JobListItem {
    let d = a.details
    let status = d?.status
    let group: JobGroup = status == .completed ? .completed : (status == .inProgress ? .current : .next)
    let hasLocalWork = sync != nil && sync != .noLocalWork
    return JobListItem(
        assignmentId: a.serviceRequestId,
        serviceRecord: assignmentDisplayValue(d?.requestNo),
        customer: assignmentDisplayValue(d?.customer?.name),
        lease: assignmentDisplayValue(d?.lease?.name),
        well: wellsLabel(a),
        jobType: assignmentDisplayValue(d?.jobType?.name),
        group: group,
        jhaStatus: .notStarted,
        ticketStatus: .notStarted,
        syncStatus: srSyncLabel(sync),
        primaryLabel: hasLocalWork ? .continueJob : .startJob
    )
}

func toJobIdentity(_ a: HubAssignment?) -> JobIdentity? {
    guard let a else { return nil }
    let d = a.details
    return JobIdentity(
        serviceRecord: assignmentDisplayValue(d?.requestNo),
        customer: assignmentDisplayValue(d?.customer?.name),
        lease: assignmentDisplayValue(d?.lease?.name),
        well: wellsLabel(a),
        jobType: assignmentDisplayValue(d?.jobType?.name),
        truck: assignmentDisplayValue(d?.vehicle?.name),
        trailer: assignmentDisplayValue(d?.trailer?.name),
        destination: assignmentDisplayValue(d?.disposalSite?.name)
    )
}

func toJobDetails(_ a: HubAssignment?, driverName: String?) -> JobDetails? {
    guard let a else { return nil }
    let d = a.details
    return JobDetails(
        serviceRecord: assignmentDisplayValue(d?.requestNo),
        customer: assignmentDisplayValue(d?.customer?.name),
        lease: assignmentDisplayValue(d?.lease?.name),
        well: wellsLabel(a),
        county: assignmentValueUnavailable,
        material: assignmentDisplayValue(d?.material),
        jobType: assignmentDisplayValue(d?.jobType?.name),
        truck: assignmentDisplayValue(d?.vehicle?.name),
        trailer: assignmentDisplayValue(d?.trailer?.name),
        driver: assignmentDisplayValue(driverName),
        destination: assignmentDisplayValue(d?.disposalSite?.name),
        orderedBy: assignmentValueUnavailable,
        dispatchNotes: "No dispatch notes were provided by the Hub.",
        customerNotes: "No customer notes were provided by the Hub."
    )
}

func formatLastHubContactLabel(_ lastHubContactAtMs: Int64?) -> String {
    guard let lastHubContactAtMs else { return "Never" }
    let date = Date(timeIntervalSince1970: Double(lastHubContactAtMs) / 1000)
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func titleCaseToken(_ value: String) -> String {
    value
        .split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
        .filter { !$0.isEmpty }
        .map { part -> String in
            String(part.prefix(1)).uppercased() + part.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

func profileDisplayName(_ profile: UserProfile?, _ fallbackUsername: String) -> String? {
    if let displayName = profile?.displayName { return displayName }
    if let username = profile?.username { return username }
    let trimmed = fallbackUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func profileRole(_ profile: UserProfile?) -> String? {
    if let title = profile?.title { return title }
    if let accessProfile = profile?.accessProfile { return titleCaseToken(accessProfile) }
    return nil
}

/// ISO-8601 with fractional seconds, matching the rest of the app's timestamp stamping.
private func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

enum BootState {
    case starting
    case ready(AppRuntime)
    case failed(failure: BootFailure)
}

struct AppRoot: View {
    @Environment(\.fieldTheme) private var t
    @State private var boot: BootState = .starting
    @State private var authNeeded = false
    // A previously-valid session that died mid-shift (retry engine signalled auth) → Session Expired,
    // distinct from a never-signed-in cold start.
    @State private var sessionExpired = false
    @State private var resetArmed = false
    @State private var bootAttempt = 0

    var body: some View {
        Group {
            if case .ready(let runtime) = boot {
                FieldSessionShell(
                    runtime: runtime,
                    authNeeded: authNeeded,
                    sessionExpired: sessionExpired,
                    onAuthNeeded: { needed in
                        authNeeded = needed
                        if !needed { sessionExpired = false }
                    }
                )
            } else {
                splash
            }
        }
        // Boot is a synchronous, throwing call — run it off the main render pass. Re-runs whenever
        // bootAttempt is bumped (the reset-and-retry path below).
        .task(id: bootAttempt) {
            do {
                let runtime = try wireAppRuntime(
                    hubUrl: hubUrl,
                    onAuthRequired: {
                        authNeeded = true
                        sessionExpired = true
                    }
                )
                boot = .ready(runtime)
            } catch {
                // Visible, classified failure — never a guess, never an auto-wipe. classifyBootFailure
                // distinguishes a missing Hub URL from a DB key mismatch (the only resettable case)
                // from any other error, with a plain-language message for each.
                boot = .failed(failure: classifyBootFailure(error))
            }
        }
    }

    // Splash / boot — branded, no technical details (GUI Master §1). The DB-key-mismatch reset is the
    // one exception that must stay explicit and double-confirmed.
    private var splash: some View {
        VStack(spacing: spacing.md) {
            Logo(size: 96, ring: true)
            Text("Field Capture")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            if case .starting = boot {
                Text("Opening saved work…")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            if case .failed(let failure) = boot {
                VStack(alignment: .leading, spacing: spacing.md) {
                    Text(failure.message)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.danger)
                        .accessibilityIdentifier("boot-failed-\(failure.reason.rawValue)")
                    if failure.canReset {
                        FieldButton(
                            label: resetArmed
                                ? "Tap again to CONFIRM reset — unsynced work will be lost"
                                : "Reset local data…",
                            onPress: {
                                if !resetArmed {
                                    resetArmed = true
                                    return
                                }
                                do {
                                    try resetLocalDatabase()
                                    resetArmed = false
                                    boot = .starting
                                    bootAttempt += 1
                                } catch {
                                    resetArmed = false
                                    boot = .failed(failure: classifyBootFailure(error))
                                }
                            },
                            variant: .destructive,
                            theme: t
                        )
                    }
                }
                .padding(spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(t.card)
                .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                .accessibilityIdentifier("boot-failed")
            }
        }
        .padding(spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.background)
    }
}

enum RefreshState {
    case idle
    case checking  // bounded: the Hub client times out and resolves to a state
    case done(result: FieldSessionResult)
    /// A local-device exception escaped (keystore, SQLite). Visible, retryable — never a spinner.
    case failed(message: String)
}

enum Tab: String { case day, jobs, sops, sync, more }

enum WorkPanel: String {
    case detail, jha, jobdetails, jobsops, emergency, stopwork, ticket, receipt, capture, location,
        print
}

let JOB_SUB_FLOWS: Set<WorkPanel> = [.jha, .jobdetails, .jobsops, .emergency, .stopwork]

let TABS: [(key: Tab, label: String)] = [
    (.day, "Day"), (.jobs, "Jobs"), (.sops, "SOPs"), (.sync, "Sync"), (.more, "More"),
]

let WORK_PANELS: [(key: WorkPanel, label: String)] = [
    (.detail, "Details"), (.ticket, "Ticket"), (.receipt, "Receipt"),
    (.capture, "Evidence"), (.location, "Location"), (.print, "Print"),
]

enum JobsViewMode { case list, work }

/// The seam AppState-equivalent for foreground detection, wired over the real UIApplication
/// notifications (mirrors FieldRuntime.ForegroundSync's AppStateLike, which is UIKit-agnostic).
private struct UIKitForegroundAppState: AppStateLike {
    func addEventListener(_ handler: @escaping (String) -> Void) -> AppStateSubscription {
        let nc = NotificationCenter.default
        let willForeground = nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in handler("active") }
        let didBackground = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in handler("background") }
        return AppStateSubscription(remove: {
            nc.removeObserver(willForeground)
            nc.removeObserver(didBackground)
        })
    }
}

struct FieldSessionShell: View {
    var runtime: AppRuntime
    var authNeeded: Bool
    var sessionExpired: Bool
    var onAuthNeeded: (Bool) -> Void

    @Environment(\.fieldTheme) private var t
    @State private var refresh: RefreshState = .idle
    @State private var fieldGate: FieldWorkGate
    @State private var tab: Tab = .day
    @State private var jobView: JobsViewMode = .list
    @State private var workPanel: WorkPanel = .detail
    @State private var selectedSrId: String?
    @State private var workStartStatus: JobWorkStartStatus?
    // Only the setter matters: bumping it forces a re-render so the store-derived summaries below
    // recompute after a save/delete/refresh. The value itself is never read.
    @State private var revision = 0
    @State private var username = ""
    @State private var password = ""
    @State private var userProfile: UserProfile?
    @State private var profileReadError: String?
    @State private var loginMessage: String?
    @State private var manualSyncing = false
    @State private var foregroundUnsubscribe: (() -> Void)?
    @State private var formOutboxItems: [DurableSyncOutboxItem] = []
    @State private var outboxReadError: String?
    @State private var completedWorkflowSteps = CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:])
    @State private var workflowReadError: String?
    @State private var fieldTicketDrafts: [FieldTicketDraft] = []
    @State private var receiptDrafts: [FieldDomain.ReceiptDraft] = []
    @State private var draftReadError: String?

    init(runtime: AppRuntime, authNeeded: Bool, sessionExpired: Bool, onAuthNeeded: @escaping (Bool) -> Void) {
        self.runtime = runtime
        self.authNeeded = authNeeded
        self.sessionExpired = sessionExpired
        self.onAuthNeeded = onAuthNeeded
        _fieldGate = State(initialValue: runtime.field.gate.get())
    }

    private var controller: AppController { runtime.controller }
    private var field: FieldRuntimeWorkspace { runtime.field }

    private func refreshLocalWorkflowState() {
        do {
            formOutboxItems = try runtime.outbox.list()
            let corruptOpIds = try runtime.outbox.listCorruptOpIds()
            outboxReadError =
                corruptOpIds.isEmpty
                ? nil
                : "Some saved sync records need support review. No affected record will be sent automatically."
        } catch {
            outboxReadError = "Saved-work sync status is temporarily unavailable. Your local work is unchanged."
        }

        if let vehicleRef {
            do {
                completedWorkflowSteps = try field.workflow.completedSteps(vehicleRef: vehicleRef)
                workflowReadError = nil
            } catch {
                completedWorkflowSteps = CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:])
                workflowReadError = "Safety-form status is temporarily unavailable. Field work remains blocked."
            }
        } else {
            completedWorkflowSteps = CompletedWorkflowSteps(jhaFormIdByServiceRequest: [:])
            workflowReadError = nil
        }

        do {
            fieldTicketDrafts = try runtime.draftStore.list()
            receiptDrafts = try runtime.receiptStore.list()
            draftReadError = nil
        } catch {
            fieldTicketDrafts = []
            receiptDrafts = []
            draftReadError = "Saved ticket and receipt status is temporarily unavailable. Your local work is unchanged."
        }
    }

    private func bump() {
        revision += 1
        refreshLocalWorkflowState()
    }

    // ---- derived-from-stores render data (recomputed every body evaluation) ----

    private var assignments: [HubAssignment] { runtime.assignmentStore.listAssignments() }
    private var syncStateById: [String: SrSyncState] { controller.srSyncStateById() }
    private var needsReviewCount: Int { syncStateById.values.filter { $0 == .needsReview }.count }
    private var completedJobsCount: Int {
        assignments.filter { $0.details?.status == .completed }.count
    }
    private var draftCount: Int { fieldTicketDrafts.count + receiptDrafts.count }
    private var syncSummary: SyncCenterSummary { controller.syncCenterSummary(draftCount) }
    private var offlinePolicyState: OfflinePolicyPersistedState { runtime.offlinePolicyStore.getState() }
    private var pendingSyncItems: [SyncItem] {
        assignments
            .filter { syncStateById[$0.serviceRequestId] == .needsSync }
            .map {
                let requestNo = $0.details?.requestNo?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label =
                    requestNo.flatMap { $0.isEmpty ? nil : "Field ticket · SR \($0)" }
                    ?? "Field ticket · request number unavailable"
                return SyncItem(
                    key: $0.serviceRequestId,
                    label: label,
                    status: .pendingSync
                )
            }
    }
    private var effectiveSrId: String { selectedSrId ?? assignments.first?.serviceRequestId ?? "" }
    private var selectedAssignment: HubAssignment? { assignments.first { $0.serviceRequestId == effectiveSrId } }
    // The SR's human request number is the ticket id shown to the driver.
    private var selectedRequestNo: String? { selectedAssignment?.details?.requestNo }
    private var vehicleRef: String? {
        [selectedAssignment?.details?.vehicle?.name, userProfile?.defaultTruck]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
    }
    private var truckDisplay: String { assignmentDisplayValue(vehicleRef) }
    private var trailerDisplay: String {
        assignmentDisplayValue(selectedAssignment?.details?.trailer?.name ?? userProfile?.defaultTrailer)
    }
    private var jhaJobSiteFields: [JhaField] {
        let details = selectedAssignment?.details
        return [
            JhaField(label: "Service Record", value: assignmentDisplayValue(details?.requestNo)),
            JhaField(label: "Customer", value: assignmentDisplayValue(details?.customer?.name)),
            JhaField(label: "Lease", value: assignmentDisplayValue(details?.lease?.name)),
            JhaField(label: "Well", value: selectedAssignment.map(wellsLabel) ?? assignmentValueUnavailable),
            JhaField(label: "Job Type", value: assignmentDisplayValue(details?.jobType?.name)),
            JhaField(label: "Material", value: assignmentDisplayValue(details?.material)),
            JhaField(label: "Truck", value: truckDisplay),
            JhaField(label: "Trailer", value: trailerDisplay),
            JhaField(label: "Destination", value: assignmentDisplayValue(details?.disposalSite?.name)),
            JhaField(label: "Driver", value: assignmentDisplayValue(driverName)),
        ]
    }
    private var jhaEmergencyFields: [JhaField] {
        [
            JhaField(label: "Emergency Services", value: "911"),
            JhaField(
                label: "Site-specific emergency details",
                value: "Not provided by Hub — confirm the emergency plan with dispatch before work."
            ),
        ]
    }
    private var driverName: String? { profileDisplayName(userProfile, username) }
    private var driverRole: String? { profileRole(userProfile) }
    private var gateEmployeeId: String? {
        guard case .unlocked(_, _, let employeeId) = fieldGate, let employeeId, !employeeId.isEmpty else { return nil }
        return employeeId
    }
    private var employeeId: String? { gateEmployeeId ?? userProfile?.employeeId }
    private var punchedIn: Bool { if case .unlocked = fieldGate { return true } else { return false } }
    private var checkingNow: Bool { if case .checking = refresh { return true } else { return false } }
    private var formOutboxPending: Int {
        formOutboxItems.filter { $0.state == .pending || $0.state == .inFlight }.count
    }
    private var pendingSync: Int {
        (syncSummary.counts[.waitingToSync] ?? 0) + (syncSummary.counts[.waitingOnYou] ?? 0) + formOutboxPending
    }

    // Status strip: show only what matters (GUI Master §3) — never env/hub/backend strings.
    private var chips: [HeaderChip] {
        var result: [HeaderChip] = []
        if case .unlocked = fieldGate {
            result.append(HeaderChip(label: "Punched In", tone: .success))
        } else if case .locked(let reason, _) = fieldGate, reason == .hubUnreachable {
            result.append(HeaderChip(label: "Offline Mode", tone: .warning))
        } else if case .locked(let reason, _) = fieldGate, reason == .notClockedIn {
            result.append(HeaderChip(label: "Not Punched In", tone: .warning))
        }
        if outboxReadError != nil || draftReadError != nil {
            result.append(HeaderChip(label: "Saved Work Status Unavailable", tone: .warning))
        } else if pendingSync > 0 {
            result.append(HeaderChip(label: "\(pendingSync) Pending Sync", tone: .info))
        }
        if let vehicleName = selectedAssignment?.details?.vehicle?.name, !vehicleName.isEmpty {
            result.append(HeaderChip(label: vehicleName, tone: .neutral))
        }
        return result
    }

    private var dayStatusDetail: String? {
        if case .locked(let reason, _) = fieldGate, reason == .hubUnreachable {
            return "Hub unreachable — your saved work is safe on this phone and will sync later."
        }
        if case .locked(let reason, _) = fieldGate, reason == .badHubResponse {
            return "The Hub answered unexpectedly. Try again in a moment."
        }
        return nil
    }

    private var syncLastHubContactLabel: String {
        switch refresh {
        case .checking:
            return "Checking now…"
        case .failed:
            return
                "Last attempt failed on this device · \(formatLastHubContactLabel(offlinePolicyState.lastHubContactAtMs))"
        default:
            return formatLastHubContactLabel(offlinePolicyState.lastHubContactAtMs)
        }
    }

    // ---- navigation ----

    private func openSr(_ serviceRequestId: String) {
        selectedSrId = serviceRequestId
        workStartStatus = nil
        workPanel = .detail
        jobView = .work
        tab = .jobs
    }

    // ---- refresh / login / sync ----

    private func doRefresh() async {
        refresh = .checking
        do {
            let result = try await controller.refreshSession()  // Hub failures resolve to locked states
            let gate = applyOfflinePolicyToGate(
                previousGate: field.gate.get(), nextGate: result.gate, offlinePolicy: controller.offlinePolicy())
            field.gate.set(gate)
            fieldGate = gate
            refresh = .done(result: FieldSessionResult(gate: gate, assignments: result.assignments))
            if case .locked(let reason, _) = gate, reason == .authFailed {
                onAuthNeeded(true)
            } else {
                onAuthNeeded(false)
            }
            bump()
        } catch {
            // Local-device failures (SQLite write, keystore) are the only throws left — they must
            // land in a visible state too. No infinite "Checking Hub".
            refresh = .failed(message: String(describing: error))
        }
    }

    private func doManualSync() async {
        manualSyncing = true
        defer { manualSyncing = false }
        await doRefresh()
        // This revalidates/resumes any auth-paused runners, then kicks both V2 sync and blob upload.
        await doForegroundSync()
    }

    private func doForegroundSync() async {
        do {
            try await controller.onForeground()
        } catch {
            refresh = .failed(message: String(describing: error))
        }
        bump()
    }

    private func loadUserProfile() async {
        do {
            userProfile = try await controller.currentUserProfile()
            profileReadError = nil
        } catch {
            userProfile = nil
            profileReadError = "Account details are temporarily unavailable on this phone."
        }
    }

    private func doLogin() async {
        loginMessage = nil
        do {
            let result = try await controller.login(AuthCredentials(username: username, password: password))
            if case .signedIn = result {
                password = ""
                await loadUserProfile()
                onAuthNeeded(false)
                await doRefresh()
                return
            }
            switch result {
            case .invalidCredentials(let detail):
                loginMessage = detail.map { "Sign-in rejected: \($0)" } ?? "Sign-in rejected"
            case .unavailable(let reason):
                loginMessage = "Hub unavailable (\(reason)) — try again"
            default:
                break
            }
        } catch {
            loginMessage = "Sign-in failed on this device: \(String(describing: error))"
        }
    }

    private func startWork() {
        let actorRef = gateEmployeeId ?? username
        do {
            let result = try field.workStart.startWork(
                WorkStartInput(serviceRequestId: effectiveSrId, actorRef: actorRef))
            switch result {
            case .ok:
                workStartStatus = JobWorkStartStatus(label: "Work start saved on this phone", tone: .success)
                bump()
            case .locked(let reason):
                workStartStatus = JobWorkStartStatus(label: "Locked: \(reason)", tone: .warning)
            case .invalid(let errors):
                workStartStatus = JobWorkStartStatus(label: errors.joined(separator: ", "), tone: .danger)
            }
        } catch {
            workStartStatus = JobWorkStartStatus(
                label: "Could not save work start on this phone. Check storage and try again.",
                tone: .danger
            )
        }
    }

    // ---- submit plumbing ----
    //
    // Wizard completions persist REAL records via the same services the functional panels use:
    // saving + completing + submitting a durable form/ticket so the outcome shows up in Sync.
    //
    // The driver's drawn signature is captured as a durable blob (CaptureFlow) and wrapped in a
    // SignatureRecord (signer identity, UTC timestamp, certification text, consent, device/audit)
    // before the form is built — a form can never be completed without its real signature.

    private func persistSignature(
        _ serviceRequestId: String, _ certificationText: String, _ payload: SignatureSubmitPayload
    ) async throws -> SignatureRecordResult {
        let result = try await field.capture.capture(
            CaptureInput(
                bytes: signatureBytes(payload.signature),
                mimeType: "application/octet-stream",
                source: .signaturePad,
                attachmentKind: .signature,
                parentType: .sr,
                parentId: serviceRequestId
            ))
        switch result {
        case .locked(let reason):
            return .locked(reason: reason)
        case .captured(let record, _):
            let signerUserId: String? = (!username.isEmpty && payload.signerRole == "Driver") ? username : nil
            let signatureRecord = buildSignatureRecord(
                blobId: record.blobId,
                signerName: payload.signerName,
                signerUserId: signerUserId,
                signerRole: payload.signerRole,
                signedAtUtc: isoStamp(Date()),
                certificationText: certificationText,
                deviceInstanceId: field.deviceInstanceId,
                appVersion: appVersion ?? "unknown"
            )
            return .ok(record: signatureRecord)
        }
    }

    private func submitPreTripInspection(_ payload: DvirSubmissionPayload) async -> SubmitResult {
        guard !effectiveSrId.isEmpty, selectedAssignment != nil else {
            return SubmitResult(
                ok: false,
                message: "A current Hub assignment is required before starting an inspection."
            )
        }
        guard let vehicleRef else {
            return SubmitResult(
                ok: false,
                message: "A truck is required. Refresh the assignment or ask dispatch to assign equipment."
            )
        }
        do {
            let sig = try await persistSignature(
                effectiveSrId, DVIR_PRETRIP_CERTIFICATION_TEXT,
                SignatureSubmitPayload(
                    signature: payload.signature,
                    signerName: payload.signerName,
                    signerRole: "Driver"
                ))
            switch sig {
            case .locked(let reason):
                return SubmitResult(ok: false, message: "Field work is locked: \(reason).")
            case .ok(let record):
                let form = try preTripDvirForm(
                    formId: "pre-trip-dvir-\(effectiveSrId)-\(record.blobId)",
                    serviceRequestId: effectiveSrId,
                    vehicleRef: vehicleRef,
                    items: payload.items,
                    defectsCertifiedSafe: payload.defectsCertifiedSafe,
                    signatures: [record]
                )
                let saved = try field.workflow.saveDraft(.dvir(form))
                guard case .ok = saved else {
                    bump()
                    return workflowSubmitResult(saved, "")
                }
                let completed = try field.workflow.completeForm(form.formId)
                guard case .ok = completed else {
                    bump()
                    return workflowSubmitResult(completed, "")
                }
                let res = try field.workflow.submitForm(form.formId)
                bump()
                return workflowSubmitResult(res, "Pre-trip inspection completed and saved on this phone.")
            }
        } catch let error as FieldFormError {
            return SubmitResult(ok: false, message: "Inspection is incomplete: \(error.message)")
        } catch is FieldWorkflowError {
            return workflowPersistenceFailure("pre-trip inspection")
        } catch {
            return signatureCaptureFailure
        }
    }

    private func submitPostTripInspection(_ payload: DvirSubmissionPayload) async -> SubmitResult {
        guard !effectiveSrId.isEmpty, selectedAssignment != nil else {
            return SubmitResult(
                ok: false,
                message: "A current Hub assignment is required before starting an inspection."
            )
        }
        guard let vehicleRef else {
            return SubmitResult(
                ok: false,
                message: "A truck is required. Refresh the assignment or ask dispatch to assign equipment."
            )
        }
        do {
            let sig = try await persistSignature(
                effectiveSrId, DVIR_POSTTRIP_CERTIFICATION_TEXT,
                SignatureSubmitPayload(
                    signature: payload.signature,
                    signerName: payload.signerName,
                    signerRole: "Driver"
                ))
            switch sig {
            case .locked(let reason):
                return SubmitResult(ok: false, message: "Field work is locked: \(reason).")
            case .ok(let record):
                let form = try postTripDvirForm(
                    formId: "post-trip-dvir-\(effectiveSrId)-\(record.blobId)",
                    serviceRequestId: effectiveSrId,
                    vehicleRef: vehicleRef,
                    items: payload.items,
                    defectsCertifiedSafe: payload.defectsCertifiedSafe,
                    signatures: [record]
                )
                let saved = try field.workflow.saveDraft(.dvir(form))
                guard case .ok = saved else {
                    bump()
                    return workflowSubmitResult(saved, "")
                }
                let completed = try field.workflow.completeForm(form.formId)
                guard case .ok = completed else {
                    bump()
                    return workflowSubmitResult(completed, "")
                }
                let res = try field.workflow.submitForm(form.formId)
                bump()
                return workflowSubmitResult(res, "Post-trip inspection completed and saved on this phone.")
            }
        } catch let error as FieldFormError {
            return SubmitResult(ok: false, message: "Inspection is incomplete: \(error.message)")
        } catch is FieldWorkflowError {
            return workflowPersistenceFailure("post-trip inspection")
        } catch {
            return signatureCaptureFailure
        }
    }

    private func submitJhaForm(_ payload: JhaSubmissionPayload) async -> SubmitResult {
        guard !effectiveSrId.isEmpty, selectedAssignment != nil else {
            return SubmitResult(ok: false, message: "A current Hub assignment is required before starting a JHA/JSA.")
        }
        guard !payload.signatures.isEmpty else {
            return SubmitResult(ok: false, message: "A signature is required.")
        }
        do {
            var records: [SignatureRecord] = []
            for signature in payload.signatures {
                let sig = try await persistSignature(effectiveSrId, JHA_CERTIFICATION_TEXT, signature)
                switch sig {
                case .locked(let reason):
                    return SubmitResult(ok: false, message: "Field work is locked: \(reason).")
                case .ok(let record):
                    records.append(record)
                }
            }
            guard let primarySignature = records.first else {
                return SubmitResult(ok: false, message: "A signature is required.")
            }
            let form = try jhaJsaForm(
                formId: "jha-jsa-\(effectiveSrId)-\(primarySignature.blobId)",
                serviceRequestId: effectiveSrId,
                hazards: payload.hazards,
                signatures: records
            )
            let saved = try field.workflow.saveDraft(.jha(form))
            guard case .ok = saved else {
                bump()
                return workflowSubmitResult(saved, "")
            }
            let completed = try field.workflow.completeForm(form.formId)
            guard case .ok = completed else {
                bump()
                return workflowSubmitResult(completed, "")
            }
            let res = try field.workflow.submitForm(form.formId)
            bump()
            return workflowSubmitResult(res, "JHA/JSA completed and saved on this phone.")
        } catch let error as FieldFormError {
            return SubmitResult(ok: false, message: "JHA/JSA is incomplete: \(error.message)")
        } catch is FieldWorkflowError {
            return workflowPersistenceFailure("JHA/JSA")
        } catch {
            return signatureCaptureFailure
        }
    }

    // ---- body ----

    var body: some View {
        Group {
            if authNeeded {
                SignInView(
                    username: username, password: password, message: loginMessage, expired: sessionExpired,
                    onUsername: { username = $0 }, onPassword: { password = $0 },
                    onSubmit: { Task { await doLogin() } }
                )
            } else {
                mainShell
            }
        }
        // On foreground return, AppController.onForeground re-validates the session (a silent
        // refresh resumes any runner paused for auth while backgrounded) and kicks the sync/upload
        // drivers so queued evidence drains promptly.
        .onAppear {
            if foregroundUnsubscribe == nil {
                foregroundUnsubscribe = subscribeForegroundSync(
                    UIKitForegroundAppState(), { Task { await doForegroundSync() } }, "active")
            }
        }
        .onDisappear {
            // Stop the foreground event source FIRST, then tear down the controller.
            foregroundUnsubscribe?()
            foregroundUnsubscribe = nil
            controller.stop()
        }
        .task {
            await loadUserProfile()
            refreshLocalWorkflowState()
            await doRefresh()
        }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            AppHeader(chips: chips)
            tabBar
            if checkingNow {
                Text("Checking Hub…")
                    .font(.system(size: typeScale.caption))
                    .foregroundStyle(t.textMuted)
                    .padding(.horizontal, spacing.lg)
                    .padding(.top, spacing.xs)
            }
            if let workflowReadError {
                Text(workflowReadError)
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, spacing.lg)
                    .padding(.top, spacing.xs)
                    .accessibilityIdentifier("workflow-status-unavailable")
            }
            if let draftReadError {
                Text(draftReadError)
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, spacing.lg)
                    .padding(.top, spacing.xs)
                    .accessibilityIdentifier("draft-status-unavailable")
            }
            if let profileReadError {
                Text(profileReadError)
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.danger)
                    .padding(.horizontal, spacing.lg)
                    .padding(.top, spacing.xs)
                    .accessibilityIdentifier("profile-status-unavailable")
            }
            ScrollView {
                VStack(spacing: spacing.md) {
                    tabContent
                }
                .padding(spacing.lg)
            }
            .background(t.background)
        }
        .background(t.background)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(TABS, id: \.key) { tabDef in
                let selected = tab == tabDef.key
                Button(action: {
                    tab = tabDef.key
                    if tabDef.key == .jobs { jobView = .list }
                }) {
                    Text(tabDef.label)
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .foregroundStyle(selected ? t.primary : t.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab-\(tabDef.key.rawValue)")
            }
        }
        .background(t.card)
        .overlay(Rectangle().fill(t.border).frame(height: 0.5), alignment: .bottom)
        .accessibilityIdentifier("tab-bar")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .day:
            DayTab(
                punchedIn: punchedIn,
                clockedInSince: {
                    if case .unlocked(let since, _, _) = fieldGate { return since }
                    return nil
                }(),
                statusDetail: dayStatusDetail,
                jobsCount: assignments.count,
                completedJobsCount: completedJobsCount,
                needsReview: needsReviewCount,
                pendingSync: pendingSync,
                hasAuthoritativeAssignment: !assignments.isEmpty,
                checking: checkingNow,
                onOpenJobs: { tab = .jobs },
                onRefresh: { Task { await doRefresh() } },
                onSubmitPreTrip: submitPreTripInspection,
                onSubmitPostTrip: submitPostTripInspection,
                driverName: driverName,
                truck: truckDisplay,
                trailer: trailerDisplay,
                odometer: assignmentValueUnavailable
            )
        case .jobs:
            jobsTabContent
        case .sops:
            SopsTab()
        case .sync:
            SyncTab(
                pendingCount: pendingSync,
                failedCount: syncSummary.counts[.rejectedByHub] ?? 0,
                syncedCount: syncSummary.counts[.acceptedByHub] ?? 0,
                offline: {
                    if case .locked(let reason, _) = fieldGate { return reason == .hubUnreachable }
                    return false
                }(),
                lastSyncedAt: syncLastHubContactLabel,
                syncing: checkingNow || manualSyncing,
                pendingItems: pendingSyncItems,
                statusError: outboxReadError ?? draftReadError,
                onSyncNow: { Task { await doManualSync() } }
            )
        case .more:
            MoreTab(
                onSignOut: {
                    try await controller.logout()
                    userProfile = nil
                    onAuthNeeded(true)
                    bump()
                },
                onOpenSops: { tab = .sops },
                punchedIn: punchedIn,
                syncSummary: (outboxReadError ?? draftReadError)
                    ?? (pendingSync == 0
                        ? "All work is saved and up to date."
                        : "\(pendingSync) item\(pendingSync == 1 ? "" : "s") waiting to sync. Your work is safe on this phone."),
                syncTone: (outboxReadError == nil && draftReadError == nil && pendingSync == 0) ? .success : .warning,
                driverName: driverName,
                driverRole: driverRole,
                department: userProfile?.department,
                employeeId: employeeId,
                phone: userProfile?.phone,
                assignedYard: userProfile?.assignedYard,
                defaultTruck: userProfile?.defaultTruck,
                defaultTrailer: userProfile?.defaultTrailer,
                envInfo: EnvironmentInfo(
                    hubEnvironment: appEnv.rawValue,
                    hubUrl: hubUrl ?? "not configured",
                    appVersion: appVersion ?? "—",
                    build: "development",
                    storageEngine: runtime.durability.rawValue,
                    deviceId: "This device",
                    lastSync: syncLastHubContactLabel
                )
            )
        }
    }

    @ViewBuilder
    private var jobsTabContent: some View {
        if jobView == .list {
            JobsListScreen(
                jobs: assignments.map { toJobListItem($0, syncStateById[$0.serviceRequestId]) },
                onOpenJob: openSr,
                onRefresh: { Task { await doRefresh() } }
            )
        } else {
            jobWorkContent
        }
    }

    private var jobWorkContent: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: { jobView = .list }) {
                Text("‹ All jobs").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("job-back")

            if !JOB_SUB_FLOWS.contains(workPanel) {
                workPanelTabs
            }

            workPanelContent
        }
    }

    private var workPanelTabs: some View {
        HStack(spacing: spacing.xs) {
            ForEach(WORK_PANELS, id: \.key) { panelDef in
                let selected = workPanel == panelDef.key
                Button(action: { workPanel = panelDef.key }) {
                    Text(panelDef.label)
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .foregroundStyle(selected ? t.onPrimary : t.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? t.primary : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: sizing.pillRadius).stroke(
                                selected ? t.primary : t.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: sizing.pillRadius))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("work-panel-\(panelDef.key.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var workPanelContent: some View {
        switch workPanel {
        case .detail:
            JobOverviewScreen(
                job: toJobIdentity(selectedAssignment),
                primaryLabel: .startJhaJsa,
                onPrimary: { workPanel = .jha },
                onStartWork: { startWork() },
                workStartStatus: workStartStatus,
                onAddEvidence: { workPanel = .capture },
                onCaptureGps: { workPanel = .location },
                onAddReceipt: { workPanel = .receipt },
                onPrintTicket: { workPanel = .print },
                onEmergencyInfo: { workPanel = .emergency },
                onStopWork: { workPanel = .stopwork },
                onMenu: { key in
                    switch key {
                    case .details: workPanel = .jobdetails
                    case .sops: workPanel = .jobsops
                    case .emergency: workPanel = .emergency
                    case .stopWork: workPanel = .stopwork
                    case .evidence: workPanel = .capture
                    case .print: workPanel = .print
                    case .directions:
                        if let destination = selectedAssignment?.details?.disposalSite?.name
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                            !destination.isEmpty,
                            let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                            let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)")
                        {
                            UIApplication.shared.open(url)
                        } else {
                            workStartStatus = JobWorkStartStatus(
                                label: "Directions unavailable: no destination was provided by the Hub.",
                                tone: .warning
                            )
                        }
                    case .dispatch:
                        workStartStatus = JobWorkStartStatus(
                            label: "Dispatch contact unavailable: use a verified company number.",
                            tone: .warning
                        )
                    }
                }
            )
        case .jobdetails, .jobsops, .emergency, .stopwork:
            subJobPanel
        case .jha:
            JhaFlow(
                onExit: { workPanel = .detail },
                onStartFieldTicket: { workPanel = .ticket },
                onSubmit: submitJhaForm,
                driverName: driverName,
                srNumber: assignmentDisplayValue(selectedAssignment?.details?.requestNo),
                customer: assignmentDisplayValue(selectedAssignment?.details?.customer?.name),
                lease: assignmentDisplayValue(selectedAssignment?.details?.lease?.name),
                jobSiteFields: jhaJobSiteFields,
                emergencyFields: jhaEmergencyFields,
                dvirCompleted: completedWorkflowSteps.preTripDvirFormId != nil
            )
        case .ticket:
            TicketCaptureScreen(
                draftStore: runtime.draftStore, serviceRequestId: effectiveSrId, requestNo: selectedRequestNo,
                driverName: driverName, gate: fieldGate, identity: identity,
                onSaved: { _ in bump() }, onDeleted: { bump() }
            )
        case .receipt:
            FieldReceiptCaptureScreen(
                receiptStore: runtime.receiptStore, serviceRequestId: effectiveSrId,
                requestNo: selectedRequestNo, gate: fieldGate,
                identity: identity,
                onSaved: { _ in bump() }, onDeleted: { bump() }
            )
        case .capture:
            CaptureEvidenceScreen(
                capture: field.capture, uploads: field.uploadEngine, blobs: field.blobs,
                parentType: .fieldTicket, parentId: effectiveSrId, linkOutcome: field.linkOutcome,
                captureDevice: captureEvidenceDevice
            )
        case .location:
            LocationValidationScreen(
                locationStore: runtime.locationStore, serviceRequestId: effectiveSrId, gate: fieldGate,
                captureGps: { await captureValidationGps() }, identity: identity,
                onSaved: { evidence in
                    _ = try field.locationEvidenceSync.enqueue(evidence)
                    bump()
                }
            )
        case .print:
            PrintQueueScreen(runtime: field.printRuntime, queue: field.printQueue)
        }
    }

    @ViewBuilder
    private var subJobPanel: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            Button(action: { workPanel = .detail }) {
                Text("‹ Back to job").font(.system(size: typeScale.body, weight: .bold)).foregroundStyle(t.primary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("jobsub-back")
            switch workPanel {
            case .jobdetails: JobDetailsScreen(details: toJobDetails(selectedAssignment, driverName: driverName))
            case .jobsops: JobSopsScreen()
            case .emergency: EmergencyInfoScreen()
            case .stopwork: StopWorkScreen()
            default: EmptyView()
            }
        }
    }
}

enum SignInAux { case none, help, offline, permissions, sops }

private struct SignInScroll<Content: View>: View {
    var alignment: Alignment
    @ViewBuilder var content: Content

    init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(spacing.xl)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: proxy.size.height,
                        alignment: alignment
                    )
            }
        }
    }
}

struct SignInView: View {
    var username: String
    var password: String
    var message: String?
    var expired: Bool = false
    var onUsername: (String) -> Void
    var onPassword: (String) -> Void
    var onSubmit: () -> Void

    @Environment(\.fieldTheme) private var t
    @State private var aux: SignInAux = .none
    @State private var expiredDismissed = false

    private func home() { aux = .none }

    var body: some View {
        Group {
            // Session Expired (GUI Master §5 screen 6) — shown when a previously-valid session died.
            if expired && !expiredDismissed {
                SignInScroll {
                    SessionExpiredScreen(onSignInAgain: { expiredDismissed = true })
                }
            } else if aux != .none {
                SignInScroll(alignment: .leading) {
                    VStack(alignment: .leading, spacing: spacing.xl) {
                        Button(action: home) {
                            Text("‹ Back to sign in").font(.system(size: typeScale.body, weight: .bold))
                                .foregroundStyle(t.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("signin-aux-back")
                        auxContent
                    }
                }
            } else {
                SignInScroll {
                    VStack(spacing: spacing.xl) {
                        VStack(spacing: spacing.sm) {
                            Logo(size: 88, ring: true)
                            Text("Field Capture").font(.system(size: typeScale.title, weight: .heavy)).foregroundStyle(
                                t.text)
                            Text("Driver companion for field work").font(.system(size: typeScale.body)).foregroundStyle(
                                t.textMuted)
                        }
                        Card(title: "Sign in", testID: "login-form", theme: t) {
                            Text("Driver ID").font(.system(size: typeScale.label, weight: .semibold)).foregroundStyle(
                                t.text)
                            TextField(
                                "",
                                text: Binding(get: { username }, set: onUsername),
                                prompt: Text("Driver ID").foregroundColor(t.textMuted)
                            )
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .padding(12)
                            .background(t.card)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                            .accessibilityLabel("Driver ID")
                            Text("Password").font(.system(size: typeScale.label, weight: .semibold)).foregroundStyle(
                                t.text)
                            SecureField(
                                "",
                                text: Binding(get: { password }, set: onPassword),
                                prompt: Text("Password").foregroundColor(t.textMuted)
                            )
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                            .padding(12)
                            .background(t.card)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                            .accessibilityLabel("Password")
                            FieldButton(label: "Sign In", onPress: onSubmit, theme: t)
                            if let message {
                                Text(message).font(.system(size: typeScale.label)).foregroundStyle(t.danger)
                            }
                            FieldButton(
                                label: "Help signing in", onPress: { aux = .help }, variant: .secondary,
                                testID: "signin-help", theme: t)
                            FieldButton(
                                label: "View saved offline work", onPress: { aux = .offline }, variant: .secondary,
                                testID: "signin-offline", theme: t)
                            FieldButton(
                                label: "View SOPs", onPress: { aux = .sops }, variant: .secondary,
                                testID: "signin-sops", theme: t)
                            FieldButton(
                                label: "Set up permissions", onPress: { aux = .permissions }, variant: .secondary,
                                testID: "signin-permissions", theme: t)
                            Text("Saved work on this phone stays safe.").font(.system(size: typeScale.caption))
                                .foregroundStyle(t.textMuted)
                        }
                    }
                }
            }
        }
        .background(t.background.ignoresSafeArea())
    }

    @ViewBuilder
    private var auxContent: some View {
        switch aux {
        case .help: SignInHelpScreen(onBack: home)
        case .offline: OfflineSavedWorkScreen(onContinue: home, onRetry: home)
        case .permissions: FirstRunPermissionsScreen(onFinish: home)
        case .sops: SopBrowser()
        case .none: EmptyView()
        }
    }
}
