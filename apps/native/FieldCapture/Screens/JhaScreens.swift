//
//  JhaScreens.swift
//  Ported from apps/mobile/src/screens/JhaScreens.tsx
//
//  JHA/JSA flow (GUI Master §10 / screens 33–43) — the job-specific Job Hazard Analysis the driver
//  completes ON SITE before work begins. The flow walks: Overview → Job and Site → Emergency Info →
//  Pre-Job Safety → PPE → Hazards → Job Steps and Risk → Stop Work Authority → Signatures → Review →
//  Complete. Completing it unlocks the Field Ticket.
//
//  These screens are PRESENTATIONAL ONLY: every screen takes small primitive props + callbacks, and
//  renders design-kit surfaces (Card / FieldButton / StatusBadge). No domain/runtime/data imports, no
//  native modules. Signature capture, GPS, and the real save/sync are wired elsewhere — here a
//  signature is the shared `SignatureField` preview + Sign/Clear. Driver-facing language only: no
//  UUIDs, payloads, queues, or env strings (GUI Master §20). Risk math is computed for the driver
//  (severity × likelihood), never asked of them.
//

import Foundation
import FieldContracts
import SwiftUI

/* ------------------------------------------------------------------ *
 * Shared types + small local helpers
 * ------------------------------------------------------------------ */

/// Driver-facing section status (subset of the GUI Master §20 status vocabulary).
enum JhaSectionStatus: String, Equatable {
    case notStarted = "Not Started"
    case inProgress = "In Progress"
    case required = "Required"
    case complete = "Complete"
    case needsReview = "Needs Review"
}

private let SECTION_TONE: [JhaSectionStatus: Tone] = [
    .notStarted: .neutral,
    .inProgress: .info,
    .required: .warning,
    .complete: .success,
    .needsReview: .warning,
]

struct JhaSection: Equatable {
    var key: String
    var label: String
    var status: JhaSectionStatus
}

/// A read-only labeled field (auto-filled job/site data, emergency info).
struct JhaField: Equatable {
    var label: String
    var value: String
}

/// A single safety-check item rendered as an OK / Not Yet segmented control (never a checkbox).
struct JhaCheckItem: Equatable {
    var key: String
    var label: String
    /// true = confirmed OK, false = not yet / outstanding.
    var ok: Bool
    /// When true the item is sourced from the daily DVIR and is shown read-only here.
    var autoFilled: Bool?
}

struct JhaCheckGroup: Equatable {
    var key: String
    var title: String
    var items: [JhaCheckItem]
}

/// Structural counterpart of the TS `JhaSelectable` interface — lets `SelectTile` render both plain
/// PPE tiles (`JhaSelectable`) and hazard tiles (`JhaHazard`, which structurally extends it) without
/// the TS file's nominal-vs-structural typing gap.
protocol JhaSelectableLike {
    var key: String { get }
    var label: String { get }
    var selected: Bool { get }
}

/// A large selectable PPE / hazard tile.
struct JhaSelectable: JhaSelectableLike, Equatable {
    var key: String
    var label: String
    var selected: Bool
}

/// Risk category derived from the risk score.
enum RiskCategory: String, Equatable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"
}

struct JhaJobStep: Equatable {
    var key: String
    var index: Int
    var title: String
    var hazards: String
    var controls: String
    var severity: Double
    var likelihood: Double
    var initials: String
}

struct JhaSignatureRow: Equatable {
    var key: String
    var role: String
    var name: String
    var dateTime: String
    var required: Bool
    var signed: Bool
}

struct JhaReviewLine: Equatable {
    var label: String
    var value: String
    var done: Bool
}

/// Clamp to 1–5, rounding, and default to 1 for non-finite input (mirrors the TS `Number.isFinite`
/// guard against a bad upstream value).
private func clampRisk(_ value: Double) -> Int {
    if !value.isFinite { return 1 }
    if value < 1 { return 1 }
    if value > 5 { return 5 }
    return Int(value.rounded())
}

/// Compute a 1–25 risk score; the driver never does this math (GUI Master screen 39).
func calcRiskScore(_ severity: Double, _ likelihood: Double) -> Int {
    let s = clampRisk(severity)
    let l = clampRisk(likelihood)
    return s * l
}

/// Map a 1–25 score to a driver-facing category.
func riskCategory(_ score: Int) -> RiskCategory {
    if score >= 17 { return .critical }
    if score >= 10 { return .high }
    if score >= 5 { return .medium }
    return .low
}

private let RISK_TONE: [RiskCategory: Tone] = [
    .low: .success,
    .medium: .info,
    .high: .warning,
    .critical: .danger,
]

/* ------------------------------------------------------------------ *
 * Small presentational sub-components (file-local)
 * ------------------------------------------------------------------ */

private struct FieldRow: View {
    var field: JhaField
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.system(size: typeScale.caption, weight: .semibold))
                .tracking(0.3)
                .textCase(.uppercase)
                .foregroundStyle(theme.textMuted)
            Text(field.value)
                .font(.system(size: typeScale.body, weight: .semibold))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 4)
    }
}

/// OK / Not Yet segmented control. Mirrors the DVIR OK/Defect pattern (GUI Master §23.4): a confirmed
/// item reads "OK", an outstanding one "Not Yet" — never an ambiguous checkbox where checked could
/// mean "problem".
private struct OkSegment: View {
    var ok: Bool
    var disabled: Bool = false
    var onSetOk: (Bool) -> Void
    var theme: Theme
    var testID: String?

    private static let segments: [(value: Bool, label: String, tone: Tone)] = [
        (true, "OK", .success),
        (false, "Not Yet", .warning),
    ]

    var body: some View {
        HStack(spacing: spacing.xs) {
            ForEach(Self.segments, id: \.label) { seg in
                let active = ok == seg.value
                let accent = seg.tone == .success ? theme.success : theme.warning
                Button {
                    onSetOk(seg.value)
                } label: {
                    Text(seg.label)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(active ? theme.onPrimary : theme.textMuted)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 64, minHeight: 40)
                        .background(active ? accent : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(active ? accent : theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .opacity(disabled ? 0.5 : 1)
                .disabled(disabled)
                .accessibilityLabel(seg.label)
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// A large selectable tile (PPE / Hazard). Selected reads as a filled primary tile.
private struct SelectTile: View {
    var item: any JhaSelectableLike
    var onToggle: () -> Void
    var theme: Theme
    var testID: String?

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: typeScale.body, weight: .bold))
                    .foregroundStyle(item.selected ? theme.onPrimary : theme.text)
                Text(item.selected ? "Selected" : "Tap to select")
                    .font(.system(size: typeScale.caption, weight: .semibold))
                    .foregroundStyle(item.selected ? theme.onPrimary : theme.textMuted)
            }
            .padding(.horizontal, spacing.md)
            .padding(.vertical, spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(item.selected ? theme.primary : theme.cardMuted)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(item.selected ? theme.primary : theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(item.selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(ifPresent: testID)
    }
}

private struct JhaTileGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: spacing.sm),
            GridItem(.flexible()),
        ]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing.sm) {
            content
        }
    }
}

