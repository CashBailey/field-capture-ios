//
//  FieldRuntimeScreens.swift
//  Ported from apps/mobile/src/screens/FieldRuntimeScreens.tsx
//
//  The FUNCTIONAL field-runtime screens — wired to the real stores/engines (draft stores, capture
//  flow, upload/print engines, the field-workflow service, the PT-210 printer transport), unlike
//  the presentational mock screens elsewhere in this target. Deliberately plain/utilitarian styling
//  (its own small local style helpers below, not the shared Card/FieldButton components) — mirrors
//  the TS source's own minimal `useFieldStyles()`/`StyleSheet` rather than the polished design
//  system, since these are developer/ops-facing runtime surfaces first.
//
//  NAMING NOTE: the TS `ReceiptCaptureScreen` export is ported here as `FieldReceiptCaptureScreen`.
//  `EvidenceScreens.swift` (same app target) already declares a presentational `ReceiptCaptureScreen`
//  for a different (mock) screen; this file's version is the functional one wired to a real
//  `ReceiptDraftStore`. The shell/gallery must import this one under the `FieldReceiptCaptureScreen`
//  name (the TS shell already imports both `ReceiptCaptureScreen` exports under distinct local names,
//  since they come from two different TS screen files).
//

import Foundation
import FieldAdapters
import FieldContracts
import FieldDomain
import FieldRuntime
import SwiftUI

// MARK: - Shared message + action primitives (mirrors the TS `Message` / `ActionButton` / `MessageLine`)

private struct RuntimeMessage {
    enum Kind { case ok, warn, error }
    var kind: Kind
    var text: String
}

private struct MessageLine: View {
    var message: RuntimeMessage?
    var t: Theme

    var body: some View {
        if let message {
            Group {
                switch message.kind {
                case .ok: Text(message.text).runtimeOk(t)
                case .warn: Text(message.text).runtimeWarn(t)
                case .error: Text(message.text).runtimeError(t)
                }
            }
            .accessibilityIdentifier("runtime-message")
        }
    }
}

/// The one accent color this runtime file's controls use — matches the TS source's hard-coded
/// `#1f6f8b`, distinct from the polished design system's green primary (these are utilitarian
/// runtime/dev-facing surfaces, not the branded UI).
private let runtimeAccent = Color(hex: "#1f6f8b")

private struct ActionButton: View {
    var testID: String
    var label: String
    var onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 34)
                .background(runtimeAccent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(testID)
    }
}

