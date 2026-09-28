//
//  PostTripScreens.swift
//  Ported from apps/mobile/src/screens/PostTripScreens.tsx
//
//  End-Day & Post-Trip flow (GUI Master §8 / screens 18–26) — the close-out half of the workday.
//  Screens, in order:
//    18 EndDayReviewScreen          — hand-off from job work into the post-trip DVIR
//    19 PostTripOverviewScreen      — start the daily post-trip inspection (truck + trailer)
//    20 PostTripSectionScreen       — one inspection section; OK / Defect segmented control (§23.4)
//    21 PostTripReviewScreen        — counts + defect remarks before signing
//    22 PostTripSignatureScreen     — driver attestation + signature placeholder
//    23 PostTripCompleteScreen      — post-trip done, points at Punch Out
//    24 PunchOutScreen              — end-of-day summary + punch out
//    25 PunchOutConfirmScreen       — confirm modal (or "Post-Trip Required" block)
//    26 PunchOutSuccessScreen       — punched out, saved-on-phone reassurance
//
//  Presentational only: every screen takes primitive props + callbacks and reads only Design
//  components/tokens (in the same app target — no import needed for those). No domain/runtime/data
//  types, no native modules beyond SwiftUI. DVIR uses OK / Defect segmented controls (never
//  checkboxes) so "checked = defective" can never be ambiguous (§23.4). Driver-facing language only —
//  no UUIDs, hashes, payloads, queues, or hub URLs (§20). Status labels come from the approved §20 set.
//

import Foundation
import FieldContracts
import SwiftUI

// MARK: - Shared local types + small presentational helpers

// `InspectionResult` (not-checked/ok/defect) is declared once in PreTripScreens.swift — same app
// target, same namespace — and reused here as-is (TS unions in PostTripScreens.tsx and
// PreTripScreens.tsx are identical).

struct PostTripItem {
    var key: String
    var label: String
    var result: InspectionResult
    var group: InspectionItem.Group = .truck
    var note: String = ""
}

func defaultPostTripInspectionItems() -> [PostTripItem] {
    [
        PostTripItem(key: "truck-fluids", label: "Truck fluid leaks (oil, coolant, fuel)", result: .notChecked),
        PostTripItem(key: "truck-brakes", label: "Truck brakes & air lines", result: .notChecked),
        PostTripItem(key: "truck-lights", label: "Truck lights & reflectors", result: .notChecked),
        PostTripItem(key: "truck-tires", label: "Truck tires & wheels", result: .notChecked),
        PostTripItem(key: "truck-glass", label: "Mirrors & windshield", result: .notChecked),
        PostTripItem(
            key: "trailer-brakes", label: "Trailer brakes & air lines", result: .notChecked, group: .trailer),
        PostTripItem(
            key: "trailer-lights", label: "Trailer lights & reflectors", result: .notChecked, group: .trailer),
        PostTripItem(key: "trailer-tires", label: "Trailer tires & wheels", result: .notChecked, group: .trailer),
        PostTripItem(
            key: "trailer-coupling", label: "Trailer coupling & safety chains", result: .notChecked, group: .trailer),
        PostTripItem(
            key: "trailer-tank", label: "Trailer tank, valves, hoses & leaks", result: .notChecked, group: .trailer),
    ]
}

/// A pending-sync line shown as reassurance ("saved on this phone").
struct SyncSummaryItem {
    var key: String
    var label: String
}

/// A line in the end-of-day summary (status reinforced by a §20 badge).
struct DaySummaryLine {
    var key: String
    var label: String
    var value: String
    var tone: Tone
}

/// Screen title + optional one-line caption — the consistent header used across this flow.
private struct ScreenHeader: View {
    var title: String
    var caption: String?
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(title)
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(theme.text)
            if let caption {
                Text(caption)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(theme.textMuted)
            }
        }
    }
}

/// A label/value row, e.g. "Odometer End  125,184".
private struct FactRow: View {
    var label: String
    var value: String
    var theme: Theme