/// Stepper control used for severity / likelihood (1–5).
private struct RiskStepper: View {
    var label: String
    var value: Double
    var onChange: (Double) -> Void
    var theme: Theme
    var testID: String?

    var body: some View {
        let value = clampRisk(value)
        HStack {
            Text(label)
                .font(.system(size: typeScale.body, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer()
            HStack(spacing: spacing.sm) {
                Button {
                    onChange(Double(clampRisk(Double(value - 1))))
                } label: {
                    Text("\u{2212}")
                        .font(.system(size: typeScale.heading, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                }
                .opacity(value <= 1 ? 0.4 : 1)
                .disabled(value <= 1)
                .accessibilityLabel("Decrease \(label)")

                Text("\(value)")
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .frame(minWidth: 24)
                    .multilineTextAlignment(.center)

                Button {
                    onChange(Double(clampRisk(Double(value + 1))))
                } label: {
                    Text("+")
                        .font(.system(size: typeScale.heading, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                }
                .opacity(value >= 5 ? 0.4 : 1)
                .disabled(value >= 5)
                .accessibilityLabel("Increase \(label)")
            }
        }
        .accessibilityIdentifier(ifPresent: testID)
    }
}

private struct ScreenHeader<Content: View>: View {
    var title: String
    var subtitle: String?
    var theme: Theme
    @ViewBuilder var children: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(title)
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(theme.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: typeScale.body))
                    .lineSpacing(3)
                    .foregroundStyle(theme.textMuted)
            }
            children()
        }
    }
}

extension ScreenHeader where Content == EmptyView {
    init(title: String, subtitle: String? = nil, theme: Theme) {
        self.init(title: title, subtitle: subtitle, theme: theme, children: { EmptyView() })
    }
}

/// Reusable multiline text field with a placeholder (SwiftUI's `TextEditor` has no built-in one),
/// styled like the RN `input`/`inputMulti` combo.
private struct MultilineField: View {
    @Binding var text: String
    var placeholder: String
    var theme: Theme
    var accessibilityLabelText: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, spacing.md + 4)
                    .padding(.vertical, spacing.sm + 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, spacing.md)
                .padding(.vertical, spacing.sm)
        }
        .frame(minHeight: 64)
        .background(theme.cardMuted)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabelText)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for the PPE/Hazard tile grid and
/// the crew-role chip row. Native `Layout` protocol, no dependency. (File-local copy: `AppHeader.swift`'s
/// `FlowLayout` is `private` to that file.)
private struct JhaFlowLayout: Layout {
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

/* ------------------------------------------------------------------ *
 * 33. JHA/JSA Overview
 * ------------------------------------------------------------------ */

struct JhaOverviewScreen: View {
    var srNumber: String? = nil
    var customer: String? = nil
    var lease: String? = nil
    var sections: [JhaSection]? = nil
    var primaryLabel: String? = nil
    var onBegin: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let srNumber = srNumber ?? "2026-000001"
        let customer = customer ?? "Acme Energy"
        let lease = lease ?? "Northfield Lease"
        let sections =
            sections ?? DEFAULT_SECTIONS.map { JhaSection(key: $0.key, label: $0.label, status: .notStarted) }
        let complete = sections.filter { $0.status == .complete }.count

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "JHA/JSA",
                subtitle:
                    "Complete at the tank battery before loading begins — this covers the on-site work, not the drive.",
                theme: t
            )

            Card(title: "Job", theme: t) {
                Text("SR \(srNumber)")
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(t.text)
                Text("\(customer) \u{00B7} \(lease)")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }

            Card(title: "Progress", tone: .highlight, testID: "jha-progress", theme: t) {
                Text("\(complete) of \(sections.count) sections complete")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                FieldButton(
                    label: primaryLabel ?? "Begin JHA/JSA",
                    onPress: onBegin,
                    testID: "jha-begin",
                    theme: t
                )
            }

            Card(title: "Sections", theme: t) {
                ForEach(sections, id: \.key) { section in
                    HStack {
                        Text(section.label)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.text)
                        Spacer()
                        StatusBadge(label: section.status.rawValue, tone: SECTION_TONE[section.status] ?? .neutral)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("jha-section-\(section.key)")
                }
            }
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_SECTIONS: [(key: String, label: String)] = [
    (key: "job-site", label: "Job and Site"),
    (key: "emergency", label: "Emergency Info"),
    (key: "pre-job", label: "Pre-Job Safety"),
    (key: "ppe", label: "PPE"),
    (key: "hazards", label: "Hazards"),
    (key: "job-steps", label: "Job Steps and Risk"),
    (key: "stop-work", label: "Stop Work Authority"),
    (key: "signatures", label: "Signatures"),
    (key: "review", label: "Review"),
]

/* ------------------------------------------------------------------ *
 * 34. JHA/JSA Job and Site
 * ------------------------------------------------------------------ */

struct JhaJobAndSiteScreen: View {
    var fields: [JhaField]? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme

    private var renderedFields: [JhaField] {
        if let fields { return fields }
        #if DEBUG
            return PREVIEW_JOB_SITE_FIELDS
        #else
            return [
                JhaField(
                    label: "Assignment details",
                    value: "Unavailable — refresh the assignment before starting this JHA/JSA."
                )
            ]
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "Job and Site", subtitle: "Auto-filled from your assignment. Review before continuing.", theme: t
            )