/// Pressable pill — the `styles.chip`/`chipSelected`/`chipText`/`chipTextSelected` equivalent.
private struct RuntimeChip: View {
    var t: Theme
    var label: String
    var selected: Bool
    var testID: String
    var accessibilityLabel: String?
    var onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.white : t.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: 30)
                .background(selected ? runtimeAccent : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? runtimeAccent : t.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(testID)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` half of RN's `styles.row`.
/// ponytail: duplicated from the same-named private layout in EvidenceScreens.swift / JobScreens.swift
/// (file-private there, so unreachable from here) rather than promoting a two-line layout into a
/// shared file — promote it if a fourth caller needs it.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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

/// `styles.section` — hairline top border + vertical padding.
private struct RuntimeSection<Content: View>: View {
    var t: Theme
    var testID: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 0.5) }
            .accessibilityIdentifier(ifPresent: testID)
    }
}

/// `styles.card`.
private struct RuntimeCard<Content: View>: View {
    var t: Theme
    var testID: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(10)
            .background(t.card)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier(ifPresent: testID)
    }
}

/// `styles.screenInner`.
private struct ScreenInner<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.vertical, 8)
    }
}

private extension Text {
    func runtimeHeading(_ t: Theme) -> some View { font(.system(size: 15, weight: .bold)).foregroundStyle(t.text) }
    func runtimeMeta(_ t: Theme) -> some View { font(.system(size: 12)).foregroundStyle(t.textMuted) }
    func runtimeOk(_ t: Theme) -> some View { font(.system(size: 13, weight: .semibold)).foregroundStyle(t.success) }
    func runtimeWarn(_ t: Theme) -> some View { font(.system(size: 13, weight: .semibold)).foregroundStyle(t.warning) }
    func runtimeError(_ t: Theme) -> some View { font(.system(size: 13, weight: .semibold)).foregroundStyle(t.danger) }
}

/// `styles.input`.
private extension View {
    func runtimeInputStyle(_ t: Theme) -> some View {
        self
            .font(.system(size: 14))
            .foregroundStyle(t.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 220, minHeight: 34, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.border, lineWidth: 1))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// ISO-8601 with fractional seconds, matching the rest of the app's timestamp stamping.
/// ponytail: each module in this codebase keeps its own private copy of this exact helper
/// (FieldRuntime/RestartRecovery.swift, FieldDomain/SubmitFieldTicket.swift, FieldData/*) rather
/// than sharing one across module boundaries — this file follows the same established pattern.
private func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// JS `Number(string)` coercion: trims, empty string -> 0, otherwise parses or NaN. Several TS
/// validations here (`Number(quantity) < 0`) rely on this exact behavior (a blank field parses as
/// 0, not an error) — ported faithfully rather than "fixed".
private func jsNumber(_ s: String) -> Double {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return 0 }
    return Double(trimmed) ?? .nan
}

private func ids(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func fieldValue(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "unknown" }
    return value
}

private func gateLabel(_ gate: FieldWorkGate) -> String {
    switch gate {
    case .unlocked:
        return "Field work unlocked"
    case .locked(let reason, _):
        return "Field work locked: \(fieldWorkGateLockReason(reason))"
    }
}

/// Locked reason when `gate` is present AND locked; nil when unlocked or absent (an absent gate is
/// never treated as locked — mirrors the TS `props.gate?.state === 'locked'` optional-chained check).
private func isLocked(_ gate: FieldWorkGate?) -> FieldWorkGate.LockedReason? {
    guard let gate, case .locked(let reason, _) = gate else { return nil }
    return reason
}

private let WORKFLOW_STEP_LABELS: [WorkflowStepType: String] = [
    .preTripDvir: "pre-trip DVIR",
    .jha: "JHA/JSA per SR",
    .postTripDvir: "post-trip DVIR",
]

/// Map an SR status to a badge tone (spec 8.6). Color reinforces; the StatusBadge label carries it.
private func assignmentStatusTone(_ status: String) -> Tone {
    switch status {
    case "assigned", "in_progress":
        return .info
    case "on_hold":
        return .warning
    case "completed":
        return .success
    case "cancelled":
        return .danger
    default:
        return .neutral
    }
}

private func workflowLabel(_ assignment: HubAssignment) -> String {
    guard let req = assignment.details?.workflowRequirements else { return "Workflow none configured" }
    let labels = req.requiredSteps.map { WORKFLOW_STEP_LABELS[$0] ?? "" }
    return labels.isEmpty ? "Workflow none configured" : "Workflow \(labels.joined(separator: ", "))"
}

/// Per-SR sync state -> which existing text style conveys urgency (text label always present, so
/// this is never color-alone — spec 8.6).
@ViewBuilder
private func srSyncStyled(_ text: Text, _ state: SrSyncState, _ t: Theme) -> some View {
    switch state {
    case .noLocalWork: text.runtimeMeta(t)
    case .synced: text.runtimeOk(t)
    case .needsSync: text.runtimeWarn(t)
    case .needsReview: text.runtimeError(t)
    }
}

// MARK: - Assignment card (shared by the inbox + Today screen)

private struct AssignmentCard: View {
    var t: Theme
    var assignment: HubAssignment
    var syncState: SrSyncState
    var onPress: (() -> Void)?

    var body: some View {
        let d = assignment.details
        let srNo = d?.requestNo ?? assignment.serviceRequestId
        let wells = d?.wells?.map(\.name).joined(separator: ", ")
        let status = d?.status?.rawValue ?? "unknown"

        let inner = VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 8) {
                Text("SR \(srNo)").runtimeHeading(t)
                StatusBadge(
                    label: status, tone: assignmentStatusTone(status), testID: "status-\(assignment.serviceRequestId)")
            }
            Text("Customer \(fieldValue(d?.customer?.name))").runtimeMeta(t)
            Text("Lease \(fieldValue(d?.lease?.name))").runtimeMeta(t)
            Text("Wells \(fieldValue(wells))").runtimeMeta(t)
            Text("Material \(fieldValue(d?.material))").runtimeMeta(t)
            Text("Disposal \(fieldValue(d?.disposalSite?.name))").runtimeMeta(t)
            Text("Vehicle \(fieldValue(d?.vehicle?.name))").runtimeMeta(t)
            Text("Trailer \(fieldValue(d?.trailer?.name))").runtimeMeta(t)
            Text(workflowLabel(assignment)).runtimeMeta(t)
            srSyncStyled(Text("Last sync: \(SR_SYNC_STATE_LABELS[syncState] ?? "")"), syncState, t)
                .accessibilityIdentifier("sync-\(assignment.serviceRequestId)")
        }
        .padding(10)
        .background(t.card)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        return Group {
            if let onPress {
                Button(action: onPress) { inner }.buttonStyle(.plain)
            } else {
                inner
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Service request \(srNo), status \(status), \(SR_SYNC_STATE_LABELS[syncState] ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("assignment-card-\(assignment.serviceRequestId)")
    }
}

// MARK: - Assignment detail

struct AssignmentDetailScreen: View {
    var assignment: HubAssignment?
    var syncState: SrSyncState?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = envTheme
        RuntimeSection(t: t, testID: "assignment-detail") {
            if let assignment {
                let d = assignment.details
                let wellNames = d?.wells?.map(\.name).joined(separator: ", ")
                let srNo = d?.requestNo ?? assignment.serviceRequestId
                let status = d?.status?.rawValue ?? "unknown"

                FlowLayout(spacing: 8) {
                    Text("SR \(srNo)").runtimeHeading(t)
                    StatusBadge(label: status, tone: assignmentStatusTone(status), testID: "detail-status")
                }
                if let syncState {
                    srSyncStyled(Text("Sync: \(SR_SYNC_STATE_LABELS[syncState] ?? "")"), syncState, t)
                        .accessibilityIdentifier("detail-sync")
                }
                Text("Customer \(fieldValue(d?.customer?.name))").runtimeMeta(t)
                Text("Lease \(fieldValue(d?.lease?.name))").runtimeMeta(t)
                Text("Wells \(fieldValue(wellNames))").runtimeMeta(t)
                Text("Material \(fieldValue(d?.material))").runtimeMeta(t)
                Text("Disposal \(fieldValue(d?.disposalSite?.name))").runtimeMeta(t)
                Text("Vehicle \(fieldValue(d?.vehicle?.name))").runtimeMeta(t)
                Text("Trailer \(fieldValue(d?.trailer?.name))").runtimeMeta(t)
                Text("Job type \(fieldValue(d?.jobType?.name))").runtimeMeta(t)
                Text(workflowLabel(assignment)).runtimeMeta(t)
                Text(
                    "Snapshot \(assignment.snapshotHash) \u{00B7} Server version \(assignment.latestServerVersion ?? "unknown")"
                ).runtimeMeta(t)
            } else {
                Text("Assignment").runtimeHeading(t)
                Text("No assignment selected").runtimeWarn(t)
            }
        }
    }
}

// MARK: - Assignment inbox

struct AssignmentInboxScreen: View {
    var assignments: [HubAssignment]
    var syncStateById: [String: SrSyncState]
    var selectedFilter: InboxFilter
    var onSelectFilter: (InboxFilter) -> Void
    var onSelectAssignment: ((String) -> Void)?

    @Environment(\.fieldTheme) private var t

    var body: some View {
        let filtered = filterAssignments(assignments, syncStateById, selectedFilter)
        RuntimeSection(t: t, testID: "assignment-inbox") {
            Text("Assignments").runtimeHeading(t)
            FlowLayout(spacing: 8) {
                ForEach(INBOX_FILTERS, id: \.self) { filter in
                    let count = filterAssignments(assignments, syncStateById, filter).count
                    let selected = filter == selectedFilter
                    RuntimeChip(
                        t: t,
                        label: "\(INBOX_FILTER_LABELS[filter] ?? "") (\(count))",
                        selected: selected,
                        testID: "filter-\(filter.rawValue)",
                        accessibilityLabel:
                            "\(INBOX_FILTER_LABELS[filter] ?? "") filter, \(count) \(count == 1 ? "assignment" : "assignments")",
                        onPress: { onSelectFilter(filter) }
                    )
                }
            }
            if filtered.isEmpty {
                Text("No assignments in this view").runtimeWarn(t).accessibilityIdentifier("inbox-empty")
            } else {
                ForEach(filtered, id: \.serviceRequestId) { assignment in
                    AssignmentCard(
                        t: t,
                        assignment: assignment,
                        syncState: syncStateById[assignment.serviceRequestId] ?? .noLocalWork,
                        onPress: onSelectAssignment != nil ? { onSelectAssignment?(assignment.serviceRequestId) } : nil
                    )
                }
            }
        }
    }
}

// MARK: - Today dashboard

/**
 * Today dashboard (spec 7.4): the day's work as a priority ladder — office-review needs first,
 * then work owed to Hub, then in-progress / assigned / on-hold — with a one-line summary. Reuses
 * the SRs-tab AssignmentCard so a tap opens the same detail. Pure ranking lives in the domain.
 */
struct TodayScreen: View {
    var assignments: [HubAssignment]
    var syncStateById: [String: SrSyncState]
    var onSelectAssignment: ((String) -> Void)?

    @Environment(\.fieldTheme) private var t

    var body: some View {
        let ranked = rankTodayAssignments(assignments, syncStateById)
        let countBy: (SrSyncState) -> Int = { state in
            ranked.filter { (syncStateById[$0.serviceRequestId] ?? .noLocalWork) == state }.count
        }
        let needsReview = countBy(.needsReview)
        let needsSync = countBy(.needsSync)
        let summary =
            "\(ranked.count) \(ranked.count == 1 ? "assignment" : "assignments")"
            + (needsReview > 0 ? " \u{00B7} \(needsReview) need review" : "")
            + (needsSync > 0 ? " \u{00B7} \(needsSync) need sync" : "")

        RuntimeSection(t: t, testID: "today") {
            Text("Today").runtimeHeading(t)
            Text(summary).runtimeMeta(t).accessibilityIdentifier("today-summary")
            if ranked.isEmpty {
                Text("No assignments today").runtimeWarn(t).accessibilityIdentifier("today-empty")
            } else {
                ForEach(ranked, id: \.serviceRequestId) { assignment in
                    AssignmentCard(
                        t: t,
                        assignment: assignment,
                        syncState: syncStateById[assignment.serviceRequestId] ?? .noLocalWork,
                        onPress: onSelectAssignment != nil ? { onSelectAssignment?(assignment.serviceRequestId) } : nil
                    )
                }
            }
        }
    }
}

// MARK: - Field ticket capture — tank-form helpers

/// One tank's gauge fields as editable strings (inputs are strings; parsed to numbers on save).
/// Mirrors the paper ticket's two side-by-side tank panels.
private struct TankForm {
    var label: String
    var locationTime: String
    var barrelsPulled: String
    var bTotalFt: String
    var bTotalIn: String
    var bWaterFt: String
    var bWaterIn: String
    var bCondFt: String
    var bCondIn: String
    var eTotalFt: String
    var eTotalIn: String
    var eWaterFt: String
    var eWaterIn: String
    var eCondFt: String
    var eCondIn: String
    var wpFt: String
    var wpIn: String
}

private struct LineForm {
    var description: String
    var qty: String
}

/// JS `String(number)` coercion for a display field: `3` not `3.0`, `3.5` stays `3.5`.
/// ponytail: no byte-exact contract test for this display text, so exact IEEE754-vs-Double tie
/// behavior is not chased further than this (same simplification FieldAdapters' own
/// `jsNumberString` documents for the PT-210 diagnostic receipt).
private func numToStr(_ n: Double?) -> String {
    guard let n else { return "" }
    return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
}

private func strToNum(_ v: String) -> Double? {
    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let n = Double(trimmed), n.isFinite else { return nil }
    return n
}

private func ftInFrom(_ ft: String, _ inch: String) -> FtIn? {
    let f = strToNum(ft)
    let i = strToNum(inch)
    if f == nil, i == nil { return nil }
    return FtIn(ft: f, inches: i)
}

private func readingFrom(
    totalFt: String, totalIn: String, waterFt: String, waterIn: String, condFt: String, condIn: String
) -> FieldDomain.GaugeReading? {
    let total = ftInFrom(totalFt, totalIn)
    let water = ftInFrom(waterFt, waterIn)
    let condensate = ftInFrom(condFt, condIn)
    if total == nil, water == nil, condensate == nil { return nil }
    return FieldDomain.GaugeReading(total: total, water: water, condensate: condensate)
}

private func emptyTankForm(_ label: String) -> TankForm {
    TankForm(
        label: label, locationTime: "", barrelsPulled: "",
        bTotalFt: "", bTotalIn: "", bWaterFt: "", bWaterIn: "", bCondFt: "", bCondIn: "",
        eTotalFt: "", eTotalIn: "", eWaterFt: "", eWaterIn: "", eCondFt: "", eCondIn: "",
        wpFt: "", wpIn: ""
    )
}

private func tankToForm(_ g: TankGauge?, _ fallbackLabel: String) -> TankForm {
    guard let g else { return emptyTankForm(fallbackLabel) }
    return TankForm(
        label: g.label ?? fallbackLabel,
        locationTime: g.locationTime ?? "",
        barrelsPulled: numToStr(g.barrelsPulled),
        bTotalFt: numToStr(g.beginning?.total?.ft),
        bTotalIn: numToStr(g.beginning?.total?.inches),
        bWaterFt: numToStr(g.beginning?.water?.ft),
        bWaterIn: numToStr(g.beginning?.water?.inches),
        bCondFt: numToStr(g.beginning?.condensate?.ft),
        bCondIn: numToStr(g.beginning?.condensate?.inches),
        eTotalFt: numToStr(g.ending?.total?.ft),
        eTotalIn: numToStr(g.ending?.total?.inches),
        eWaterFt: numToStr(g.ending?.water?.ft),
        eWaterIn: numToStr(g.ending?.water?.inches),
        eCondFt: numToStr(g.ending?.condensate?.ft),
        eCondIn: numToStr(g.ending?.condensate?.inches),
        wpFt: numToStr(g.waterPulled?.ft),
        wpIn: numToStr(g.waterPulled?.inches)
    )
}

/// Returns nil unless the driver entered actual readings — a default/typed label or location
/// time ALONE is not data (otherwise the seeded "Truck"/"Trailer" labels would emit empty tanks).
private func formToTank(_ form: TankForm) -> TankGauge? {
    let beginning = readingFrom(
        totalFt: form.bTotalFt, totalIn: form.bTotalIn, waterFt: form.bWaterFt, waterIn: form.bWaterIn,
        condFt: form.bCondFt, condIn: form.bCondIn
    )
    let ending = readingFrom(
        totalFt: form.eTotalFt, totalIn: form.eTotalIn, waterFt: form.eWaterFt, waterIn: form.eWaterIn,
        condFt: form.eCondFt, condIn: form.eCondIn
    )
    let waterPulled = ftInFrom(form.wpFt, form.wpIn)
    let barrelsPulled = strToNum(form.barrelsPulled)
    if beginning == nil, ending == nil, waterPulled == nil, barrelsPulled == nil { return nil }
    let label = form.label.trimmingCharacters(in: .whitespacesAndNewlines)
    let locationTime = form.locationTime.trimmingCharacters(in: .whitespacesAndNewlines)
    return TankGauge(
        label: label.isEmpty ? nil : label,
        locationTime: locationTime.isEmpty ? nil : locationTime,
        beginning: beginning,
        ending: ending,
        waterPulled: waterPulled,
        barrelsPulled: barrelsPulled
    )
}

/// Assemble the full paper-ticket detail from the form state; nil when nothing was entered.
private func buildTicketDetail(
    rigNo: String, yardArrival: String, timeIn: String, timeOut: String,
    tank0: TankForm, tank1: TankForm, lines: [LineForm]
) -> FieldTicketDetail? {
    let trimmedRigNo = rigNo.trimmingCharacters(in: .whitespacesAndNewlines)
    let ya = yardArrival.trimmingCharacters(in: .whitespacesAndNewlines)
    let ti = timeIn.trimmingCharacters(in: .whitespacesAndNewlines)
    let to = timeOut.trimmingCharacters(in: .whitespacesAndNewlines)
    let times: FieldTicketTimes? =
        (ya.isEmpty && ti.isEmpty && to.isEmpty)
        ? nil
        : FieldTicketTimes(
            yardArrival: ya.isEmpty ? nil : ya,
            timeIn: ti.isEmpty ? nil : ti,
            timeOut: to.isEmpty ? nil : to
        )
    let tanks = [formToTank(tank0), formToTank(tank1)].compactMap { $0 }
    let lineItems: [TicketLineItem] =
        lines
        .map { (description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines), qty: strToNum($0.qty)) }
        .filter { !$0.description.isEmpty }
        .map { TicketLineItem(description: $0.description, qty: $0.qty) }

    if trimmedRigNo.isEmpty, times == nil, tanks.isEmpty, lineItems.isEmpty {
        return nil
    }
    return FieldTicketDetail(
        rigNo: trimmedRigNo.isEmpty ? nil : trimmedRigNo,
        times: times,
        tanks: tanks.isEmpty ? nil : tanks,
        lineItems: lineItems.isEmpty ? nil : lineItems
    )
}

/// One tank panel — beginning + ending gauges (total/water/condensate ft+in), water pulled, barrels.
private struct TankPanel: View {
    var t: Theme
    var title: String
    var idPrefix: String
    @Binding var form: TankForm

    private func field(_ key: String, _ binding: Binding<String>, _ placeholder: String, _ numeric: Bool) -> some View {
        TextField(placeholder, text: binding)
            .keyboardType(numeric ? .decimalPad : .default)
            .runtimeInputStyle(t)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(title) \(placeholder)")
            .accessibilityIdentifier("\(idPrefix)-\(key)")
    }

    private func gaugeRow(
        _ label: String, _ ftKey: String, _ ftBinding: Binding<String>, _ inKey: String, _ inBinding: Binding<String>
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).runtimeMeta(t).frame(maxWidth: .infinity, alignment: .leading)
            field(ftKey, ftBinding, "ft", true)
            field(inKey, inBinding, "in", true)
        }
    }

    var body: some View {
        RuntimeCard(t: t, testID: "\(idPrefix)-panel") {
            Text(title).runtimeHeading(t)
            field("label", $form.label, "Tank", false)
            Spacer().frame(height: 6)
            field("locationTime", $form.locationTime, "Location time", false)
            Text("Beginning gauge").runtimeMeta(t).padding(.top, 8)
            gaugeRow("Total", "bTotalFt", $form.bTotalFt, "bTotalIn", $form.bTotalIn)
            gaugeRow("Water", "bWaterFt", $form.bWaterFt, "bWaterIn", $form.bWaterIn)
            gaugeRow("Condensate", "bCondFt", $form.bCondFt, "bCondIn", $form.bCondIn)
            Text("Ending gauge").runtimeMeta(t).padding(.top, 8)
            gaugeRow("Total", "eTotalFt", $form.eTotalFt, "eTotalIn", $form.eTotalIn)
            gaugeRow("Water", "eWaterFt", $form.eWaterFt, "eWaterIn", $form.eWaterIn)
            gaugeRow("Condensate", "eCondFt", $form.eCondFt, "eCondIn", $form.eCondIn)
            gaugeRow("Water pulled", "wpFt", $form.wpFt, "wpIn", $form.wpIn)
            Spacer().frame(height: 6)
            field("barrelsPulled", $form.barrelsPulled, "Barrels pulled", true)
        }
    }
}

// MARK: - Ticket capture

/**
 * Author/edit the field-ticket draft for one SR (spec 7.10). Fields map 1:1 to the V1 submit
 * payload (ticket_no / quantity_bbl / disposal_ticket_no). One editable draft per SR: an existing
 * draft loads on mount; Save upserts it; Delete removes it. The clock gate blocks authoring just
 * like every other field action.
 */
struct TicketCaptureScreen: View {
    var draftStore: FieldTicketDraftStore
    var serviceRequestId: String
    /// The SR's human-readable request number (e.g. "2026-000001"). An internal id is never
    /// substituted when the assignment has not yet provided a request number.
    var requestNo: String?
    /// The authenticated driver's identity. Never a visible, editable field.
    var driverName: String?
    var gate: FieldWorkGate?
    var identity: CaptureIdentity
    var now: (() -> Date)?
    var onSaved: ((FieldTicketDraft) -> Void)?
    var onDeleted: (() -> Void)?

    @Environment(\.fieldTheme) private var t

    @State private var quantity: String
    @State private var disposalTicketNo: String
    @State private var truck: String
    @State private var trailer: String
    @State private var notes: String
    @State private var captureMethod: TicketCaptureMethod
    @State private var draftId: String?
    @State private var createdAt: String?
    @State private var rigNo: String
    @State private var yardArrival: String
    @State private var timeIn: String
    @State private var timeOut: String
    @State private var tank0: TankForm
    @State private var tank1: TankForm
    @State private var lines: [LineForm]
    @State private var message: RuntimeMessage?
    @State private var loadedServiceRequestId: String?

    private var ticketNo: String { requestNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var ticketDisplayNo: String { ticketNo.isEmpty ? "Not provided by Hub" : ticketNo }
    private var nowFn: () -> Date { now ?? { Date() } }

    init(
        draftStore: FieldTicketDraftStore,
        serviceRequestId: String,
        requestNo: String? = nil,
        driverName: String? = nil,
        gate: FieldWorkGate? = nil,
        identity: CaptureIdentity,
        now: (() -> Date)? = nil,
        onSaved: ((FieldTicketDraft) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.draftStore = draftStore
        self.serviceRequestId = serviceRequestId
        self.requestNo = requestNo
        self.driverName = driverName
        self.gate = gate
        self.identity = identity
        self.now = now
        self.onSaved = onSaved
        self.onDeleted = onDeleted

        _quantity = State(initialValue: "")
        _disposalTicketNo = State(initialValue: "")
        _truck = State(initialValue: "")
        _trailer = State(initialValue: "")
        _notes = State(initialValue: "")
        _captureMethod = State(initialValue: .digital)
        _draftId = State(initialValue: nil)
        _createdAt = State(initialValue: nil)
        _rigNo = State(initialValue: "")
        _yardArrival = State(initialValue: "")
        _timeIn = State(initialValue: "")
        _timeOut = State(initialValue: "")
        _tank0 = State(initialValue: emptyTankForm("Truck"))
        _tank1 = State(initialValue: emptyTankForm("Trailer"))
        _lines = State(initialValue: [LineForm(description: "", qty: "")])
        _message = State(initialValue: nil)
        _loadedServiceRequestId = State(initialValue: nil)
    }

    private func loadExistingDraft() {
        guard loadedServiceRequestId != serviceRequestId else { return }
        do {
            let existing = try draftStore.list().first { $0.serviceRequestId == serviceRequestId }
            quantity = existing.map { numToStr($0.quantityBbl) } ?? ""
            disposalTicketNo = existing?.disposalTicketNo ?? ""
            truck = existing?.truck ?? ""
            trailer = existing?.trailer ?? ""
            notes = existing?.notes ?? ""
            captureMethod = existing?.captureMethod ?? .digital
            draftId = existing?.id
            createdAt = existing?.createdAt
            rigNo = existing?.detail?.rigNo ?? ""
            yardArrival = existing?.detail?.times?.yardArrival ?? ""
            timeIn = existing?.detail?.times?.timeIn ?? ""
            timeOut = existing?.detail?.times?.timeOut ?? ""
            tank0 = tankToForm(existing?.detail?.tanks?[safe: 0], "Truck")
            tank1 = tankToForm(existing?.detail?.tanks?[safe: 1], "Trailer")
            if let items = existing?.detail?.lineItems, !items.isEmpty {
                lines = items.map { LineForm(description: $0.description, qty: numToStr($0.qty)) }
            } else {
                lines = [LineForm(description: "", qty: "")]
            }
            loadedServiceRequestId = serviceRequestId
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not load the saved ticket draft. Your local work is unchanged."
            )
        }
    }

    private func save() {
        if let reason = isLocked(gate) {
            message = RuntimeMessage(kind: .warn, text: "Field work is locked: \(fieldWorkGateLockReason(reason))")
            return
        }
        guard !ticketNo.isEmpty else {
            message = RuntimeMessage(
                kind: .error,
                text: "The Hub has not provided a request number. Refresh the assignment before saving this ticket."
            )
            return
        }
        let qty = jsNumber(quantity)
        guard qty.isFinite, qty >= 0 else {
            message = RuntimeMessage(kind: .error, text: "Quantity must be a non-negative number")
            return
        }
        let id = draftId ?? identity.generateUuid()
        let at = isoStamp(nowFn())
        let driver = driverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = buildTicketDetail(
            rigNo: rigNo, yardArrival: yardArrival, timeIn: timeIn, timeOut: timeOut, tank0: tank0, tank1: tank1,
            lines: lines)
        let trimmedTruck = truck.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrailer = trailer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = FieldTicketDraft(
            id: id,
            serviceRequestId: serviceRequestId,
            ticketNo: ticketNo.trimmingCharacters(in: .whitespacesAndNewlines),
            quantityBbl: qty,
            disposalTicketNo: disposalTicketNo.trimmingCharacters(in: .whitespacesAndNewlines),
            truck: trimmedTruck.isEmpty ? nil : trimmedTruck,
            trailer: trimmedTrailer.isEmpty ? nil : trimmedTrailer,
            driver: driver.flatMap { $0.isEmpty ? nil : $0 },
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            captureMethod: captureMethod,
            detail: detail,
            createdAt: createdAt ?? at,
            updatedAt: at
        )
        do {
            try draftStore.save(draft)
            draftId = id
            createdAt = draft.createdAt
            message = RuntimeMessage(kind: .ok, text: "Ticket draft saved")
            onSaved?(draft)
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not save the ticket draft on this phone. Check storage and try again."
            )
        }
    }

    private func remove() {
        guard let id = draftId else { return }
        do {
            try draftStore.delete(id)
            draftId = nil
            createdAt = nil
            quantity = ""
            disposalTicketNo = ""
            truck = ""
            trailer = ""
            notes = ""
            captureMethod = .digital
            rigNo = ""
            yardArrival = ""
            timeIn = ""
            timeOut = ""
            tank0 = emptyTankForm("Truck")
            tank1 = emptyTankForm("Trailer")
            lines = [LineForm(description: "", qty: "")]
            message = RuntimeMessage(kind: .ok, text: "Draft deleted")
            onDeleted?()
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not delete the ticket draft. Your saved draft is unchanged."
            )
        }
    }

    var body: some View {
        RuntimeSection(t: t, testID: "ticket-capture") {
            Text("Field ticket \u{00B7} SR \(ticketDisplayNo)").runtimeHeading(t)
            Text("Ticket \(ticketDisplayNo)").runtimeMeta(t).accessibilityIdentifier("ticket-no")
            TextField("Quantity (bbl)", text: $quantity)
                .keyboardType(.decimalPad)
                .runtimeInputStyle(t)
                .accessibilityLabel("Quantity in barrels")
                .accessibilityIdentifier("ticket-qty-input")
            TextField("Disposal ticket number", text: $disposalTicketNo)
                .runtimeInputStyle(t)
                .accessibilityLabel("Disposal ticket number")
                .accessibilityIdentifier("ticket-disposal-input")
            TextField("Truck", text: $truck)
                .runtimeInputStyle(t)
                .accessibilityLabel("Truck")
                .accessibilityIdentifier("ticket-truck-input")
            TextField("Trailer", text: $trailer)
                .runtimeInputStyle(t)
                .accessibilityLabel("Trailer")
                .accessibilityIdentifier("ticket-trailer-input")
            TextField("Notes", text: $notes)
                .runtimeInputStyle(t)
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("ticket-notes-input")

            Text("Times & rig").runtimeMeta(t).padding(.top, 8)
            TextField("Rig #", text: $rigNo)
                .runtimeInputStyle(t)
                .accessibilityLabel("Rig number")
                .accessibilityIdentifier("ticket-rig-input")
            TextField("Yard arrival time", text: $yardArrival)
                .runtimeInputStyle(t)
                .accessibilityLabel("Yard arrival time")
                .accessibilityIdentifier("ticket-yard-input")
            TextField("Time in", text: $timeIn)
                .runtimeInputStyle(t)
                .accessibilityLabel("Time in")
                .accessibilityIdentifier("ticket-timein-input")
            TextField("Time out", text: $timeOut)
                .runtimeInputStyle(t)
                .accessibilityLabel("Time out")
                .accessibilityIdentifier("ticket-timeout-input")

            TankPanel(t: t, title: "Tank 1 \u{2014} truck", idPrefix: "ticket-tank0", form: $tank0)
            TankPanel(t: t, title: "Tank 2 \u{2014} trailer", idPrefix: "ticket-tank1", form: $tank1)

            Text("Line items").runtimeHeading(t).padding(.top, 8)
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                HStack(alignment: .center, spacing: 8) {
                    TextField(
                        "Description",
                        text: Binding(get: { lines[idx].description }, set: { lines[idx].description = $0 })
                    )
                    .runtimeInputStyle(t)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Line \(idx + 1) description")
                    .accessibilityIdentifier("ticket-line-desc-\(idx)")
                    TextField("Qty", text: Binding(get: { lines[idx].qty }, set: { lines[idx].qty = $0 }))
                        .keyboardType(.decimalPad)
                        .runtimeInputStyle(t)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Line \(idx + 1) quantity")
                        .accessibilityIdentifier("ticket-line-qty-\(idx)")
                    if lines.count > 1 {
                        RuntimeChip(
                            t: t, label: "Remove", selected: false, testID: "ticket-line-remove-\(idx)",
                            accessibilityLabel: "Remove line \(idx + 1)",
                            onPress: { lines.remove(at: idx) }
                        )
                    }
                }
            }
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "ticket-line-add", label: "Add line",
                    onPress: { lines.append(LineForm(description: "", qty: "")) })
            }
            Text("Rate & total are priced by the Hub.").runtimeMeta(t).padding(.top, 4)

            FlowLayout(spacing: 8) {
                ForEach(TICKET_CAPTURE_METHODS, id: \.self) { method in
                    let selected = method == captureMethod
                    RuntimeChip(
                        t: t, label: method.rawValue, selected: selected, testID: "ticket-capture-\(method.rawValue)",
                        accessibilityLabel: "Capture method \(method.rawValue)",
                        onPress: { captureMethod = method }
                    )
                }
            }
            FlowLayout(spacing: 8) {
                ActionButton(testID: "ticket-save", label: "Save draft", onPress: save)
                if draftId != nil {
                    ActionButton(testID: "ticket-delete", label: "Delete draft", onPress: remove)
                }
            }
            MessageLine(message: message, t: t)
        }
        .task(id: serviceRequestId) { loadExistingDraft() }
    }
}

// MARK: - Receipt capture (functional)

/**
 * Author/edit the receipt draft for one SR (spec 7.10) — the receipt half of the ticket+receipt
 * package. Mirrors `TicketCaptureScreen`: an existing receipt loads on mount, Save upserts, Delete
 * removes; the clock gate blocks authoring. One receipt per (SR, ticket) for now.
 *
 * Named `FieldReceiptCaptureScreen` — see the naming note at the top of this file.
 */
struct FieldReceiptCaptureScreen: View {
    var receiptStore: ReceiptDraftStore
    var serviceRequestId: String
    var requestNo: String?
    var gate: FieldWorkGate?
    var identity: CaptureIdentity
    var now: (() -> Date)?
    var ticketDraftId: String?
    var onSaved: ((FieldDomain.ReceiptDraft) -> Void)?
    var onDeleted: (() -> Void)?

    @Environment(\.fieldTheme) private var t

    @State private var receiptType: ReceiptType
    @State private var vendor: String
    @State private var receiptNo: String
    @State private var amount: String
    @State private var notes: String
    @State private var draftId: String?
    @State private var createdAt: String?
    @State private var message: RuntimeMessage?
    @State private var loadedServiceRequestId: String?

    private var nowFn: () -> Date { now ?? { Date() } }
    private var requestDisplayNo: String {
        let trimmed = requestNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Not provided by Hub" : trimmed
    }

    init(
        receiptStore: ReceiptDraftStore,
        serviceRequestId: String,
        requestNo: String? = nil,
        gate: FieldWorkGate? = nil,
        identity: CaptureIdentity,
        now: (() -> Date)? = nil,
        ticketDraftId: String? = nil,
        onSaved: ((FieldDomain.ReceiptDraft) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil
    ) {
        self.receiptStore = receiptStore
        self.serviceRequestId = serviceRequestId
        self.requestNo = requestNo
        self.gate = gate
        self.identity = identity
        self.now = now
        self.ticketDraftId = ticketDraftId
        self.onSaved = onSaved
        self.onDeleted = onDeleted

        _receiptType = State(initialValue: .disposal)
        _vendor = State(initialValue: "")
        _receiptNo = State(initialValue: "")
        _amount = State(initialValue: "")
        _notes = State(initialValue: "")
        _draftId = State(initialValue: nil)
        _createdAt = State(initialValue: nil)
        _loadedServiceRequestId = State(initialValue: nil)
    }

    private func loadExistingDraft() {
        guard loadedServiceRequestId != serviceRequestId else { return }
        do {
            let existing = try receiptStore.list().first { $0.serviceRequestId == serviceRequestId }
            receiptType = existing?.receiptType ?? .disposal
            vendor = existing?.vendor ?? ""
            receiptNo = existing?.receiptNo ?? ""
            amount = existing.map { numToStr($0.amount) } ?? ""
            notes = existing?.notes ?? ""
            draftId = existing?.id
            createdAt = existing?.createdAt
            loadedServiceRequestId = serviceRequestId
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not load the saved receipt draft. Your local work is unchanged."
            )
        }
    }

    private func save() {
        if let reason = isLocked(gate) {
            message = RuntimeMessage(kind: .warn, text: "Field work is locked: \(fieldWorkGateLockReason(reason))")
            return
        }
        let trimmedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVendor.isEmpty else {
            message = RuntimeMessage(kind: .error, text: "Vendor is required")
            return
        }
        let value = jsNumber(amount)
        guard value.isFinite, value >= 0 else {
            message = RuntimeMessage(kind: .error, text: "Amount must be a non-negative number")
            return
        }
        let id = draftId ?? identity.generateUuid()
        let at = isoStamp(nowFn())
        let draft = FieldDomain.ReceiptDraft(
            id: id,
            serviceRequestId: serviceRequestId,
            receiptType: receiptType,
            vendor: trimmedVendor,
            receiptNo: receiptNo.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: value,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketDraftId: ticketDraftId,
            createdAt: createdAt ?? at,
            updatedAt: at
        )
        do {
            try receiptStore.save(draft)
            draftId = id
            createdAt = draft.createdAt
            message = RuntimeMessage(kind: .ok, text: "Receipt draft saved")
            onSaved?(draft)
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not save the receipt draft on this phone. Check storage and try again."
            )
        }
    }

    private func remove() {
        guard let id = draftId else { return }
        do {
            try receiptStore.delete(id)
            draftId = nil
            createdAt = nil
            vendor = ""
            receiptNo = ""
            amount = ""
            notes = ""
            message = RuntimeMessage(kind: .ok, text: "Receipt deleted")
            onDeleted?()
        } catch {
            message = RuntimeMessage(
                kind: .error,
                text: "Could not delete the receipt draft. Your saved receipt is unchanged."
            )
        }
    }

    var body: some View {
        RuntimeSection(t: t, testID: "receipt-capture") {
            Text("Receipt \u{00B7} SR \(requestDisplayNo)").runtimeHeading(t)
            FlowLayout(spacing: 8) {
                ForEach(RECEIPT_TYPES, id: \.self) { type in
                    let selected = type == receiptType
                    RuntimeChip(
                        t: t, label: type.rawValue, selected: selected, testID: "receipt-type-\(type.rawValue)",
                        accessibilityLabel: nil, onPress: { receiptType = type })
                }
            }
            TextField("Vendor", text: $vendor)
                .runtimeInputStyle(t)
                .accessibilityLabel("Vendor")
                .accessibilityIdentifier("receipt-vendor-input")
            TextField("Receipt number", text: $receiptNo)
                .runtimeInputStyle(t)
                .accessibilityLabel("Receipt number")
                .accessibilityIdentifier("receipt-no-input")
            TextField("Amount", text: $amount)
                .keyboardType(.decimalPad)
                .runtimeInputStyle(t)
                .accessibilityLabel("Amount")
                .accessibilityIdentifier("receipt-amount-input")
            TextField("Notes", text: $notes)
                .runtimeInputStyle(t)
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("receipt-notes-input")
            FlowLayout(spacing: 8) {
                ActionButton(testID: "receipt-save", label: "Save receipt", onPress: save)
                if draftId != nil {
                    ActionButton(testID: "receipt-delete", label: "Delete receipt", onPress: remove)
                }
            }
            MessageLine(message: message, t: t)
        }
        .task(id: serviceRequestId) { loadExistingDraft() }
    }
}

// MARK: - Sync Center

/**
 * Sync Center (spec 7.15): the worker's single answer to "what's saved, synced, failed, and needs
 * review?". Dumb/pure — the caller computes `summary` via `summarizeSyncCenter`. "Retry all" is
 * offered only when work is outstanding.
 */
struct SyncCenterScreen: View {
    var summary: SyncCenterSummary
    var lastHubContactLabel: String?
    var onRetryAll: (() -> Void)?
    var onCopyDiagnostic: (() -> Void)?

    @Environment(\.fieldTheme) private var t

    var body: some View {
        RuntimeSection(t: t, testID: "sync-center") {
            Text("Sync Center").runtimeHeading(t)
            if let lastHubContactLabel {
                Text("Last Hub contact: \(lastHubContactLabel)").runtimeMeta(t).accessibilityIdentifier(
                    "last-hub-contact")
            }
            ForEach(SYNC_CENTER_ORDER, id: \.self) { category in
                Text("\(SYNC_CENTER_LABELS[category] ?? ""): \(summary.counts[category] ?? 0)")
                    .runtimeMeta(t)
                    .accessibilityIdentifier("sync-row-\(category.rawValue)")
            }
            if summary.hasOutstanding {
                if let onRetryAll {
                    ActionButton(testID: "sync-retry-all", label: "Retry all", onPress: onRetryAll)
                }
            } else {
                Text("All work is accepted by Hub").runtimeOk(t).accessibilityIdentifier("sync-all-clear")
            }
            if let onCopyDiagnostic {
                ActionButton(testID: "sync-copy-diagnostic", label: "Copy diagnostic", onPress: onCopyDiagnostic)
            }
        }
    }
}

// MARK: - More / Settings

/**
 * More / Settings: Hub environment + read-only URL (informational), an honest storage-durability
 * line, the offline-policy explanation, copy-diagnostic, and sign-out. Sign-out PRESERVES unsynced
 * local work (cross-cutting invariant) — the copy says so plainly.
 */
struct MoreScreen: View {
    var appEnv: String
    var hubUrl: String?
    var durability: String
    var appVersion: String?
    var onSignOut: () async -> Void
    var onCopyDiagnostic: (() -> Void)?

    @Environment(\.fieldTheme) private var t

    var body: some View {
        RuntimeSection(t: t, testID: "more-screen") {
            Text("More").runtimeHeading(t)
            Text("Hub environment: \(appEnv)").runtimeMeta(t).accessibilityIdentifier("more-hub-env")
            Text("Hub URL: \(hubUrl ?? "not configured")").runtimeMeta(t).accessibilityIdentifier("more-hub-url")
            Text("Local storage: \(durability)").runtimeMeta(t)
            if let appVersion {
                Text("Version: \(appVersion)").runtimeMeta(t)
            }
            Text(
                "Field Capture works offline. Captured work is saved on this phone and synced to Ops Hub when a connection returns \u{2014} it is never lost or auto-deleted."
            )
            .runtimeMeta(t)
            Text("Signing out keeps your unsynced work safe on this phone.").runtimeMeta(t)
            if let onCopyDiagnostic {
                ActionButton(testID: "more-copy-diagnostic", label: "Copy diagnostic info", onPress: onCopyDiagnostic)
            }
            ActionButton(testID: "more-sign-out", label: "Sign out", onPress: { Task { await onSignOut() } })
        }
    }
}

// MARK: - Location validation

private let LOCATION_PLACE_KINDS: [LocationPlaceKind] = [.yard, .disposalSite, .wellSite, .other]

private func locationPlaceLabel(_ kind: LocationPlaceKind) -> String {
    switch kind {
    case .yard: return "Yard"
    case .disposalSite: return "Disposal Site"
    case .wellSite: return "Well Site"
    case .other: return "Other"
    }
}

private func locationStateLabel(_ state: LocationEvidenceState) -> String {
    switch state {
    case .notCaptured: return "Not Captured"
    case .captured: return "Captured"
    case .verified: return "Verified"
    case .outsideExpectedArea: return "Outside Expected Area"
    case .unverified: return "Unverified"
    case .rejected: return "Needs Attention"
    case .gpsUnavailable: return "GPS Unavailable"
    case .manualOnly: return "Saved Without GPS"
    }
}

/**
 * Location validation (spec 7.13 / Phase 7) — VALIDATION ONLY, not navigation. Pick a place, take a
 * single-shot GPS fix, classify it against the assignment's expected area, and save it as durable,
 * non-evictable evidence. Unknown wells save as "Unverified Location Evidence"; a failed fix saves
 * "gps-unavailable" — the phone never fakes a verified location.
 */
struct LocationValidationScreen: View {
    var locationStore: LocationEvidenceStore
    var serviceRequestId: String
    var gate: FieldWorkGate?
    var expectedArea: (lat: Double, lon: Double, radiusM: Double)?
    var captureGps: () async -> LocationGpsPoint?
    var identity: CaptureIdentity
    var now: (() -> Date)?
    var onSaved: ((LocationEvidence) throws -> Void)?

    @Environment(\.fieldTheme) private var t
    @State private var placeKind: LocationPlaceKind = .wellSite
    @State private var evidenceType = "arrival"
    @State private var message: RuntimeMessage?
    @State private var lastState: LocationEvidenceState?

    private var nowFn: () -> Date { now ?? { Date() } }

    private func guardUnlocked() -> Bool {
        guard let reason = isLocked(gate) else { return true }
        message = RuntimeMessage(kind: .warn, text: "Field work is locked: \(fieldWorkGateLockReason(reason))")
        return false
    }

    private func save(_ gps: LocationGpsPoint?, _ manualOnly: Bool) {
        guard guardUnlocked() else { return }
        let state = classifyLocationEvidence(
            LocationClassifyInput(
                gps: gps,
                expected: expectedArea.map { ExpectedArea(lat: $0.lat, lon: $0.lon, radiusM: $0.radiusM) },
                manualOnly: manualOnly ? true : nil,
                gpsUnavailable: (gps == nil && !manualOnly) ? true : nil
            ))
        let trimmedType = evidenceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = LocationEvidence(
            id: identity.generateUuid(),
            serviceRequestId: serviceRequestId,
            placeKind: placeKind,
            evidenceType: trimmedType.isEmpty ? "location" : trimmedType,
            gps: gps,
            state: state,
            createdAt: isoStamp(nowFn())
        )
        do {
            try locationStore.record(evidence)
        } catch {
            message = RuntimeMessage(kind: .error, text: "Could not save location evidence: \(error)")
            return
        }
        lastState = state
        do {
            try onSaved?(evidence)
            message = RuntimeMessage(
                kind: state == .verified ? .ok : (state == .outsideExpectedArea ? .error : .warn),
                text: "Location evidence saved: \(locationStateLabel(state))"
            )
        } catch {
            message = RuntimeMessage(
                kind: .warn,
                text: "Location evidence is saved on this phone, but could not be queued for sync. Try Sync again."
            )
        }
    }

    private func captureAndSave() async {
        guard guardUnlocked() else { return }
        let gps = await captureGps()
        save(gps, false)
    }

    var body: some View {
        RuntimeSection(t: t, testID: "location-validation") {
            Text("Location validation").runtimeHeading(t)
            FlowLayout(spacing: 8) {
                ForEach(LOCATION_PLACE_KINDS, id: \.self) { kind in
                    let selected = kind == placeKind
                    RuntimeChip(
                        t: t,
                        label: locationPlaceLabel(kind),
                        selected: selected,
                        testID: "location-place-\(kind.rawValue)",
                        accessibilityLabel: nil, onPress: { placeKind = kind })
                }
            }
            TextField("Evidence type (e.g. arrival)", text: $evidenceType)
                .runtimeInputStyle(t)
                .accessibilityLabel("Evidence type")
                .accessibilityIdentifier("location-type-input")
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "location-capture", label: "Capture GPS", onPress: { Task { await captureAndSave() } })
                ActionButton(
                    testID: "location-manual", label: "Save as Unverified Location Evidence",
                    onPress: { save(nil, true) })
            }
            if let lastState {
                Text("Status: \(locationStateLabel(lastState))").runtimeMeta(t).accessibilityIdentifier(
                    "location-state")
            }
            MessageLine(message: message, t: t)
        }
    }
}

// MARK: - Field workflow (DVIR / JHA / ticket gate)

private func formStatus(_ forms: FieldFormStore, _ formId: String) -> String {
    do {
        guard let record = try forms.get(formId) else { return "not-started" }
        return record.lastError.map { "\(record.status.rawValue) (\($0))" } ?? record.status.rawValue
    } catch {
        return "status-unavailable"
    }
}

private func dvirForm(formId: String, kind: DvirKind, vehicleRef: String, signatureText: String) -> DvirForm {
    // `InspectionItem` is qualified: PreTripScreens.swift (same app target) declares its own
    // presentational `struct InspectionItem`, which would otherwise shadow FieldContracts' type.
    DvirForm(
        formId: formId, kind: kind, vehicleRef: vehicleRef,
        items: [FieldContracts.InspectionItem(itemId: "brakes", label: "Brakes", result: .ok)],
        signatureBlobIds: ids(signatureText)
    )
}

private func jhaForm(
    formId: String, serviceRequestId: String, hazard: String, mitigation: String, signatureText: String
) -> JhaForm {
    // `JhaHazard` is qualified: JhaScreens.swift (same app target) declares its own
    // presentational `struct JhaHazard`, which would otherwise shadow FieldContracts' type.
    JhaForm(
        formId: formId, serviceRequestId: serviceRequestId,
        hazards: [FieldContracts.JhaHazard(hazardId: "h1", description: hazard, mitigation: mitigation)],
        signatureBlobIds: ids(signatureText)
    )
}

private func formatWorkflowResult(_ result: WorkflowActionResult<FieldFormRecord>, _ ok: String) -> RuntimeMessage {
    switch result {
    case .ok:
        return RuntimeMessage(kind: .ok, text: ok)
    case .locked(let reason):
        return RuntimeMessage(kind: .warn, text: "Locked: \(reason)")
    case .invalid(let errors):
        return RuntimeMessage(kind: .error, text: errors.joined(separator: ", "))
    case .frozen(_, let recordStatus):
        return RuntimeMessage(kind: .warn, text: "Frozen: \(recordStatus.rawValue)")
    case .notFound(let formId):
        return RuntimeMessage(kind: .error, text: "Missing form \(formId)")
    }
}

/// The submit callback's result, peeked for an optional `status` field — mirrors the TS
/// `onSubmitTicket: () => Promise<unknown>` handler reading `(result.result as {status?:string})`.
/// Swift has no `unknown`/duck typing, so the submit closure returns this small concrete shape
/// instead (a minimal, necessary deviation — not a TS-exported type, so it isn't in the required
/// export list, but `FieldWorkflowScreen`'s `onSubmitTicket` prop needs it to compile).
struct SubmitTicketOutcome {
    var status: String?
    init(status: String? = nil) { self.status = status }
}

private func jsonEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// Renders `TicketSubmitGuard` the way the TS `JSON.stringify(...)` call did. `TicketSubmitGuard`
/// isn't `Codable` (it wraps `[FieldFormKind]`/reasons only, no wire contract), so this hand-rolls
/// the same key/value shape rather than adding a wire-format conformance nothing else needs.
private func ticketSubmitGuardJSON(_ result: TicketSubmitGuard) -> String {
    switch result {
    case .allowed:
        return "{\"status\":\"allowed\"}"
    case .locked(let reason):
        return "{\"status\":\"locked\",\"reason\":\"\(jsonEscape(reason))\"}"
    case .vehicleUnsafe(let reviewRequired):
        return "{\"status\":\"vehicle-unsafe\",\"reviewRequired\":\(reviewRequired)}"
    case .blocked(let missing):
        let items = missing.map { "\"\(jsonEscape($0.rawValue))\"" }.joined(separator: ",")
        return "{\"status\":\"blocked\",\"missing\":[\(items)]}"
    }
}

struct FieldWorkflowScreen: View {
    var gate: FieldWorkGate
    var workflow: FieldWorkflowService
    var forms: FieldFormStore
    var serviceRequestId: String
    var onSubmitTicket: () async throws -> SubmitTicketOutcome

    @Environment(\.fieldTheme) private var t
    @State private var message: RuntimeMessage?
    @State private var revision = 0
    @State private var preTripSignature = ""
    @State private var postTripSignature = ""
    @State private var vehicleRef = "truck-7"
    @State private var hazard: String
    @State private var mitigation: String
    @State private var jhaSignature: String

    private var preTripId: String { "pre-trip-dvir-\(serviceRequestId)" }
    private var postTripId: String { "post-trip-dvir-\(serviceRequestId)" }
    private var jhaId: String { "jha-jsa-\(serviceRequestId)" }

    // Item 9 — JHA save-as-you-go + don't-re-ask-once-done: seed the editable fields from the
    // durable record keyed jha-jsa-${SR} so progress is remembered across navigation/restart.
    private var jhaRecord: FieldFormRecord? {
        do { return try forms.get(jhaId) } catch { return nil }
    }
    private var jhaDone: Bool {
        guard let jhaRecord else { return false }
        return jhaRecord.status != .draft
    }
    private var jhaCompletedAt: String? {
        guard let jhaRecord, case .jha(let f) = jhaRecord.form else { return nil }
        return f.completedAt
    }

    init(
        gate: FieldWorkGate, workflow: FieldWorkflowService, forms: FieldFormStore, serviceRequestId: String,
        onSubmitTicket: @escaping () async throws -> SubmitTicketOutcome
    ) {
        self.gate = gate
        self.workflow = workflow
        self.forms = forms
        self.serviceRequestId = serviceRequestId
        self.onSubmitTicket = onSubmitTicket

        let seedJhaId = "jha-jsa-\(serviceRequestId)"
        let seedForm: JhaForm?
        do {
            if case .jha(let form) = try forms.get(seedJhaId)?.form {
                seedForm = form
            } else {
                seedForm = nil
            }
        } catch {
            seedForm = nil
        }
        _hazard = State(initialValue: seedForm?.hazards.first?.description ?? "H2S")
        _mitigation = State(initialValue: seedForm?.hazards.first?.mitigation ?? "monitor")
        _jhaSignature = State(initialValue: seedForm?.signatureBlobIds.first ?? "")
    }

    private func bump() { revision += 1 }

    @discardableResult
    private func persistJhaDraft(
        hazardOverride: String? = nil, mitigationOverride: String? = nil, signatureOverride: String? = nil
    ) throws -> WorkflowActionResult<FieldFormRecord> {
        try workflow.saveDraft(
            .jha(
                jhaForm(
                    formId: jhaId,
                    serviceRequestId: serviceRequestId,
                    hazard: hazardOverride ?? hazard,
                    mitigation: mitigationOverride ?? mitigation,
                    signatureText: signatureOverride ?? jhaSignature
                )))
    }

    private enum JhaField { case hazard, mitigation, signatureText }

    // Save-on-change: each keystroke updates state AND writes the draft (skipped once
    // frozen/done). Failures are swallowed here — the explicit Save surfaces any locked/frozen
    // message; on-change just keeps progress durable.
    private func onChangeJha(_ field: JhaField, _ value: String) {
        switch field {
        case .hazard: hazard = value
        case .mitigation: mitigation = value
        case .signatureText: jhaSignature = value
        }
        guard !jhaDone else { return }
        do {
            switch field {
            case .hazard: _ = try persistJhaDraft(hazardOverride: value)
            case .mitigation: _ = try persistJhaDraft(mitigationOverride: value)
            case .signatureText: _ = try persistJhaDraft(signatureOverride: value)
            }
        } catch {
            message = RuntimeMessage(kind: .error, text: "Could not save the JHA/JSA draft on this phone.")
        }
        bump()
    }

    private func saveDvir(_ kind: DvirKind, _ formId: String, _ sig: String) {
        do {
            let result = try workflow.saveDraft(
                .dvir(dvirForm(formId: formId, kind: kind, vehicleRef: vehicleRef, signatureText: sig)))
            message = formatWorkflowResult(result, "Draft saved")
        } catch {
            message = RuntimeMessage(kind: .error, text: "Could not save the inspection draft on this phone.")
        }
        bump()
    }

    private func complete(_ formId: String) {
        do {
            let result = try workflow.completeForm(formId)
            message = formatWorkflowResult(result, "Completed")
        } catch {
            message = RuntimeMessage(kind: .error, text: "Could not complete the form on this phone.")
        }
        bump()
    }

    private func submit(_ formId: String) {
        do {
            let result = try workflow.submitForm(formId)
            message = formatWorkflowResult(result, "Evidence enqueued")
        } catch {
            message = RuntimeMessage(kind: .error, text: "Could not queue the form for sync.")
        }
        bump()
    }

    private var ticketGuardText: String {
        do {
            return ticketSubmitGuardJSON(
                try workflow.guardTicketSubmit(serviceRequestId, vehicleRef: vehicleRef))
        } catch {
            return "{\"status\":\"unavailable\"}"
        }
    }

    var body: some View {
        ScreenInner {
            Group {
                if case .unlocked = gate {
                    Text(gateLabel(gate)).runtimeOk(t)
                } else {
                    Text(gateLabel(gate)).runtimeWarn(t)
                }
            }
            .accessibilityIdentifier("field-gate")
            MessageLine(message: message, t: t)
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "workflow-refresh-outcomes", label: "Refresh Outcomes",
                    onPress: {
                        do {
                            let result = try workflow.reconcileOutcomes()
                            message = RuntimeMessage(
                                kind: (!result.needsReview.isEmpty || !result.rejected.isEmpty) ? .warn : .ok,
                                text:
                                    "Outcomes accepted \(result.accepted.count) review \(result.needsReview.count) rejected \(result.rejected.count)"
                            )
                        } catch {
                            message = RuntimeMessage(kind: .error, text: "Form outcomes are temporarily unavailable.")
                        }
                        bump()
                    })
            }

            RuntimeSection(t: t) {
                Text("Pre-trip DVIR").runtimeHeading(t)
                Text("status \(formStatus(forms, preTripId))").accessibilityIdentifier("pretrip-status")
                TextField("Vehicle", text: $vehicleRef).runtimeInputStyle(t).accessibilityIdentifier("vehicle-ref")
                TextField("Signature blob id", text: $preTripSignature).runtimeInputStyle(t).accessibilityIdentifier(
                    "pretrip-signature")
                FlowLayout(spacing: 8) {
                    ActionButton(
                        testID: "pretrip-save", label: "Save",
                        onPress: { saveDvir(.preTripDvir, preTripId, preTripSignature) })
                    ActionButton(testID: "pretrip-complete", label: "Complete", onPress: { complete(preTripId) })
                    ActionButton(testID: "pretrip-submit", label: "Submit", onPress: { submit(preTripId) })
                }
            }

            RuntimeSection(t: t) {
                Text("JHA/JSA").runtimeHeading(t)
                Text("status \(formStatus(forms, jhaId))").accessibilityIdentifier("jha-status")
                if jhaDone {
                    RuntimeSection(t: t, testID: "jha-complete-banner") {
                        Text(
                            "JHA/JSA already complete for this SR\(jhaCompletedAt.map { " (\($0))" } ?? "") \u{2014} no need to fill it out again."
                        )
                        .runtimeOk(t)
                        ActionButton(testID: "jha-submit", label: "Submit", onPress: { submit(jhaId) })
                    }
                } else {
                    TextField("Hazard", text: Binding(get: { hazard }, set: { onChangeJha(.hazard, $0) }))
                        .runtimeInputStyle(t).accessibilityIdentifier("jha-hazard")
                    TextField("Mitigation", text: Binding(get: { mitigation }, set: { onChangeJha(.mitigation, $0) }))
                        .runtimeInputStyle(t).accessibilityIdentifier("jha-mitigation")
                    TextField(
                        "Signature blob id",
                        text: Binding(get: { jhaSignature }, set: { onChangeJha(.signatureText, $0) })
                    )
                    .runtimeInputStyle(t).accessibilityIdentifier("jha-signature")
                    FlowLayout(spacing: 8) {
                        ActionButton(
                            testID: "jha-save", label: "Save",
                            onPress: {
                                do {
                                    let result = try persistJhaDraft()
                                    message = formatWorkflowResult(result, "Draft saved")
                                } catch {
                                    message = RuntimeMessage(
                                        kind: .error, text: "Could not save the JHA/JSA draft on this phone.")
                                }
                                bump()
                            })
                        ActionButton(testID: "jha-complete", label: "Complete", onPress: { complete(jhaId) })
                        ActionButton(testID: "jha-submit", label: "Submit", onPress: { submit(jhaId) })
                    }
                }
            }

            RuntimeSection(t: t) {
                Text("Post-trip DVIR").runtimeHeading(t)
                Text("status \(formStatus(forms, postTripId))").accessibilityIdentifier("posttrip-status")
                TextField("Signature blob id", text: $postTripSignature).runtimeInputStyle(t).accessibilityIdentifier(
                    "posttrip-signature")
                FlowLayout(spacing: 8) {
                    ActionButton(
                        testID: "posttrip-save", label: "Save",
                        onPress: { saveDvir(.postTripDvir, postTripId, postTripSignature) })
                    ActionButton(testID: "posttrip-complete", label: "Complete", onPress: { complete(postTripId) })
                    ActionButton(testID: "posttrip-submit", label: "Submit", onPress: { submit(postTripId) })
                }
            }

            RuntimeSection(t: t) {
                Text("Ticket Gate").runtimeHeading(t)
                Text(ticketGuardText).accessibilityIdentifier("ticket-gate")
                ActionButton(
                    testID: "ticket-submit", label: "Submit Ticket",
                    onPress: {
                        Task {
                            do {
                                let result = try await workflow.submitTicketWithWorkflow(
                                    serviceRequestId, vehicleRef: vehicleRef, onSubmitTicket)
                                switch result {
                                case .submitted(let value):
                                    let status = value.status ?? "complete"
                                    let ok = status == "accepted" || status == "submitted"
                                    message = RuntimeMessage(
                                        kind: ok ? .ok : .warn,
                                        text: ok ? "Ticket submitted: \(status)" : "Ticket handoff: \(status)")
                                case .locked(let reason):
                                    message = RuntimeMessage(kind: .warn, text: "Locked: \(reason)")
                                case .vehicleUnsafe:
                                    message = RuntimeMessage(
                                        kind: .error,
                                        text:
                                            "Vehicle certified UNSAFE on the pre-trip DVIR \u{2014} field work is blocked and sent for office review."
                                    )
                                case .blocked(let missing):
                                    message = RuntimeMessage(
                                        kind: .warn,
                                        text: "Ticket blocked: \(missing.map(\.rawValue).joined(separator: ", "))")
                                }
                            } catch {
                                // Not in the TS (which leaves this rejection unhandled) — Swift's async
                                // throws must be handled; surfaced in the same message slot every other
                                // failure here uses, never silently swallowed.
                                message = RuntimeMessage(kind: .error, text: "Ticket submit failed: \(error)")
                            }
                            bump()
                        }
                    })
            }
            Text("forms revision \(revision)").runtimeMeta(t)
        }
    }
}

// MARK: - Capture evidence

/// Port of the TS `CaptureEvidenceDevice` — the native photo/import capture seam this screen
/// drives for non-signature attachment kinds.
struct CaptureEvidenceDeviceInput {
    var attachmentKind: AttachBlobKind
    var source: CaptureSource
}

struct CapturedEvidenceBytes {
    var bytes: Data
    var mimeType: String
    var source: CaptureSource
}

typealias CaptureEvidenceDevice = (CaptureEvidenceDeviceInput) async throws -> CapturedEvidenceBytes?

private func captureKindLabel(_ kind: AttachBlobKind) -> String {
    switch kind {
    case .fieldTicketPhoto: return "Field photo"
    case .disposalPhoto: return "Disposal photo"
    case .receiptPhoto: return "Receipt"
    case .signature: return "Signature"
    }
}

private func captureListLine(_ blob: BlobUploadRecord, _ linkState: OutboxItemState?) -> String {
    let status: String
    if linkState == .needsReview {
        status = "Needs Review"
    } else if linkState == .rejected {
        status = "Needs Attention"
    } else if blob.state == .linked {
        status = "Synced"
    } else if blob.state == .uploading || blob.state == .uploaded {
        status = "Syncing"
    } else {
        status = "Saved on Phone"
    }
    return "\(captureKindLabel(blob.attachmentKind)) · \(status)"
}

struct CaptureEvidenceScreen: View {
    var capture: CaptureFlow
    var uploads: UploadEngine
    var blobs: BlobUploadStore
    var parentType: AttachBlobParentType
    var parentId: String
    var linkOutcome: ((String) throws -> OutboxItemState?)?
    var captureDevice: CaptureEvidenceDevice?

    @Environment(\.fieldTheme) private var t
    @State private var message: RuntimeMessage?
    @State private var revision = 0
    @State private var signatureValue: SignatureValue?
    @State private var visibleBlobs: [BlobUploadRecord] = []
    @State private var linkStates: [String: OutboxItemState] = [:]
    @State private var linkStatusError: String?

    private func refreshLinkStates() {
        do {
            let refreshedBlobs = try blobs.list().filter {
                $0.parentType == parentType && $0.parentId == parentId
            }
            var refreshed: [String: OutboxItemState] = [:]
            if let linkOutcome {
                for opId in refreshedBlobs.compactMap(\.linkOpId) {
                    if let state = try linkOutcome(opId) { refreshed[opId] = state }
                }
            }
            visibleBlobs = refreshedBlobs
            linkStates = refreshed
            linkStatusError = nil
        } catch {
            linkStatusError =
                "Evidence list or sync status is temporarily unavailable. Your saved evidence is unchanged."
        }
    }

    private func bump() {
        revision += 1
        refreshLinkStates()
    }

    private func captureOne(_ attachmentKind: AttachBlobKind, _ source: CaptureSource) async {
        do {
            let captured: CapturedEvidenceBytes?
            if attachmentKind == .signature {
                if let signatureValue {
                    captured = CapturedEvidenceBytes(
                        bytes: signatureBytes(signatureValue), mimeType: "image/png", source: .signaturePad)
                } else {
                    captured = nil
                }
            } else {
                captured = try await captureDevice?(
                    CaptureEvidenceDeviceInput(attachmentKind: attachmentKind, source: source))
            }
            guard let captured else {
                message = RuntimeMessage(
                    kind: .warn,
                    text: attachmentKind == .signature
                        ? "Draw a signature before saving it as evidence" : "Capture canceled or unavailable"
                )
                return
            }
            let result: CaptureResult
            if attachmentKind == .signature {
                result = try await capture.captureSignature(
                    bytes: captured.bytes, parentType: parentType, parentId: parentId)
            } else {
                result = try await capture.capture(
                    CaptureInput(
                        bytes: captured.bytes, mimeType: captured.mimeType, source: captured.source,
                        attachmentKind: attachmentKind, parentType: parentType, parentId: parentId
                    ))
            }
            switch result {
            case .locked(let reason):
                message = RuntimeMessage(kind: .warn, text: "Locked: \(reason)")
            case .captured:
                message = RuntimeMessage(kind: .ok, text: "\(captureKindLabel(attachmentKind)) saved on this phone")
                if attachmentKind == .signature { signatureValue = nil }
                bump()
            }
        } catch {
            message = RuntimeMessage(kind: .error, text: "Capture failed: \(error)")
        }
    }

    var body: some View {
        ScreenInner {
            Text("Evidence Capture").runtimeHeading(t)
            MessageLine(message: message, t: t)
            if let linkStatusError {
                Text(linkStatusError).runtimeWarn(t).accessibilityIdentifier("capture-link-status-error")
            }
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "capture-field-ticket-photo", label: "Field Photo",
                    onPress: { Task { await captureOne(.fieldTicketPhoto, .camera) } })
                ActionButton(
                    testID: "capture-disposal-photo", label: "Disposal",
                    onPress: { Task { await captureOne(.disposalPhoto, .camera) } })
                ActionButton(
                    testID: "capture-receipt-photo", label: "Receipt",
                    onPress: { Task { await captureOne(.receiptPhoto, .importSource) } })
                ActionButton(
                    testID: "capture-signature", label: "Signature",
                    onPress: { Task { await captureOne(.signature, .signaturePad) } })
            }
            RuntimeCard(t: t) {
                Text("Signature").runtimeHeading(t)
                SignatureField(
                    theme: t, value: signatureValue, onChange: { signatureValue = $0 },
                    testID: "capture-signature-field")
            }
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "capture-retry", label: "Sync Now",
                    onPress: {
                        Task {
                            do {
                                let report = try await uploads.processOnce()
                                message = RuntimeMessage(
                                    kind: (report.deferred > 0 || report.expired > 0) ? .warn : .ok,
                                    text: report.deferred > 0 || report.expired > 0
                                        ? "Some evidence is still saved on this phone and will retry."
                                        : "Evidence sync is up to date."
                                )
                            } catch {
                                message = RuntimeMessage(
                                    kind: .error,
                                    text: "Could not read or update evidence sync. Your saved evidence is unchanged."
                                )
                            }
                            bump()
                        }
                    })
                ActionButton(testID: "capture-refresh", label: "Refresh", onPress: bump)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleBlobs, id: \.blobId) { blob in
                    let linkState = blob.linkOpId.flatMap { linkStates[$0] }
                    Text(captureListLine(blob, linkState))
                        .runtimeMeta(t)
                }
            }
            .accessibilityIdentifier("capture-list")
        }
        .task { refreshLinkStates() }
    }
}

// MARK: - Print queue

private func printQueueLine(_ job: PrintJob) -> String {
    switch job.status {
    case .queued: return "Ticket print · Waiting to print"
    case .rendering: return "Ticket print · Preparing"
    case .printing: return "Ticket print · Printing"
    case .printed: return "Ticket print · Printed; sync pending"
    case .synced: return "Ticket print · Printed and synced"
    case .failed: return "Ticket print · Needs Attention"
    case .canceled: return "Ticket print · Canceled"
    }
}

struct PrintQueueScreen: View {
    var runtime: PrintRuntime
    var queue: PrintJobQueue

    @Environment(\.fieldTheme) private var t
    @State private var message: RuntimeMessage?
    @State private var revision = 0
    @State private var jobs: [PrintJob] = []
    @State private var listError: String?

    private func refreshJobs() {
        do {
            jobs = try queue.list()
            listError = nil
        } catch {
            listError = "The print queue list is temporarily unavailable. No print job was discarded."
        }
    }

    private func bump() {
        revision += 1
        refreshJobs()
    }

    var body: some View {
        ScreenInner {
            Text("Print Queue").runtimeHeading(t)
            MessageLine(message: message, t: t)
            if let listError {
                Text(listError).runtimeWarn(t).accessibilityIdentifier("print-list-error")
            }
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "print-process", label: "Try Printing",
                    onPress: {
                        Task {
                            do {
                                let report = try await runtime.processOnce()
                                message = RuntimeMessage(
                                    kind: report.failed > 0 ? .warn : .ok,
                                    text: report.failed > 0
                                        ? "Printing needs attention. Check the printer and try again."
                                        : report.printed > 0 ? "Ticket printed." : "No tickets are waiting to print.")
                            } catch {
                                message = RuntimeMessage(
                                    kind: .error,
                                    text: "Could not read or update the print queue. No print job was discarded."
                                )
                            }
                            bump()
                        }
                    })
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(jobs, id: \.printJobId) { job in
                    Text(printQueueLine(job)).runtimeMeta(t)
                }
            }
            .accessibilityIdentifier("print-list")
        }
        .task { refreshJobs() }
    }
}

// MARK: - PT-210 diagnostic

private struct Pt210DiagnosticError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

struct Pt210DiagnosticScreen: View {
    var binding: Pt210PrinterTransport?

    @Environment(\.fieldTheme) private var t
    @State private var transport: Pt210PrinterTransport
    @State private var devices: [DiscoveredBlePrinter] = []
    @State private var selectedDeviceId: String?
    @State private var lines: [String] = []

    init(binding: Pt210PrinterTransport? = nil) {
        self.binding = binding
        // ponytail: the TS `loadPt210NativeBinding()` could return `undefined` without a linked
        // native module, hence `requireBinding()`'s NotImplementedError branch there. The Swift
        // `Pt210PrinterTransport` is always constructible (plain CoreBluetooth wrapper), so that
        // branch has no equivalent here — the transport is seeded once and always present.
        _transport = State(initialValue: binding ?? Pt210PrinterTransport())
    }

    private func append(_ line: String) {
        lines = Array(([line] + lines).prefix(12))
    }

    private func selectedDevice() throws -> String {
        guard let deviceId = selectedDeviceId ?? devices.first?.deviceId else {
            throw Pt210DiagnosticError("no PT-210 device selected")
        }
        return deviceId
    }

    private func record(_ label: String, _ run: () async throws -> String) async {
        do {
            let result = try await run()
            append("\(label) ok: \(result)")
        } catch {
            let normalized = normalizePt210NativeError(error)
            let nativeCode = normalized.nativeCode.map { " \($0)" } ?? ""
            append("\(label) error: \(normalized.code.rawValue)\(nativeCode) \(normalized.message)")
        }
    }

    var body: some View {
        ScreenInner {
            Text("PT-210 Diagnostic").runtimeHeading(t)
            FlowLayout(spacing: 8) {
                ActionButton(
                    testID: "pt210-discover", label: "Discover",
                    onPress: {
                        Task {
                            await record("discover") {
                                let found = try await transport.discover(timeoutMs: 10_000, includeUnpaired: true)
                                devices = found
                                selectedDeviceId = found.first?.deviceId
                                return found.isEmpty ? "none" : found.map(\.name).joined(separator: ", ")
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-connect", label: "Connect",
                    onPress: {
                        Task {
                            await record("connect") {
                                let status = try await transport.connect(try selectedDevice(), timeoutMs: 10_000)
                                return status.state.rawValue
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-test-receipt", label: "Test Receipt",
                    onPress: {
                        Task {
                            await record("print test receipt") {
                                let payload = try createPt210TestReceipt()
                                let status = try await transport.writeBytes(payload, timeoutMs: 10_000)
                                return status.state.rawValue
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-signature-test", label: "Signature Test",
                    onPress: {
                        Task {
                            await record("print signature test") {
                                let payload = try createPt210SignatureBitmapTest()
                                let status = try await transport.writeBytes(payload, timeoutMs: 10_000)
                                return status.state.rawValue
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-status", label: "Status",
                    onPress: {
                        Task {
                            await record("status") {
                                let status = try await transport.status(timeoutMs: 5_000)
                                return status.state.rawValue
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-reconnect", label: "Reconnect",
                    onPress: {
                        Task {
                            await record("reconnect") {
                                let status = try await transport.reconnect(timeoutMs: 10_000)
                                return status.state.rawValue
                            }
                        }
                    })
                ActionButton(
                    testID: "pt210-disconnect", label: "Disconnect",
                    onPress: {
                        Task {
                            await record("disconnect") {
                                try await transport.disconnect()
                                // ponytail: the protocol-conformance `disconnect()` has no
                                // timeoutMs+status overload (unlike connect/writeBytes) — it always
                                // tears down, so report the terminal state directly rather than an
                                // extra status() round-trip.
                                return Pt210ConnectionState.disconnected.rawValue
                            }
                        }
                    })
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).runtimeMeta(t)
                }
            }
            .accessibilityIdentifier("pt210-diagnostic-log")
        }
    }
}