    var body: some View {
        HStack(alignment: .center, spacing: spacing.sm) {
            Text(label)
                .font(.system(size: typeScale.body, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(theme.text)
        }
        .padding(.vertical, 6)
    }
}

/// The "Next required step" highlight card reused by hand-off screens (§8).
private struct NextStepCard: View {
    var stepLabel: String
    var primaryLabel: String
    var onPrimary: () -> Void
    var testID: String?
    var theme: Theme

    var body: some View {
        Card(title: "Next required step", tone: .highlight, testID: testID, theme: theme) {
            Text(stepLabel)
                .font(.system(size: typeScale.heading, weight: .heavy))
                .foregroundStyle(theme.text)
            FieldButton(label: primaryLabel, onPress: onPrimary, theme: theme)
        }
    }
}

/// OK / Defect segmented control (GUI Master §23.4). Three explicit states so a tap is never
/// ambiguous: Not Checked is the neutral default, OK is pass, Defect is fail. "Defect" is the only
/// thing that reads as a problem — there is no checkbox whose "checked" could mean either.
private struct ResultSegment: View {
    var value: InspectionResult
    var onChange: (InspectionResult) -> Void
    var testID: String?
    var theme: Theme

    private struct SegmentOption {
        var key: InspectionResult
        var label: String
        var tone: Tone
    }

    private let options: [SegmentOption] = [
        SegmentOption(key: .notChecked, label: "Not Checked", tone: .neutral),
        SegmentOption(key: .ok, label: "OK", tone: .success),
        SegmentOption(key: .defect, label: "Defect", tone: .danger),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.key) { opt in
                let selected = opt.key == value
                let accent: Color =
                    opt.tone == .success
                    ? theme.success
                    : opt.tone == .danger ? theme.danger : theme.textMuted

                Button {
                    onChange(opt.key)
                } label: {
                    Text(opt.label)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(selected ? theme.onPrimary : theme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: sizing.minTouchTarget)
                        .padding(.horizontal, spacing.xs)
                        .background(selected ? accent : Color.clear)
                        .overlay(Rectangle().fill(theme.border).frame(width: 0.5), alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(ifPresent: testID.map { "\($0)-\(opt.key.rawValue)" })
            }
        }
        .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// A secondary host-wired action (Review Jobs, View Sync, Contact Dispatch, …).
private struct FeedbackButton: View {
    var label: String
    var confirmation: String
    var onPress: (() -> Void)?
    var testID: String?
    var theme: Theme

    @State private var acted = false

    var body: some View {
        Group {
            FieldButton(
                label: label,
                onPress: {
                    acted = true
                    onPress?()
                },
                variant: .secondary,
                testID: testID,
                theme: theme
            )
            if acted {
                Text(confirmation)
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(theme.success)
                    .accessibilityIdentifier(ifPresent: testID.map { "\($0)-confirm" })
            }
        }
    }
}

// MARK: - 18. End Day Review

/// Screen 18 — End Day Review. Transition from job work to post-trip. Summarizes how the day went
/// (jobs completed, field tickets submitted, items still syncing) and points firmly at the one
/// required next step: the driver post-trip inspection.
struct EndDayReviewScreen: View {
    var jobsCompleted: Int?
    var jobsTotal: Int?
    var ticketsSubmitted: Int?
    var pendingSync: Int?
    var onStartPostTrip: () -> Void
    var onReviewJobs: (() -> Void)?
    var onViewSync: (() -> Void)?
    var onContactDispatch: (() -> Void)? = nil
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "End Day", caption: "Wrap up today and start your post-trip.", theme: t)

            Card(title: "Today’s summary", testID: "end-day-summary", theme: t) {
                if let jobsCompleted, let jobsTotal {
                    FactRow(label: "Jobs completed", value: "\(jobsCompleted) of \(jobsTotal)", theme: t)
                }
                if let ticketsSubmitted {
                    FactRow(label: "Field tickets", value: "\(ticketsSubmitted) submitted", theme: t)
                }
                if let pendingSync {
                    HStack(alignment: .center, spacing: spacing.sm) {
                        Text("Pending sync")
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                        Spacer()
                        StatusBadge(
                            label: pendingSync == 0 ? "Synced" : "Pending Sync",
                            tone: pendingSync == 0 ? .success : .warning,
                            testID: "end-day-sync-badge"
                        )
                    }
                    .padding(.vertical, 6)
                    if pendingSync > 0 {
                        Text(
                            "\(pendingSync) item\(pendingSync == 1 ? "" : "s") saved on this phone, syncing when connected."
                        )
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                    }
                }
                if jobsCompleted == nil && ticketsSubmitted == nil && pendingSync == nil {
                    Text("Today’s Hub summary is unavailable. Your post-trip can still be completed on this phone.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                }
            }

            NextStepCard(
                stepLabel: "Driver Post-Trip Inspection",
                primaryLabel: "Start Post-Trip",
                onPrimary: onStartPostTrip,
                testID: "end-day-next",
                theme: t
            )

            if onReviewJobs != nil || onViewSync != nil || onContactDispatch != nil {
                Card(title: "More options", theme: t) {
                    if let onReviewJobs {
                        FeedbackButton(
                            label: "Review Jobs",
                            confirmation: "Opening today’s jobs…",
                            onPress: onReviewJobs,
                            testID: "end-day-review-jobs",
                            theme: t
                        )
                    }
                    if let onViewSync {
                        FeedbackButton(
                            label: "View Sync",
                            confirmation: "Opening sync status…",
                            onPress: onViewSync,
                            testID: "end-day-view-sync",
                            theme: t
                        )
                    }
                    if let onContactDispatch {
                        FeedbackButton(
                            label: "Contact Dispatch",
                            confirmation: "Opening dispatch contact…",
                            onPress: onContactDispatch,
                            testID: "end-day-dispatch",
                            theme: t
                        )
                    }
                }
            }
        }
        .padding(spacing.lg)
    }
}

// MARK: - 19. Driver Post-Trip Overview

/// Screen 19 — Driver Post-Trip Overview. Starts the daily post-trip DVIR. Names the rig the driver
/// is closing out and the ending odometer, and makes clear the inspection is required before punching
/// out.
struct PostTripOverviewScreen: View {
    var truck: String?
    var trailer: String?
    var odometerEnd: String?
    var onBegin: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let truck = self.truck ?? "Truck 7"
        let trailer = self.trailer ?? "Vacuum Trailer 19"
        let odometerEnd = self.odometerEnd ?? "125,184"

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Driver Post-Trip Inspection", theme: t)

            Card(title: "Required before punching out", tone: .highlight, testID: "post-trip-required-card", theme: t) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(label: "Required", tone: .warning, testID: "post-trip-required-badge")
                }
                Text(
                    "Check the truck and trailer for any damage or problems from today’s work before you end your day."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            }

            Card(title: "Equipment", testID: "post-trip-equipment", theme: t) {
                FactRow(label: "Truck", value: truck, theme: t)
                FactRow(label: "Trailer", value: trailer, theme: t)
                FactRow(label: "Odometer End", value: odometerEnd, theme: t)
            }

            FieldButton(label: "Begin Post-Trip", onPress: onBegin, testID: "post-trip-begin", theme: t)
        }
        .padding(spacing.lg)
    }
}