            Card(title: "Job details", theme: t) {
                ForEach(renderedFields, id: \.label) { field in
                    FieldRow(field: field, theme: t)
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: Emergency Info", onPress: onNext, testID: "jha-jobsite-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

#if DEBUG
    private let PREVIEW_JOB_SITE_FIELDS: [JhaField] = [
        JhaField(label: "Company Name", value: "Acme Oilfield Services"),
        JhaField(label: "Customer / Operator", value: "Acme Energy"),
        JhaField(label: "Date", value: "June 16, 2026"),
        JhaField(label: "Prepared By", value: "J. Bailey"),
        JhaField(label: "Driver Name", value: "J. Bailey"),
        JhaField(label: "Supervisor Name", value: "M. Reyes"),
        JhaField(label: "Truck Unit No.", value: "Truck 7"),
        JhaField(label: "Trailer / Tanker No.", value: "Vacuum Trailer 19"),
        JhaField(label: "Job Ticket / Work Order No.", value: "SR 2026-000001"),
        JhaField(label: "Lease / Facility / Well Pad", value: "Northfield 114H"),
        JhaField(label: "County", value: "Reeves County, TX"),
        JhaField(label: "Start Location", value: "Pecos Yard"),
        JhaField(label: "Destination / SWD Facility", value: "Northfield 114H"),
        JhaField(label: "Start Time", value: "06:30"),
        JhaField(label: "Estimated Finish Time", value: "11:00"),
        JhaField(label: "Shift", value: "Day"),
        JhaField(label: "Weather", value: "Clear"),
        JhaField(label: "Temperature", value: "92\u{00B0}F"),
        JhaField(label: "Heat Index", value: "98\u{00B0}F"),
        JhaField(label: "Cell Phone / Radio Channel", value: "Channel 3"),
    ]
#endif

/* ------------------------------------------------------------------ *
 * 35. JHA/JSA Emergency Info
 * ------------------------------------------------------------------ */

struct JhaEmergencyInfoScreen: View {
    var fields: [JhaField]? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme

    private var renderedFields: [JhaField] {
        if let fields { return fields }
        #if DEBUG
            return PREVIEW_EMERGENCY_FIELDS
        #else
            return [
                JhaField(label: "Emergency Services", value: "911"),
                JhaField(
                    label: "Site-specific emergency details",
                    value: "Unavailable — confirm the emergency plan with dispatch before work."
                ),
            ]
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Emergency Info", subtitle: "Know these before work begins.", theme: t)

            Card(title: "If something goes wrong", tone: .highlight, theme: t) {
                Text(
                    "Stop work and make the area safe first, then use the contacts below. In a life-threatening emergency, call 911."
                )
                .font(.system(size: typeScale.body))
                .lineSpacing(3)
                .foregroundStyle(t.text)
            }

            Card(title: "Emergency contacts and access", theme: t) {
                ForEach(renderedFields, id: \.label) { field in
                    FieldRow(field: field, theme: t)
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: Pre-Job Safety", onPress: onNext, testID: "jha-emergency-next", theme: t)
        }
        .padding(spacing.lg)
    }
}

#if DEBUG
    private let PREVIEW_EMERGENCY_FIELDS: [JhaField] = [
        JhaField(label: "Emergency Contact Number", value: "911"),
        JhaField(label: "Site Contact / Company Man", value: "D. Cole \u{00B7} (432) 555-0142"),
        JhaField(label: "Customer Safety Contact", value: "Acme Safety \u{00B7} (432) 555-0190"),
        JhaField(label: "Nearest Hospital / Clinic", value: "Reeves County Hospital, Pecos"),
        JhaField(label: "Muster Point", value: "Lease entrance, north gate"),
        JhaField(label: "Spill Response Contact", value: "Field Dispatch \u{00B7} (432) 555-0100"),
        JhaField(label: "H2S Emergency Contact", value: "Site Safety \u{00B7} (432) 555-0190"),
        JhaField(label: "911 Access Instructions", value: "Give lease name, well pad, and county road marker"),
        JhaField(label: "Gate Codes / Lease Road Directions", value: "Gate code at dispatch; CR 308 to north pad"),
    ]
#endif

/* ------------------------------------------------------------------ *
 * 36. JHA/JSA Pre-Job Safety
 * ------------------------------------------------------------------ */

struct JhaPreJobSafetyScreen: View {
    var groups: [JhaCheckGroup]? = nil
    /// Auto-filled pre-trip / DVIR completion (GUI Master screen 36).
    var dvirCompleted: Bool? = nil
    var onSetItemOk: ((String, String, Bool) -> Void)? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var local: [JhaCheckGroup]

    init(
        groups: [JhaCheckGroup]? = nil,
        dvirCompleted: Bool? = nil,
        onSetItemOk: ((String, String, Bool) -> Void)? = nil,
        primaryLabel: String? = nil,
        onNext: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.groups = groups
        self.dvirCompleted = dvirCompleted
        self.onSetItemOk = onSetItemOk
        self.primaryLabel = primaryLabel
        self.onNext = onNext
        self.theme = theme
        _local = State(initialValue: groups ?? DEFAULT_PRE_JOB_GROUPS)
    }

    private func setOk(_ groupKey: String, _ itemKey: String, _ ok: Bool) {
        local = local.map { g in
            guard g.key == groupKey else { return g }
            var next = g
            next.items = g.items.map { i in
                guard i.key == itemKey else { return i }
                var ni = i
                ni.ok = ok
                return ni
            }
            return next
        }
        onSetItemOk?(groupKey, itemKey, ok)
    }

    private func resolveOk(_ item: JhaCheckItem, dvirCompleted: Bool) -> Bool {
        item.key == "dvir-pre-trip" ? (dvirCompleted || item.ok) : item.ok
    }

    var body: some View {
        let t = theme ?? envTheme
        let dvirCompleted = dvirCompleted ?? false
        let allConfirmed = local.allSatisfy { group in
            group.items.allSatisfy { resolveOk($0, dvirCompleted: dvirCompleted) }
        }

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Pre-Job Safety", subtitle: "Confirm each item is OK before you start.", theme: t)

            if dvirCompleted {
                Card(title: "Pre-trip", theme: t) {
                    HStack {
                        Text("DVIR / Pre-Trip Inspection pulled from today\u{2019}s inspection.")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                        StatusBadge(label: "Complete", tone: .success, testID: "jha-dvir-autofill")
                    }
                }
            }

            ForEach(local, id: \.key) { group in
                Card(title: group.title, testID: "jha-prejob-\(group.key)", theme: t) {
                    ForEach(group.items, id: \.key) { item in
                        let isDvir = item.key == "dvir-pre-trip"
                        let ok = resolveOk(item, dvirCompleted: dvirCompleted)
                        let autoFilled = (item.autoFilled ?? false) || (isDvir && dvirCompleted)
                        HStack {
                            Text(item.label)
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.text)
                            Spacer()
                            if autoFilled {
                                StatusBadge(label: ok ? "Complete" : "Required", tone: ok ? .success : .warning)
                            } else {
                                OkSegment(
                                    ok: ok,
                                    onSetOk: { value in setOk(group.key, item.key, value) },
                                    theme: t,
                                    testID: "jha-check-\(item.key)"
                                )
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: PPE",
                onPress: onNext,
                disabled: !allConfirmed,
                testID: "jha-prejob-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_PRE_JOB_GROUPS: [JhaCheckGroup] = [
    JhaCheckGroup(
        key: "driver", title: "Driver Readiness",
        items: [
            JhaCheckItem(key: "fit-for-duty", label: "Fit for Duty", ok: false),
            JhaCheckItem(key: "fatigue", label: "Fatigue Check Completed", ok: false),
            JhaCheckItem(key: "hos", label: "Hours of Service Verified", ok: false),
            JhaCheckItem(
                key: "dvir-pre-trip", label: "DVIR / Pre-Trip Inspection Completed", ok: false, autoFilled: true),
        ]),
    JhaCheckGroup(
        key: "route", title: "Route and Weather",
        items: [
            JhaCheckItem(key: "journey", label: "Journey Management / Route Review Completed", ok: false),
            JhaCheckItem(key: "road", label: "Road Conditions Reviewed", ok: false),
            JhaCheckItem(key: "weather", label: "Weather / Heat Stress Reviewed", ok: false),
            JhaCheckItem(key: "hydration", label: "Hydration Plan in Place", ok: false),
        ]),
    JhaCheckGroup(
        key: "site", title: "Site Readiness",
        items: [
            JhaCheckItem(key: "h2s-required", label: "H2S Monitor Required", ok: false),
            JhaCheckItem(key: "h2s-checked", label: "H2S Monitor Checked", ok: false),
            JhaCheckItem(key: "ppe-inspected", label: "PPE Inspected", ok: false),
            JhaCheckItem(key: "fire-ext", label: "Fire Extinguisher Inspected", ok: false),
            JhaCheckItem(key: "first-aid", label: "First Aid Kit Available", ok: false),
            JhaCheckItem(key: "chocks", label: "Wheel Chocks Available", ok: false),
        ]),
    JhaCheckGroup(
        key: "equipment", title: "Equipment Readiness",
        items: [
            JhaCheckItem(key: "fittings", label: "Areas and Fittings Inspected", ok: false),
            JhaCheckItem(key: "pump-pto", label: "Pump / PTO Inspected", ok: false),
            JhaCheckItem(key: "valves", label: "Valves Inspected", ok: false),
        ]),
    JhaCheckGroup(
        key: "customer", title: "Customer Site Requirements",
        items: [
            JhaCheckItem(key: "orientation", label: "Customer Site Orientation Completed", ok: false),
            JhaCheckItem(key: "spotter", label: "Backing Spotter Required", ok: false),
            JhaCheckItem(key: "power-lines", label: "Overhead Power Lines Checked", ok: false),
            JhaCheckItem(key: "slip-trip", label: "Slip / Trip Hazards Identified", ok: false),
            JhaCheckItem(key: "lighting", label: "Lighting Required for Night Work", ok: false),
        ]),
]

func defaultJhaPreJobGroups() -> [JhaCheckGroup] {
    DEFAULT_PRE_JOB_GROUPS
}

/* ------------------------------------------------------------------ *
 * 37. JHA/JSA PPE
 * ------------------------------------------------------------------ */

struct JhaPpeScreen: View {
    var items: [JhaSelectable]? = nil
    var otherText: String? = nil
    var onToggle: ((String, Bool) -> Void)? = nil
    var onChangeOther: ((String) -> Void)? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var local: [JhaSelectable]
    @State private var localOtherText: String

    init(
        items: [JhaSelectable]? = nil,
        otherText: String? = nil,
        onToggle: ((String, Bool) -> Void)? = nil,
        onChangeOther: ((String) -> Void)? = nil,
        primaryLabel: String? = nil,
        onNext: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.items = items
        self.otherText = otherText
        self.onToggle = onToggle
        self.onChangeOther = onChangeOther
        self.primaryLabel = primaryLabel
        self.onNext = onNext
        self.theme = theme
        _local = State(initialValue: items ?? DEFAULT_PPE)
        _localOtherText = State(initialValue: otherText ?? "")
    }

    private func toggle(_ key: String) {
        local = local.map { $0.key == key ? JhaSelectable(key: $0.key, label: $0.label, selected: !$0.selected) : $0 }
        if let changed = local.first(where: { $0.key == key }) {
            onToggle?(key, changed.selected)
        }
    }

    var body: some View {
        let t = theme ?? envTheme
        let otherSelected = local.first(where: { $0.key == "other" })?.selected ?? false
        let hasSelection = local.contains(where: { $0.selected })
        let hasRequiredOtherText =
            !otherSelected
            || !localOtherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "PPE", subtitle: "Select the protective equipment required for this job.", theme: t)

            Card(title: "Required PPE", theme: t) {
                JhaTileGrid {
                    ForEach(local, id: \.key) { item in
                        SelectTile(item: item, onToggle: { toggle(item.key) }, theme: t, testID: "jha-ppe-\(item.key)")
                    }
                }
                if otherSelected {
                    TextField(
                        "Describe the other PPE",
                        text: Binding(
                            get: { localOtherText },
                            set: { next in
                                localOtherText = next
                                onChangeOther?(next)
                            })
                    )
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .padding(.vertical, spacing.sm)
                    .frame(minHeight: 48)
                    .background(t.cardMuted)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, spacing.sm)
                    .accessibilityIdentifier("jha-ppe-other-text")
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: Hazards",
                onPress: onNext,
                disabled: !hasSelection || !hasRequiredOtherText,
                testID: "jha-ppe-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_PPE: [JhaSelectable] = [
    JhaSelectable(key: "fr", label: "FR Clothing", selected: false),
    JhaSelectable(key: "hard-hat", label: "Hard Hat", selected: false),
    JhaSelectable(key: "glasses", label: "Safety Glasses", selected: false),
    JhaSelectable(key: "hearing", label: "Hearing Protection", selected: false),
    JhaSelectable(key: "work-gloves", label: "Work Gloves", selected: false),
    JhaSelectable(key: "chem-gloves", label: "Chemical Resistant Gloves", selected: false),
    JhaSelectable(key: "boots", label: "Steel Toe Boots", selected: false),
    JhaSelectable(key: "vest", label: "Reflective Vest", selected: false),
    JhaSelectable(key: "h2s-monitor", label: "H2S Monitor", selected: false),
    JhaSelectable(key: "respirator", label: "Respirator if Required", selected: false),
    JhaSelectable(key: "rain-gear", label: "Rain Gear", selected: false),
    JhaSelectable(key: "other", label: "Other", selected: false),
]

func defaultJhaPpe() -> [JhaSelectable] {
    DEFAULT_PPE
}

/* ------------------------------------------------------------------ *
 * 38. JHA/JSA Hazards
 * ------------------------------------------------------------------ */

/// Suggested controls shown when the hazard is selected (structurally extends `JhaSelectable` in TS).
struct JhaHazard: JhaSelectableLike, Equatable {
    var key: String
    var label: String
    var selected: Bool
    var controls: [String]
}

struct JhaHazardsScreen: View {
    var hazards: [JhaHazard]? = nil
    var onToggle: ((String, Bool) -> Void)? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var local: [JhaHazard]

    init(
        hazards: [JhaHazard]? = nil,
        onToggle: ((String, Bool) -> Void)? = nil,
        primaryLabel: String? = nil,
        onNext: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.hazards = hazards
        self.onToggle = onToggle
        self.primaryLabel = primaryLabel
        self.onNext = onNext
        self.theme = theme
        _local = State(initialValue: hazards ?? DEFAULT_HAZARDS)
    }

    private func toggle(_ key: String) {
        local = local.map { h in
            guard h.key == key else { return h }
            var next = h
            next.selected.toggle()
            return next
        }
        if let changed = local.first(where: { $0.key == key }) {
            onToggle?(key, changed.selected)
        }
    }

    var body: some View {
        let t = theme ?? envTheme
        let hasSelection = local.contains(where: { $0.selected })

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "Hazards", subtitle: "Select hazards present. Controls appear for each one you pick.", theme: t)

            Card(title: "Job hazards", theme: t) {
                JhaTileGrid {
                    ForEach(local, id: \.key) { hazard in
                        SelectTile(
                            item: hazard, onToggle: { toggle(hazard.key) }, theme: t, testID: "jha-hazard-\(hazard.key)"
                        )
                    }
                }
            }

            if local.contains(where: { $0.selected }) {
                Card(title: "Controls", tone: .highlight, testID: "jha-hazard-controls", theme: t) {
                    ForEach(local.filter { $0.selected }, id: \.key) { hazard in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hazard.label) selected")
                                .font(.system(size: typeScale.body, weight: .bold))
                                .foregroundStyle(t.text)
                            ForEach(hazard.controls, id: \.self) { control in
                                Text("\u{2022} \(control)")
                                    .font(.system(size: typeScale.body))
                                    .lineSpacing(2)
                                    .foregroundStyle(t.text)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: Job Steps",
                onPress: onNext,
                disabled: !hasSelection,
                testID: "jha-hazards-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_HAZARDS: [JhaHazard] = [
    JhaHazard(
        key: "collision", label: "Vehicle Collision", selected: false,
        controls: [
            "Maintain safe following distance", "Obey lease speed limits", "Stay alert at intersections",
        ]),
    JhaHazard(
        key: "rollover", label: "Rollover", selected: false,
        controls: [
            "Slow on curves and grades", "Watch soft shoulders", "Keep load secured",
        ]),
    JhaHazard(
        key: "dust", label: "Dust / Low Visibility", selected: false,
        controls: [
            "Use headlights", "Reduce speed", "Increase following distance",
        ]),
    JhaHazard(
        key: "backing", label: "Backing Hazards", selected: false,
        controls: [
            "Use a spotter", "Walk the path first", "Back slowly with hazards on",
        ]),
    JhaHazard(
        key: "fatigue", label: "Fatigue", selected: false,
        controls: [
            "Take rest breaks", "Stay hydrated", "Stop if drowsy",
        ]),
    JhaHazard(
        key: "heat", label: "Heat Stress", selected: false,
        controls: [
            "Drink water often", "Take shade breaks", "Watch for heat illness",
        ]),
    JhaHazard(
        key: "h2s", label: "H2S Exposure", selected: false,
        controls: [
            "H2S monitor checked", "Know muster point", "Stay upwind", "Stop work if alarm sounds",
        ]),
    JhaHazard(
        key: "chemical", label: "Chemical Exposure", selected: false,
        controls: [
            "Wear chemical gloves", "Review SDS", "Avoid skin contact",
        ]),
    JhaHazard(
        key: "slips", label: "Slips / Trips / Falls", selected: false,
        controls: [
            "Watch footing", "Keep area clear", "Use three points of contact",
        ]),
    JhaHazard(
        key: "pinch", label: "Pinch Points", selected: false,
        controls: [
            "Keep hands clear of fittings", "Wear gloves", "Mind connection points",
        ]),
    JhaHazard(
        key: "hose-whip", label: "Hose Whip", selected: false,
        controls: [
            "Secure hose connections", "Bleed pressure before disconnect", "Stand clear of hose ends",
        ]),
    JhaHazard(
        key: "fire", label: "Fire / Explosion", selected: false,
        controls: [
            "No ignition sources", "Ground equipment", "Fire extinguisher staged",
        ]),
    JhaHazard(
        key: "spill", label: "Spill / Release", selected: false,
        controls: [
            "Stage containment", "Know spill response contact", "Stop transfer if leaking",
        ]),
    JhaHazard(
        key: "power-lines", label: "Overhead Power Lines", selected: false,
        controls: [
            "Check clearance before raising", "Maintain safe distance", "Use a spotter",
        ]),
    JhaHazard(
        key: "wildlife", label: "Wildlife", selected: false,
        controls: [
            "Scan area on arrival", "Keep distance", "Watch for snakes near equipment",
        ]),
]

func defaultJhaHazards() -> [JhaHazard] {
    DEFAULT_HAZARDS
}

/* ------------------------------------------------------------------ *
 * 39. JHA/JSA Job Steps and Risk
 * ------------------------------------------------------------------ */

struct JhaJobStepsScreen: View {
    var steps: [JhaJobStep]? = nil
    var onChangeStep: ((JhaJobStep) -> Void)? = nil
    var primaryLabel: String? = nil
    var onNext: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var local: [JhaJobStep]
    @State private var openKey: String?

    init(
        steps: [JhaJobStep]? = nil,
        onChangeStep: ((JhaJobStep) -> Void)? = nil,
        primaryLabel: String? = nil,
        onNext: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.steps = steps
        self.onChangeStep = onChangeStep
        self.primaryLabel = primaryLabel
        self.onNext = onNext
        self.theme = theme
        let initial = steps ?? DEFAULT_JOB_STEPS
        _local = State(initialValue: initial)
        _openKey = State(initialValue: initial.first?.key)
    }

    private func update(_ key: String, _ mutate: (inout JhaJobStep) -> Void) {
        local = local.map { step in
            guard step.key == key else { return step }
            var next = step
            mutate(&next)
            return next
        }
        if let changed = local.first(where: { $0.key == key }) {
            onChangeStep?(changed)
        }
    }

    var body: some View {
        let t = theme ?? envTheme
        let allReviewed = local.allSatisfy { step in
            !step.hazards.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !step.controls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !step.initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "Job Steps and Risk", subtitle: "Review each step. The app scores the risk for you.", theme: t)

            ForEach(local, id: \.key) { step in
                let open = step.key == openKey
                let initialScore = calcRiskScore(step.severity, step.likelihood)
                let initialCat = riskCategory(initialScore)

                Card(testID: "jha-step-\(step.key)", theme: t) {
                    Button {
                        openKey = open ? nil : step.key
                    } label: {
                        HStack {
                            Text("\(step.index). \(step.title)")
                                .font(.system(size: typeScale.body, weight: .bold))
                                .foregroundStyle(t.text)
                            Spacer()
                            StatusBadge(label: initialCat.rawValue, tone: RISK_TONE[initialCat] ?? .neutral)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)

                    if open {
                        VStack(alignment: .leading, spacing: spacing.xs) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Potential Hazards")
                                    .font(.system(size: typeScale.caption, weight: .semibold))
                                    .foregroundStyle(t.textMuted)
                                MultilineField(
                                    text: Binding(
                                        get: { step.hazards },
                                        set: { newValue in update(step.key) { $0.hazards = newValue } }),
                                    placeholder: "Hazards for this step",
                                    theme: t,
                                    accessibilityLabelText: "Potential hazards for step \(step.index)"
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Controls / Safe Work Practices")
                                    .font(.system(size: typeScale.caption, weight: .semibold))
                                    .foregroundStyle(t.textMuted)
                                MultilineField(
                                    text: Binding(
                                        get: { step.controls },
                                        set: { newValue in update(step.key) { $0.controls = newValue } }),
                                    placeholder: "Controls for this step",
                                    theme: t,
                                    accessibilityLabelText: "Controls for step \(step.index)"
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Initial Risk")
                                    .font(.system(size: typeScale.caption, weight: .semibold))
                                    .foregroundStyle(t.textMuted)
                                RiskStepper(
                                    label: "Severity (1\u{2013}5)",
                                    value: step.severity,
                                    onChange: { v in update(step.key) { $0.severity = v } },
                                    theme: t,
                                    testID: "jha-step-sev-\(step.key)"
                                )
                                RiskStepper(
                                    label: "Likelihood (1\u{2013}5)",
                                    value: step.likelihood,
                                    onChange: { v in update(step.key) { $0.likelihood = v } },
                                    theme: t,
                                    testID: "jha-step-like-\(step.key)"
                                )
                            }

                            HStack {
                                Text("Risk Score \(initialScore)")
                                    .font(.system(size: typeScale.body, weight: .bold))
                                    .foregroundStyle(t.text)
                                Spacer()
                                StatusBadge(
                                    label: "Risk \(initialCat.rawValue)", tone: RISK_TONE[initialCat] ?? .neutral,
                                    testID: "jha-step-score-\(step.key)")
                            }

                            Text("Residual risk drops as you apply the controls above.")
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.textMuted)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Initials")
                                    .font(.system(size: typeScale.caption, weight: .semibold))
                                    .foregroundStyle(t.textMuted)
                                TextField(
                                    "Your initials",
                                    text: Binding(
                                        get: { step.initials },
                                        set: { newValue in update(step.key) { $0.initials = newValue } })
                                )
                                .textInputAutocapitalization(.characters)
                                .foregroundStyle(t.text)
                                .padding(.horizontal, spacing.md)
                                .padding(.vertical, spacing.sm)
                                .frame(minHeight: 48)
                                .background(t.cardMuted)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Initials for step \(step.index)")
                            }
                        }
                        .padding(.top, spacing.xs)
                    } else {
                        Text("Risk Score \(initialScore) \u{00B7} Tap to review hazards and controls")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                }
            }

            FieldButton(
                label: primaryLabel ?? "Next: Stop Work Authority",
                onPress: onNext,
                disabled: !allReviewed,
                testID: "jha-steps-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_JOB_STEPS: [JhaJobStep] = [
    JhaJobStep(
        key: "s1", index: 1, title: "Receive dispatch and review job ticket",
        hazards: "Distraction, incomplete information", controls: "Confirm details before leaving yard", severity: 2,
        likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s2", index: 2, title: "Complete pre-trip inspection", hazards: "Equipment defect, pinch points",
        controls: "Follow DVIR, tag out defects", severity: 2, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s3", index: 3, title: "Travel to lease / facility", hazards: "Vehicle collision, rollover, dust",
        controls: "Defensive driving, reduce speed", severity: 4, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s4", index: 4, title: "Stage truck and secure area", hazards: "Backing hazards, power lines",
        controls: "Use spotter, set chocks", severity: 3, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s5", index: 5, title: "Connect hoses and verify conditions", hazards: "Hose whip, H2S, chemical exposure",
        controls: "Bleed pressure, monitor H2S, PPE", severity: 4, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s6", index: 6, title: "Load or unload water", hazards: "Spill / release, slips",
        controls: "Stage containment, watch footing", severity: 3, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s7", index: 7, title: "Disconnect and secure equipment", hazards: "Pinch points, residual pressure",
        controls: "Verify zero pressure, wear gloves", severity: 3, likelihood: 2, initials: ""),
    JhaJobStep(
        key: "s8", index: 8, title: "Complete paperwork and post-trip inspection", hazards: "Fatigue, missed defect",
        controls: "Complete DVIR, take breaks", severity: 2, likelihood: 2, initials: ""),
]

func defaultJhaJobSteps() -> [JhaJobStep] {
    DEFAULT_JOB_STEPS
}

/* ------------------------------------------------------------------ *
 * 40. JHA/JSA Stop Work Authority
 * ------------------------------------------------------------------ */

struct JhaStopWorkScreen: View {
    var conditions: [String]? = nil
    var acknowledged: Bool? = nil
    var onAcknowledge: () -> Void
    var primaryLabel: String? = nil
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var acked: Bool

    init(
        conditions: [String]? = nil,
        acknowledged: Bool? = nil,
        onAcknowledge: @escaping () -> Void,
        primaryLabel: String? = nil,
        theme: Theme? = nil
    ) {
        self.conditions = conditions
        self.acknowledged = acknowledged
        self.onAcknowledge = onAcknowledge
        self.primaryLabel = primaryLabel
        self.theme = theme
        _acked = State(initialValue: acknowledged ?? false)
    }

    private func acknowledge() {
        acked = true
        onAcknowledge()
    }

    var body: some View {
        let t = theme ?? envTheme
        let conditions = conditions ?? DEFAULT_STOP_WORK

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Stop Work Authority", theme: t)

            Card(title: "Stop immediately for", tone: .highlight, theme: t) {
                ForEach(conditions, id: \.self) { condition in
                    Text("\u{2022} \(condition)")
                        .font(.system(size: typeScale.body))
                        .lineSpacing(4)
                        .foregroundStyle(t.text)
                }
            }

            Card(title: "Acknowledgement", theme: t) {
                Text(
                    "Anyone on this site \u{2014} crew, contractor, customer, or visitor \u{2014} has the authority to stop work if conditions are unsafe. No one needs permission."
                )
                .font(.system(size: typeScale.body))
                .lineSpacing(3)
                .foregroundStyle(t.text)
                Text(
                    "If more than one person is on site, we hold a tailgate meeting so everyone understands the work and its hazards before it starts."
                )
                .font(.system(size: typeScale.body))
                .lineSpacing(3)
                .foregroundStyle(t.text)
                .accessibilityIdentifier("jha-stopwork-tailgate")
                if acked {
                    StatusBadge(label: "Complete", tone: .success, testID: "jha-stopwork-state")
                } else {
                    StatusBadge(label: "Required", tone: .warning, testID: "jha-stopwork-state")
                }
            }

            FieldButton(
                label: acked ? "Continue to Signatures" : (primaryLabel ?? "Acknowledge"),
                onPress: acknowledge,
                testID: "jha-stopwork-ack",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_STOP_WORK: [String] = [
    "H2S alarm",
    "Uncontrolled leak or spill",
    "Fire",
    "Lightning",
    "Heat illness symptoms",
    "Failed equipment",
    "Unsafe road condition",
    "Missing PPE",
    "Unsafe backing condition",
    "Worker concern",
]

/* ------------------------------------------------------------------ *
 * 41. JHA/JSA Signatures
 * ------------------------------------------------------------------ */

/// Who can be added to a JHA besides the driver — the supervisor / customer rep are usually absent.
private let CREW_ROLE_OPTIONS: [String] = [
    "Additional Crew",
    "Owner",
    "Supervisor",
    "Customer Rep",
    "Other",
]

/// A person who signs the JHA. The driver is fixed (signed in); everyone else is added if present.
struct JhaSigner: Equatable {
    var key: String
    var role: String
    var name: String
    var required: Bool
    /// The driver row — role is not editable and the row cannot be removed.
    var fixed: Bool
}

/// Wrap-style role chooser for an added (non-driver) signer.
private struct RolePicker: View {
    var value: String
    var onChange: (String) -> Void
    var theme: Theme
    var testID: String?

    var body: some View {
        JhaFlowLayout(spacing: spacing.sm) {
            ForEach(CREW_ROLE_OPTIONS, id: \.self) { role in
                let selected = role == value
                Button {
                    onChange(role)
                } label: {
                    Text(role)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(selected ? theme.onPrimary : theme.text)
                        .padding(.horizontal, spacing.md)
                        .frame(minHeight: 40)
                        .background(selected ? theme.primary : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20).stroke(
                                selected ? theme.primary : theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(
                    "\(testID ?? "role")-\(role.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// The `onContinue` payload shape: `{ signatures: [{ signature, signerName, signerRole }] }`.
struct JhaSignatureEntry: Equatable {
    var signature: SignatureValue
    var signerName: String
    var signerRole: String
}

struct JhaSignaturesPayload: Equatable {
    var signatures: [JhaSignatureEntry]
}

struct JhaSignaturesScreen: View {
    /// The signed-in driver's name/id — pre-fills the (fixed) driver row.
    var driverName: String? = nil
    var people: [JhaSigner]? = nil
    var capturedSignatures: [String: SignatureValue]? = nil
    var onChangeDraft: (([JhaSigner], [String: SignatureValue]) -> Void)? = nil
    var primaryLabel: String? = nil
    /// Crew attestation shown to the driver; defaults to the canonical JHA text.
    var certificationText: String? = nil
    var onContinue: (JhaSignaturesPayload) -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var local: [JhaSigner]
    @State private var sigs: [String: SignatureValue] = [:]
    @State private var nextId: Int = 1

    init(
        driverName: String? = nil,
        people: [JhaSigner]? = nil,
        capturedSignatures: [String: SignatureValue]? = nil,
        onChangeDraft: (([JhaSigner], [String: SignatureValue]) -> Void)? = nil,
        primaryLabel: String? = nil,
        certificationText: String? = nil,
        onContinue: @escaping (JhaSignaturesPayload) -> Void,
        theme: Theme? = nil
    ) {
        self.driverName = driverName
        self.people = people
        self.capturedSignatures = capturedSignatures
        self.onChangeDraft = onChangeDraft
        self.primaryLabel = primaryLabel
        self.certificationText = certificationText
        self.onContinue = onContinue
        self.theme = theme
        _local = State(
            initialValue: people ?? [
                JhaSigner(key: "driver", role: "Driver", name: driverName ?? "", required: true, fixed: true)
            ])
        _sigs = State(initialValue: capturedSignatures ?? [:])
        _nextId = State(initialValue: max(1, people?.count ?? 1))
    }

    private func mutatePerson(_ key: String, _ mutate: (inout JhaSigner) -> Void) {
        local = local.map { p in
            guard p.key == key else { return p }
            var next = p
            mutate(&next)
            return next
        }
    }

    private func emitDraft() {
        onChangeDraft?(local, sigs)
    }

    private func setName(_ key: String, _ name: String) {
        mutatePerson(key) { $0.name = name }
        emitDraft()
    }

    private func setRole(_ key: String, _ role: String) {
        mutatePerson(key) { $0.role = role }
        emitDraft()
    }

    private func addPerson() {
        let key = "person-\(nextId)"
        nextId += 1
        local.append(JhaSigner(key: key, role: "Additional Crew", name: "", required: false, fixed: false))
        emitDraft()
    }

    private func removePerson(_ key: String) {
        local.removeAll { $0.key == key }
        sigs.removeValue(forKey: key)
        emitDraft()
    }

    // Gate Continue on the driver (the fixed row); fall back to the first person if no fixed row given.
    private var driverKey: String? {
        (local.first(where: { $0.fixed }) ?? local.first)?.key
    }

    private var driverSigned: Bool {
        guard let driverKey else { return false }
        guard let driver = local.first(where: { $0.key == driverKey }) else { return false }
        return sigs[driverKey] != nil
            && !driver.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var signedNamesAreValid: Bool {
        local.allSatisfy { person in
            sigs[person.key] == nil
                || !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func emitSignatures() {
        let signatures = local.compactMap { p -> JhaSignatureEntry? in
            guard let sig = sigs[p.key] else { return nil }
            return JhaSignatureEntry(signature: sig, signerName: p.name, signerRole: p.role)
        }
        onContinue(JhaSignaturesPayload(signatures: signatures))
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "Signatures",
                subtitle: "The driver signs. Add anyone else on site \u{2014} only people who are actually present.",
                theme: t
            )

            Card(tone: .highlight, theme: t) {
                Text(certificationText ?? JHA_CERTIFICATION_TEXT)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.text)
            }

            ForEach(local, id: \.key) { person in
                let signed = sigs[person.key] != nil
                Card(title: person.fixed ? "Driver" : nil, testID: "jha-sig-\(person.key)", theme: t) {
                    if !person.fixed {
                        RolePicker(
                            value: person.role,
                            onChange: { r in setRole(person.key, r) },
                            theme: t,
                            testID: "jha-sig-role-\(person.key)"
                        )
                    }

                    TextField(
                        person.fixed ? "Your name or driver ID" : "Name",
                        text: Binding(get: { person.name }, set: { setName(person.key, $0) })
                    )
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .padding(.vertical, spacing.sm)
                    .frame(minHeight: 48)
                    .background(t.cardMuted)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("jha-sig-name-\(person.key)")

                    if person.fixed && !(driverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("From your sign-in \u{2014} edit only if needed.")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }

                    SignatureField(
                        theme: t,
                        value: sigs[person.key],
                        onChange: { v in
                            if let v {
                                sigs[person.key] = v
                            } else {
                                sigs.removeValue(forKey: person.key)
                            }
                            emitDraft()
                        },
                        testID: "jha-sig-pad-\(person.key)"
                    )

                    StatusBadge(
                        label: signed ? "Signed" : (person.required ? "Required" : "Optional"),
                        tone: signed ? .success : (person.required ? .warning : .neutral),
                        testID: "jha-sig-state-\(person.key)"
                    )

                    if !person.fixed {
                        FieldButton(
                            label: "Remove",
                            onPress: { removePerson(person.key) },
                            variant: .secondary,
                            fullWidth: false,
                            testID: "jha-sig-remove-\(person.key)",
                            theme: t
                        )
                    }
                }
            }

            FieldButton(
                label: "Add person on site", onPress: addPerson, variant: .secondary, testID: "jha-sig-add", theme: t)

            FieldButton(
                label: primaryLabel ?? "Continue to Review",
                onPress: emitSignatures,
                disabled: !driverSigned || !signedNamesAreValid,
                testID: "jha-sig-continue",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* ------------------------------------------------------------------ *
 * 42. JHA/JSA Review
 * ------------------------------------------------------------------ */

struct JhaReviewScreen: View {
    var lines: [JhaReviewLine]? = nil
    var confirmOpen: Bool? = nil
    var primaryLabel: String? = nil
    var submitting: Bool = false
    var onComplete: () -> Void
    var onConfirmComplete: (() -> Void)? = nil
    var onCancelConfirm: (() -> Void)? = nil
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirming: Bool

    init(
        lines: [JhaReviewLine]? = nil,
        confirmOpen: Bool? = nil,
        primaryLabel: String? = nil,
        submitting: Bool = false,
        onComplete: @escaping () -> Void,
        onConfirmComplete: (() -> Void)? = nil,
        onCancelConfirm: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.lines = lines
        self.confirmOpen = confirmOpen
        self.primaryLabel = primaryLabel
        self.submitting = submitting
        self.onComplete = onComplete
        self.onConfirmComplete = onConfirmComplete
        self.onCancelConfirm = onCancelConfirm
        self.theme = theme
        _confirming = State(initialValue: confirmOpen ?? false)
    }

    private func openConfirm() {
        guard !submitting else { return }
        confirming = true
    }

    private func confirm() {
        guard !submitting else { return }
        confirming = false
        onComplete()
        onConfirmComplete?()
    }

    private func cancel() {
        confirming = false
        onCancelConfirm?()
    }

    var body: some View {
        let t = theme ?? envTheme
        let lines = lines ?? DEFAULT_REVIEW_LINES

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Review", subtitle: "Confirm every section before you complete the JHA/JSA.", theme: t)

            Card(title: "Summary", theme: t) {
                ForEach(lines, id: \.label) { line in
                    HStack {
                        Text(line.label)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.text)
                        Spacer()
                        StatusBadge(label: line.value, tone: line.done ? .success : .warning)
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("jha-review-\(line.label)")
                }
            }

            if confirming {
                Card(title: "Complete JHA/JSA?", tone: .highlight, testID: "jha-review-confirm", theme: t) {
                    Text(
                        "You are confirming that hazards, controls, PPE, emergency info, and stop-work authority were reviewed for this job."
                    )
                    .font(.system(size: typeScale.body))
                    .lineSpacing(3)
                    .foregroundStyle(t.text)
                    FieldButton(
                        label: submitting ? "Completing..." : primaryLabel ?? "Complete JHA/JSA",
                        onPress: confirm,
                        disabled: submitting,
                        testID: "jha-review-confirm-yes",
                        theme: t)
                    FieldButton(
                        label: "Cancel",
                        onPress: cancel,
                        variant: .secondary,
                        disabled: submitting,
                        testID: "jha-review-confirm-cancel",
                        theme: t)
                }
            } else {
                FieldButton(
                    label: submitting ? "Completing..." : primaryLabel ?? "Complete JHA/JSA",
                    onPress: openConfirm,
                    disabled: submitting,
                    testID: "jha-review-complete",
                    theme: t)
            }
        }
        .padding(spacing.lg)
    }
}

private let DEFAULT_REVIEW_LINES: [JhaReviewLine] = [
    JhaReviewLine(label: "Job and Site", value: "Complete", done: true),
    JhaReviewLine(label: "Emergency Info", value: "Complete", done: true),
    JhaReviewLine(label: "Pre-Job Safety", value: "Complete", done: true),
    JhaReviewLine(label: "PPE", value: "Complete", done: true),
    JhaReviewLine(label: "Hazards", value: "Complete", done: true),
    JhaReviewLine(label: "Risk Review", value: "Complete", done: true),
    JhaReviewLine(label: "Stop Work", value: "Acknowledged", done: true),
    JhaReviewLine(label: "Signatures", value: "Complete", done: true),
]

/* ------------------------------------------------------------------ *
 * 43. JHA/JSA Complete
 * ------------------------------------------------------------------ */

struct JhaCompleteScreen: View {
    var srNumber: String? = nil
    var primaryLabel: String? = nil
    var onStartFieldTicket: () -> Void
    var theme: Theme? = nil

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let srNumber = srNumber ?? "2026-000001"

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "JHA/JSA Complete", theme: t)

            Card(title: "SR \(srNumber)", tone: .highlight, theme: t) {
                HStack {
                    StatusBadge(label: "Complete", tone: .success, testID: "jha-complete-state")
                }
                Text("Field Ticket is now unlocked.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            FieldButton(
                label: primaryLabel ?? "Start Field Ticket", onPress: onStartFieldTicket, testID: "jha-complete-start",
                theme: t)
        }
        .padding(spacing.lg)
    }
}