// MARK: - 20. Driver Post-Trip Section

/// Screen 20 — Driver Post-Trip Section. One inspection section (mirrors the pre-trip sections) with
/// a Not Checked | OK | Defect segmented control per item (§23.4). Post-trip wording: report defects
/// found during or after today’s work. The component owns the per-item state locally and reports each
/// change up via onChangeItem so the host can persist.
struct PostTripSectionScreen: View {
    var sectionTitle: String?
    var sectionIndex: Int?
    var sectionCount: Int?
    var onChangeItem: ((String, InspectionResult) -> Void)?
    var onChangeNote: ((String, String) -> Void)?
    var onContinue: () -> Void
    var onBack: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var items: [PostTripItem]

    init(
        sectionTitle: String? = nil,
        sectionIndex: Int? = nil,
        sectionCount: Int? = nil,
        items: [PostTripItem]? = nil,
        onChangeItem: ((String, InspectionResult) -> Void)? = nil,
        onChangeNote: ((String, String) -> Void)? = nil,
        onContinue: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.sectionTitle = sectionTitle
        self.sectionIndex = sectionIndex
        self.sectionCount = sectionCount
        self.onChangeItem = onChangeItem
        self.onChangeNote = onChangeNote
        self.onContinue = onContinue
        self.onBack = onBack
        self.theme = theme
        _items = State(initialValue: items ?? defaultPostTripInspectionItems())
    }

    private func setResult(_ key: String, _ result: InspectionResult) {
        items = items.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.result = result
            if result != .defect { updated.note = "" }
            return updated
        }
        onChangeItem?(key, result)
    }

    private func setNote(_ key: String, _ note: String) {
        items = items.map { item in
            guard item.key == key else { return item }
            var updated = item
            updated.note = note
            return updated
        }
        onChangeNote?(key, note)
    }

    var body: some View {
        let t = theme ?? envTheme
        let sectionTitle = self.sectionTitle ?? "Engine & Cab"
        let sectionIndex = self.sectionIndex ?? 1
        let sectionCount = self.sectionCount ?? 6

        let checked = items.filter { $0.result != .notChecked }.count
        let defects = items.filter { $0.result == .defect }.count
        let allChecked = checked == items.count
        let defectsHaveNotes = items.allSatisfy {
            $0.result != .defect || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: sectionTitle,
                caption: "Section \(sectionIndex) of \(sectionCount)",
                theme: t
            )

            Card(tone: .highlight, theme: t) {
                Text("Report any defects found during or after today’s work.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                HStack(spacing: spacing.sm) {
                    StatusBadge(
                        label: allChecked ? (defects > 0 ? "Needs Review" : "Complete") : "In Progress",
                        tone: allChecked ? (defects > 0 ? .danger : .success) : .info,
                        testID: "post-trip-section-status"
                    )
                    Text("\(checked) of \(items.count) checked")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            ForEach(items, id: \.key) { item in
                Card(testID: "post-trip-item-\(item.key)", theme: t) {
                    Text(item.label)
                        .font(.system(size: typeScale.body, weight: .bold))
                        .foregroundStyle(t.text)
                    ResultSegment(
                        value: item.result,
                        onChange: { next in setResult(item.key, next) },
                        testID: "post-trip-segment-\(item.key)",
                        theme: t
                    )
                    if item.result == .defect {
                        TextField(
                            "Describe this defect",
                            text: Binding(get: { item.note }, set: { setNote(item.key, $0) }),
                            axis: .vertical
                        )
                        .foregroundStyle(t.text)
                        .padding(spacing.md)
                        .background(t.cardMuted)
                        .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                        .accessibilityIdentifier("post-trip-note-\(item.key)")
                    }
                }
            }

            if let onBack {
                FieldButton(
                    label: "Back",
                    onPress: onBack,
                    variant: .secondary,
                    testID: "post-trip-section-back",
                    theme: t
                )
            }
            FieldButton(
                label: "Continue",
                onPress: onContinue,
                disabled: !allChecked || !defectsHaveNotes,
                testID: "post-trip-section-continue",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 21. Driver Post-Trip Review

/// Screen 21 — Driver Post-Trip Review. Roll-up of the truck/trailer item counts and any defects with
/// remarks, before the driver signs. The remarks field is editable so the driver can clarify before
/// attesting.
struct PostTripReviewScreen: View {
    var truckChecked: Int?
    var truckTotal: Int?
    var trailerChecked: Int?
    var trailerTotal: Int?
    var defects: Int?
    var remarks: String?
    var onChangeRemarks: ((String) -> Void)?
    var defectsCertifiedSafe: Bool?
    var onChangeDefectsCertifiedSafe: ((Bool) -> Void)?
    var onContinue: () -> Void
    var onBack: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var remarksText: String

    init(
        truckChecked: Int? = nil,
        truckTotal: Int? = nil,
        trailerChecked: Int? = nil,
        trailerTotal: Int? = nil,
        defects: Int? = nil,
        remarks: String? = nil,
        onChangeRemarks: ((String) -> Void)? = nil,
        defectsCertifiedSafe: Bool? = nil,
        onChangeDefectsCertifiedSafe: ((Bool) -> Void)? = nil,
        onContinue: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.truckChecked = truckChecked
        self.truckTotal = truckTotal
        self.trailerChecked = trailerChecked
        self.trailerTotal = trailerTotal
        self.defects = defects
        self.remarks = remarks
        self.onChangeRemarks = onChangeRemarks
        self.defectsCertifiedSafe = defectsCertifiedSafe
        self.onChangeDefectsCertifiedSafe = onChangeDefectsCertifiedSafe
        self.onContinue = onContinue
        self.onBack = onBack
        self.theme = theme
        _remarksText = State(initialValue: remarks ?? "")
    }

    private func onRemarks(_ text: String) {
        remarksText = text
        onChangeRemarks?(text)
    }

    var body: some View {
        let t = theme ?? envTheme
        let truckChecked = self.truckChecked ?? 45
        let truckTotal = self.truckTotal ?? 45
        let trailerChecked = self.trailerChecked ?? 16
        let trailerTotal = self.trailerTotal ?? 16
        let defects = self.defects ?? 1

        let truckComplete = truckChecked == truckTotal
        let trailerComplete = trailerChecked == trailerTotal

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(
                title: "Post-Trip Review",
                caption: "Confirm everything before you sign.",
                theme: t
            )

            Card(title: "Items checked", testID: "post-trip-review-counts", theme: t) {
                HStack(alignment: .center, spacing: spacing.sm) {
                    Text("Truck items checked")
                        .font(.system(size: typeScale.body, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                    Spacer()
                    HStack(spacing: spacing.sm) {
                        Text("\(truckChecked) of \(truckTotal)")
                            .font(.system(size: typeScale.body, weight: .bold))
                            .foregroundStyle(t.text)
                        StatusBadge(
                            label: truckComplete ? "Complete" : "In Progress", tone: truckComplete ? .success : .info)
                    }
                }
                .padding(.vertical, 6)

                HStack(alignment: .center, spacing: spacing.sm) {
                    Text("Trailer items checked")
                        .font(.system(size: typeScale.body, weight: .semibold))
                        .foregroundStyle(t.textMuted)
                    Spacer()
                    HStack(spacing: spacing.sm) {
                        Text("\(trailerChecked) of \(trailerTotal)")
                            .font(.system(size: typeScale.body, weight: .bold))
                            .foregroundStyle(t.text)
                        StatusBadge(
                            label: trailerComplete ? "Complete" : "In Progress",
                            tone: trailerComplete ? .success : .info)
                    }
                }
                .padding(.vertical, 6)
            }

            Card(
                title: "Defects",
                tone: defects > 0 ? .highlight : .default,
                testID: "post-trip-review-defects",
                theme: t
            ) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(
                        label: defects > 0 ? "Needs Review" : "Complete",
                        tone: defects > 0 ? .danger : .success,
                        testID: "post-trip-defects-badge"
                    )
                    Text(defects == 0 ? "No defects found" : "\(defects) defect\(defects == 1 ? "" : "s")")
                        .font(.system(size: typeScale.body, weight: .bold))
                        .foregroundStyle(t.text)
                }
                Text("Remarks")
                    .font(.system(size: typeScale.body, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                if onChangeRemarks != nil {
                    TextField(
                        "Describe any defect found",
                        text: Binding(get: { remarksText }, set: { onRemarks($0) }),
                        axis: .vertical
                    )
                    .foregroundStyle(t.text)
                    .padding(spacing.md)
                    .background(t.cardMuted)
                    .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .frame(minHeight: sizing.minTouchTarget)
                    .accessibilityLabel("Defect remarks")
                    .accessibilityIdentifier("post-trip-remarks")
                } else {
                    Text(remarksText.isEmpty ? "No defects reported" : remarksText)
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            if defects > 0 {
                DefectSafetyCertificationCard(
                    value: defectsCertifiedSafe,
                    onChange: { onChangeDefectsCertifiedSafe?($0) },
                    theme: t
                )
            }

            if let onBack {
                FieldButton(
                    label: "Back",
                    onPress: onBack,
                    variant: .secondary,
                    testID: "post-trip-review-back",
                    theme: t
                )
            }
            FieldButton(
                label: "Continue to Signature",
                onPress: onContinue,
                disabled: defects > 0
                    && (remarksText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || defectsCertifiedSafe == nil),
                testID: "post-trip-review-continue",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 22. Driver Post-Trip Signature

/// Payload for `onComplete` — the captured signature + signer name (same payload convention as
/// PreTrip's onCompletePreTrip).
struct PostTripSignaturePayload {
    var signature: SignatureValue
    var signerName: String
}

/// Screen 22 — Driver Post-Trip Signature. Attestation plus a signature placeholder (a bordered
/// preview frame — the real capture is wired on-device). The driver taps Sign to fill the pad, then
/// Complete Post-Trip is enabled.
struct PostTripSignatureScreen: View {
    var driverName: String?
    var signed: Bool?
    var onSign: (() -> Void)?
    var onClear: (() -> Void)?
    /// Driver attestation shown above the pad; defaults to the canonical DVIR post-trip text.
    var certificationText: String?
    var onComplete: (PostTripSignaturePayload) -> Void
    var onBack: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var signature: SignatureValue?

    var body: some View {
        let t = theme ?? envTheme
        let driverName = self.driverName ?? ""
        let signed = signature != nil

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Driver Signature", theme: t)

            Card(tone: .highlight, testID: "post-trip-attestation", theme: t) {
                Text(certificationText ?? DVIR_POSTTRIP_CERTIFICATION_TEXT)
                    .font(.system(size: typeScale.heading, weight: .bold))
                    .foregroundStyle(t.text)
                if !driverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(driverName)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            Card(title: "Signature", theme: t) {
                SignatureField(
                    theme: t,
                    value: signature,
                    onChange: { next in
                        signature = next
                        if next == nil {
                            onClear?()
                        } else {
                            onSign?()
                        }
                    },
                    testID: "post-trip-signature"
                )
                HStack(spacing: spacing.sm) {
                    StatusBadge(
                        label: signed ? "Saved on Phone" : "Required",
                        tone: signed ? .success : .warning,
                        testID: "post-trip-sign-status"
                    )
                }
            }

            if let onBack {
                FieldButton(
                    label: "Back",
                    onPress: onBack,
                    variant: .secondary,
                    testID: "post-trip-sign-back",
                    theme: t
                )
            }
            FieldButton(
                label: "Complete Post-Trip",
                onPress: {
                    if let signature {
                        onComplete(PostTripSignaturePayload(signature: signature, signerName: driverName))
                    }
                },
                disabled: !signed || driverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                testID: "post-trip-complete",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 23. Driver Post-Trip Complete

/// Screen 23 — Driver Post-Trip Complete. Confirms the post-trip is done and routes the driver to the
/// final required step of the day: punch out at the physical Field Time Terminal.
struct PostTripCompleteScreen: View {
    var defects: Int?
    var onDone: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let defects = self.defects ?? 1

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Post-Trip Complete", theme: t)

            Card(title: "Inspection saved", testID: "post-trip-complete-card", theme: t) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(label: "Complete", tone: .success, testID: "post-trip-complete-badge")
                    if defects > 0 {
                        StatusBadge(label: "Needs Review", tone: .danger, testID: "post-trip-complete-defects")
                    }
                }
                Text(
                    defects > 0
                        ? "Your post-trip is saved on this phone. \(defects) defect\(defects == 1 ? "" : "s") flagged for the shop."
                        : "Your post-trip is saved on this phone and will sync when connected."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
            }

            NextStepCard(
                stepLabel: "Punch out at the Field Time Terminal. This app does not record time punches.",
                primaryLabel: "Done",
                onPrimary: onDone,
                testID: "post-trip-complete-next",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

// MARK: - 24. Punch Out

/// Screen 24 — Punch Out. The end-of-day command card: punch-in/now times, a status roll-up of the
/// whole day (pre-trip, jobs, tickets, post-trip, sync), and the punch-out action. Each summary line
/// carries an approved §20 status badge so state reads without color alone.
struct PunchOutScreen: View {
    var punchedInAt: String?
    var currentTime: String?
    var summary: [DaySummaryLine]?
    var onPunchOut: () -> Void
    var onReviewJobs: () -> Void
    var onViewSync: () -> Void
    var onContactDispatch: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    private static let defaultSummary: [DaySummaryLine] = [
        DaySummaryLine(key: "pre-trip", label: "Pre-Trip", value: "Complete", tone: .success),
        DaySummaryLine(key: "jobs", label: "Jobs", value: "3 complete", tone: .success),
        DaySummaryLine(key: "tickets", label: "Field Tickets", value: "3 submitted", tone: .success),
        DaySummaryLine(key: "post-trip", label: "Post-Trip", value: "Complete", tone: .success),
        DaySummaryLine(key: "sync", label: "Sync", value: "4 pending", tone: .warning),
    ]

    var body: some View {
        let t = theme ?? envTheme
        let punchedInAt = self.punchedInAt ?? "6:02 AM"
        let currentTime = self.currentTime ?? "5:41 PM"
        let summary = self.summary ?? Self.defaultSummary

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Ready to Punch Out", theme: t)

            Card(title: "Workday", testID: "punch-out-times", theme: t) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(label: "Punched In", tone: .success, testID: "punch-out-state")
                }
                FactRow(label: "Punched in", value: punchedInAt, theme: t)
                FactRow(label: "Current time", value: currentTime, theme: t)
            }

            Card(title: "Today’s Summary", testID: "punch-out-summary", theme: t) {
                ForEach(summary, id: \.key) { line in
                    HStack(alignment: .center, spacing: spacing.sm) {
                        Text(line.label)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                        Spacer()
                        HStack(spacing: spacing.sm) {
                            Text(line.value)
                                .font(.system(size: typeScale.body, weight: .bold))
                                .foregroundStyle(t.text)
                            StatusBadge(label: summaryBadgeLabel(line), tone: line.tone)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("punch-out-\(line.key)")
                }
            }

            FieldButton(label: "Punch Out", onPress: onPunchOut, testID: "punch-out-primary", theme: t)

            Card(title: "More options", theme: t) {
                FeedbackButton(
                    label: "Review Jobs",
                    confirmation: "Opening today’s jobs…",
                    onPress: onReviewJobs,
                    testID: "punch-out-review-jobs",
                    theme: t
                )
                FeedbackButton(
                    label: "View Sync",
                    confirmation: "Opening sync status…",
                    onPress: onViewSync,
                    testID: "punch-out-view-sync",
                    theme: t
                )
                FeedbackButton(
                    label: "Contact Dispatch",
                    confirmation: "Calling dispatch…",
                    onPress: onContactDispatch,
                    testID: "punch-out-dispatch",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/// Map a summary line to a short §20 badge label (the value text carries the detail).
private func summaryBadgeLabel(_ line: DaySummaryLine) -> String {
    if line.tone == .warning { return "Pending Sync" }
    if line.tone == .danger { return "Needs Review" }
    if line.tone == .info { return "In Progress" }
    return "Complete"
}

// MARK: - 25. Punch Out Confirmation

/// Screen 25 — Punch Out Confirmation. Rendered as an inline modal surface (no native Modal dep). Two
/// modes:
///   - postTripComplete = true  → "Punch out?" confirm with Cancel / Punch Out.
///   - postTripComplete = false → "Post-Trip Required" block that routes back to the inspection.
struct PunchOutConfirmScreen: View {
    var postTripComplete: Bool?
    var pendingSync: Int?
    var onConfirm: () -> Void
    var onCancel: () -> Void
    var onGoToPostTrip: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let postTripComplete = self.postTripComplete ?? true
        let pendingSync = self.pendingSync ?? 4

        if !postTripComplete {
            VStack(spacing: spacing.md) {
                Spacer()
                Card(title: "Post-Trip Required", tone: .highlight, testID: "punch-out-blocked", theme: t) {
                    HStack(spacing: spacing.sm) {
                        StatusBadge(label: "Blocked", tone: .danger, testID: "punch-out-blocked-badge")
                    }
                    Text("Complete your Post-Trip Inspection before punching out.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    if let onGoToPostTrip {
                        FieldButton(
                            label: "Go to Post-Trip",
                            onPress: onGoToPostTrip,
                            testID: "punch-out-goto-post-trip",
                            theme: t
                        )
                    }
                    FieldButton(
                        label: "Cancel",
                        onPress: onCancel,
                        variant: .secondary,
                        testID: "punch-out-blocked-cancel",
                        theme: t
                    )
                }
                Spacer()
            }
            .padding(spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.background)
        } else {
            VStack(spacing: spacing.md) {
                Spacer()
                Card(title: "Punch out?", testID: "punch-out-confirm", theme: t) {
                    Text("This will end your workday.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text(
                        pendingSync > 0
                            ? "Any saved work on this phone will continue syncing when connected (\(pendingSync) item\(pendingSync == 1 ? "" : "s") pending)."
                            : "Any saved work on this phone will continue syncing when connected."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
                    FieldButton(
                        label: "Punch Out",
                        onPress: onConfirm,
                        testID: "punch-out-confirm-yes",
                        theme: t
                    )
                    FieldButton(
                        label: "Cancel",
                        onPress: onCancel,
                        variant: .secondary,
                        testID: "punch-out-confirm-cancel",
                        theme: t
                    )
                }
                Spacer()
            }
            .padding(spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.background)
        }
    }
}

// MARK: - 26. Punch Out Success

/// Screen 26 — Punch Out Success. Confirms the workday ended and reassures the driver that any saved
/// work is safe on the phone and will sync when connected. Primary routes to Sync; secondary is Done.
struct PunchOutSuccessScreen: View {
    var endedAt: String?
    var pendingSync: Int?
    var onViewSync: () -> Void
    var onDone: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let endedAt = self.endedAt ?? "5:41 PM"
        let pendingSync = self.pendingSync ?? 4

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenHeader(title: "Punched Out", theme: t)

            Card(title: "Workday ended", tone: .highlight, testID: "punch-out-success", theme: t) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(label: "Punched Out", tone: .neutral, testID: "punch-out-success-badge")
                }
                Text("Workday ended at \(endedAt).")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                if pendingSync > 0 {
                    Text(
                        "\(pendingSync) item\(pendingSync == 1 ? "" : "s") \(pendingSync == 1 ? "is" : "are") saved on this phone and will sync when connected."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                } else {
                    Text("All your work is saved and up to date.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            FieldButton(label: "View Sync", onPress: onViewSync, testID: "punch-out-success-view-sync", theme: t)
            FieldButton(
                label: "Done",
                onPress: onDone,
                variant: .secondary,
                testID: "punch-out-success-done",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}
