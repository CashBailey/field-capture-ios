//
//  PreTripScreens.swift
//  Ported from apps/mobile/src/screens/PreTripScreens.tsx
//
//  Driver Pre-Trip Inspection (GUI Master §7 / screens 12–17) — the daily DVIR flow a driver
//  completes before any job work unlocks: Overview → Section → Defect Detail → Review → Signature →
//  Complete.
//
//  Company DVIR rule (GUI Master §23.4): inspection items use an OK / Defect segmented control, NOT
//  checkboxes — on this company's paper DVIR a *checked* item means a *defective* item, so a checkbox
//  would be dangerously ambiguous. Selecting "Defect" opens Defect Detail.
//
//  Self-managing controls: every toggle, segmented control, chip, and input owns its own state so it
//  visibly responds the instant a gloved thumb taps it. Optional callbacks are still fired for the
//  host, and required nav callbacks (onBegin/onContinue/onComplete/…) drive the app's routing.
//
//  Presentational only. No domain/runtime imports, no native modules: camera, signature pad, and GPS
//  are bordered placeholder frames + Buttons with inline confirmation; real capture is wired
//  elsewhere. Driver-facing language only — no UUIDs, payloads, queues, or env strings.
//

import Foundation
import FieldContracts
import SwiftUI

// MARK: - Shared local types (primitive fields + callbacks only)

/// A driver's per-item inspection result. "notChecked" is the untouched default.
enum InspectionResult: String {
    case notChecked = "not-checked"
    case ok
    case defect
}

/// Defect severity (GUI Master §14, used only when company policy supports it).
enum DefectSeverity: String {
    case minor
    case needsReview = "needs-review"
    case unsafe
}

struct DefectDetailPayload {
    var note: String
    var requiresReview: Bool
    var severity: DefectSeverity
    var photoCount: Int
}

private struct SegmentOption<T> {
    var key: T
    var label: String
}

private let RESULT_OPTIONS: [SegmentOption<InspectionResult>] = [
    SegmentOption(key: .notChecked, label: "Not Checked"),
    SegmentOption(key: .ok, label: "OK"),
    SegmentOption(key: .defect, label: "Defect"),
]

private let SEVERITY_OPTIONS: [SegmentOption<DefectSeverity>] = [
    SegmentOption(key: .minor, label: "Minor"),
    SegmentOption(key: .needsReview, label: "Needs Review"),
    SegmentOption(key: .unsafe, label: "Unsafe"),
]

// MARK: - 12. Driver Pre-Trip Overview

struct PreTripOverviewScreen: View {
    /// Where the driver left off.
    enum Status: String {
        case notStarted = "Not Started"
        case inProgress = "In Progress"
        case required = "Required"
    }

    var truck: String?
    var trailer: String?
    var odometerBegin: String?
    var status: Status?
    var onBeginInspection: () -> Void
    var onSaveDraft: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var draftSaved = false

    var body: some View {
        let t = theme ?? envTheme
        let truck = self.truck ?? "Truck 7"
        let trailer = self.trailer ?? "Vacuum Trailer 19"
        let odometer = self.odometerBegin ?? "124,882"
        let status = self.status ?? .required

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Driver Pre-Trip Inspection")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(tone: .highlight, testID: "pretrip-overview-intro", theme: t) {
                StatusBadge(label: status.rawValue, tone: status == .inProgress ? .info : .warning)
                Text("Required before starting job work.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            Card(title: "Vehicle", theme: t) {
                FieldRow(label: "Truck", value: truck, theme: t)
                FieldRow(label: "Trailer", value: trailer, theme: t)
                FieldRow(label: "Odometer Begin", value: odometer, theme: t)
            }

            Card(title: "Inspection method", theme: t) {
                Text("Mark each item OK or Defect. A Defect opens a short report so the shop knows what is wrong.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }

            FieldButton(label: "Begin Inspection", onPress: onBeginInspection, testID: "pretrip-begin", theme: t)
            if let onSaveDraft {
                FieldButton(
                    label: "Save Draft",
                    onPress: {
                        onSaveDraft()
                        draftSaved = true
                    },
                    variant: .secondary,
                    testID: "pretrip-save-draft",
                    theme: t
                )
                if draftSaved {
                    Text("Saved on this phone")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("pretrip-draft-saved")
                }
            }
        }
        .padding(spacing.lg)
    }
}

// MARK: - 13. Driver Pre-Trip Section

struct InspectionItem {
    /// Which vehicle the item belongs to — drives the truck/trailer split on Review.
    enum Group: String {
        case truck
        case trailer
    }

    var key: String
    var label: String
    var result: InspectionResult
    var group: Group?
}

/// Real, derived inspection totals — replaces the old hardcoded "45/45, 0 defects".
struct InspectionSummary {
    var total: Int
    var checked: Int
    var defectCount: Int
    var truckChecked: Int
    var truckTotal: Int
    var trailerChecked: Int
    var trailerTotal: Int
    /// True only when every item has been marked OK or Defect (nothing left "not-checked").
    var allChecked: Bool
}

/// Summarize an inspection from the driver's actual per-item results. This is what gates Continue and
/// feeds the Review screen — a DVIR can no longer report "complete" on items that were never touched.
func summarizeInspection(
    items: [InspectionItem],
    results: [String: InspectionResult]
) -> InspectionSummary {
    var checked = 0
    var defectCount = 0
    var truckChecked = 0
    var truckTotal = 0
    var trailerChecked = 0
    var trailerTotal = 0
    for item in items {
        let result = results[item.key] ?? item.result
        let isTruck = (item.group ?? .truck) == .truck
        if isTruck { truckTotal += 1 } else { trailerTotal += 1 }
        if result != .notChecked {
            checked += 1
            if isTruck { truckChecked += 1 } else { trailerChecked += 1 }
        }
        if result == .defect { defectCount += 1 }
    }
    return InspectionSummary(
        total: items.count,
        checked: checked,
        defectCount: defectCount,
        truckChecked: truckChecked,
        truckTotal: truckTotal,
        trailerChecked: trailerChecked,
        trailerTotal: trailerTotal,
        allChecked: !items.isEmpty && checked == items.count
    )
}

struct PreTripSectionScreen: View {
    /// Heading for the inspection — the whole DVIR is one scrollable page (company policy).
    var sectionName: String?
    var items: [InspectionItem]?
    var onSetResult: ((String, InspectionResult) -> Void)?
    /// Called when "Defect" is chosen so the host can open Defect Detail (screen 14).
    var onOpenDefect: ((String) -> Void)?
    /// Fired with the real, driver-entered totals — never advances until every item is marked.
    var onContinue: (InspectionSummary) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    // Self-managing per-item results: seed a key->result map from the incoming items so each row
    // re-renders highlighted the moment its OK/Defect option is tapped.
    @State private var results: [String: InspectionResult]

    init(
        sectionName: String? = nil,
        items: [InspectionItem]? = nil,
        onSetResult: ((String, InspectionResult) -> Void)? = nil,
        onOpenDefect: ((String) -> Void)? = nil,
        onContinue: @escaping (InspectionSummary) -> Void,
        theme: Theme? = nil
    ) {
        self.sectionName = sectionName
        self.items = items
        self.onSetResult = onSetResult
        self.onOpenDefect = onOpenDefect
        self.onContinue = onContinue
        self.theme = theme
        let seed = items ?? DEFAULT_SECTION_ITEMS
        _results = State(initialValue: Dictionary(uniqueKeysWithValues: seed.map { ($0.key, $0.result) }))
    }

    var body: some View {
        let t = theme ?? envTheme
        let sectionName = self.sectionName ?? "Vehicle Inspection"

        let seedItems = items ?? DEFAULT_SECTION_ITEMS
        let summary = summarizeInspection(items: seedItems, results: results)
        let remaining = summary.total - summary.checked
        let truckItems = seedItems.filter { ($0.group ?? .truck) == .truck }
        let trailerItems = seedItems.filter { $0.group == .trailer }

        VStack(alignment: .leading, spacing: spacing.md) {
            Text(sectionName)
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(testID: "pretrip-section-progress", theme: t) {
                HStack(spacing: spacing.sm) {
                    StatusBadge(
                        label: summary.allChecked ? "Ready" : "In Progress",
                        tone: summary.allChecked ? .success : .info
                    )
                    Text("\(summary.checked) of \(summary.total) items checked")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            Card(title: "Truck", theme: t) {
                ForEach(truckItems, id: \.key) { item in
                    itemRow(item: item, theme: t)
                }
            }

            if !trailerItems.isEmpty {
                Card(title: "Trailer", theme: t) {
                    ForEach(trailerItems, id: \.key) { item in
                        itemRow(item: item, theme: t)
                    }
                }
            }

            if !summary.allChecked {
                Text("Mark every item OK or Defect to continue — \(remaining) item\(remaining == 1 ? "" : "s") to go.")
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(t.warning)
                    .accessibilityIdentifier("pretrip-continue-hint")
            }

            FieldButton(
                label: "Continue",
                onPress: { onContinue(summary) },
                disabled: !summary.allChecked,
                testID: "pretrip-continue",
                theme: t
            )
        }
        .padding(spacing.lg)
    }

    @ViewBuilder
    private func itemRow(item: InspectionItem, theme: Theme) -> some View {
        let value = results[item.key] ?? .notChecked
        VStack(alignment: .leading, spacing: spacing.sm) {
            Text(item.label)
                .font(.system(size: typeScale.body, weight: .semibold))
                .foregroundStyle(theme.text)
            Segmented(
                value: value,
                options: RESULT_OPTIONS,
                onSelect: { next in
                    results[item.key] = next
                    onSetResult?(item.key, next)
                    if next == .defect { onOpenDefect?(item.key) }
                },
                theme: theme,
                testID: "pretrip-item-\(item.key)-control"
            )
        }
        .padding(.vertical, spacing.sm)
        .accessibilityIdentifier("pretrip-item-\(item.key)")
    }
}

// MARK: - 14. Defect Detail

struct DefectDetailScreen: View {
    /// The item being reported, e.g. "Brakes, Service".
    var itemName: String?
    var remarks: String?
    var onChangeRemarks: ((String) -> Void)?
    var requiresReview: Bool?
    var onToggleRequiresReview: ((Bool) -> Void)?
    /// Severity is optional — only shown when company policy supports it.
    var showSeverity: Bool?
    var severity: DefectSeverity?
    var onSelectSeverity: ((DefectSeverity) -> Void)?
    var photoCount: Int?
    var onAddPhoto: (() -> Void)?
    var onSaveDetails: ((DefectDetailPayload) -> Void)?
    var onSaveDefect: () -> Void
    var onCancel: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var remarksText: String
    @State private var requiresReviewChecked: Bool
    @State private var selectedSeverity: DefectSeverity
    @State private var photoCountValue: Int
    @State private var photoAdded = false

    init(
        itemName: String? = nil,
        remarks: String? = nil,
        onChangeRemarks: ((String) -> Void)? = nil,
        requiresReview: Bool? = nil,
        onToggleRequiresReview: ((Bool) -> Void)? = nil,
        showSeverity: Bool? = nil,
        severity: DefectSeverity? = nil,
        onSelectSeverity: ((DefectSeverity) -> Void)? = nil,
        photoCount: Int? = nil,
        onAddPhoto: (() -> Void)? = nil,
        onSaveDetails: ((DefectDetailPayload) -> Void)? = nil,
        onSaveDefect: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.itemName = itemName
        self.remarks = remarks
        self.onChangeRemarks = onChangeRemarks
        self.requiresReview = requiresReview
        self.onToggleRequiresReview = onToggleRequiresReview
        self.showSeverity = showSeverity
        self.severity = severity
        self.onSelectSeverity = onSelectSeverity
        self.photoCount = photoCount
        self.onAddPhoto = onAddPhoto
        self.onSaveDetails = onSaveDetails
        self.onSaveDefect = onSaveDefect
        self.onCancel = onCancel
        self.theme = theme
        _remarksText = State(initialValue: remarks ?? "")
        _requiresReviewChecked = State(initialValue: requiresReview ?? false)
        _selectedSeverity = State(initialValue: severity ?? .minor)
        _photoCountValue = State(initialValue: photoCount ?? 0)
    }

    private var canSave: Bool {
        !remarksText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveDefect() {
        guard canSave else { return }
        onSaveDetails?(
            DefectDetailPayload(
                note: remarksText.trimmingCharacters(in: .whitespacesAndNewlines),
                requiresReview: requiresReviewChecked,
                severity: selectedSeverity,
                photoCount: photoCountValue
            ))
        onSaveDefect()
    }

    var body: some View {
        let t = theme ?? envTheme
        let itemName = self.itemName ?? "Brakes, Service"
        let showSeverity = self.showSeverity ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Defect Reported")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Item", theme: t) {
                Text(itemName)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                StatusBadge(label: "Needs Review", tone: .warning)
            }

            Card(title: "What is wrong?", theme: t) {
                TextField(
                    "Describe the defect so the shop knows what to fix.",
                    text: $remarksText,
                    axis: .vertical
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .padding(spacing.md)
                .frame(minHeight: 96, alignment: .topLeading)
                .background(t.cardMuted)
                .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                .onChange(of: remarksText) { next in onChangeRemarks?(next) }
                .accessibilityIdentifier("defect-remarks")
            }

            if showSeverity {
                Card(title: "Severity", theme: t) {
                    Segmented(
                        value: selectedSeverity,
                        options: SEVERITY_OPTIONS,
                        onSelect: { next in
                            selectedSeverity = next
                            onSelectSeverity?(next)
                        },
                        theme: t,
                        testID: "defect-severity"
                    )
                }
            }

            Card(title: "Photo", theme: t) {
                Text(
                    photoCountValue > 0
                        ? "\(photoCountValue) photo\(photoCountValue == 1 ? "" : "s") attached"
                        : "No photo yet"
                )
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(t.cardMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: sizing.radius)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(t.border)
                )
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))

                if let onAddPhoto {
                    FieldButton(
                        label: "Add Photo",
                        onPress: {
                            onAddPhoto()
                            photoCountValue += 1
                            photoAdded = true
                        },
                        variant: .secondary,
                        testID: "defect-add-photo",
                        theme: t
                    )

                    if photoAdded {
                        Text("Photo added")
                            .font(.system(size: typeScale.label, weight: .bold))
                            .foregroundStyle(t.success)
                            .accessibilityIdentifier("defect-photo-added")
                    }
                } else {
                    Text("Photo attachment is not available in this inspection flow.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                        .accessibilityIdentifier("defect-photo-unavailable")
                }
            }

            Card(title: "Review", theme: t) {
                Button {
                    let next = !requiresReviewChecked
                    requiresReviewChecked = next
                    onToggleRequiresReview?(next)
                } label: {
                    HStack(spacing: spacing.sm) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(requiresReviewChecked ? t.warning : Color.clear)
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(requiresReviewChecked ? t.warning : t.border, lineWidth: 2)
                            Text(requiresReviewChecked ? "!" : "")
                                .font(.system(size: typeScale.label, weight: .heavy))
                                .foregroundStyle(t.onPrimary)
                        }
                        .frame(width: 28, height: 28)
                        Text("Mark Requires Review")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    }
                    .frame(minHeight: sizing.minTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark Requires Review")
                .accessibilityValue(requiresReviewChecked ? "checked" : "unchecked")
                .accessibilityIdentifier("defect-requires-review")
            }

            FieldButton(
                label: "Save Defect",
                onPress: saveDefect,
                disabled: !canSave,
                testID: "defect-save",
                theme: t
            )
            FieldButton(label: "Cancel", onPress: onCancel, variant: .secondary, testID: "defect-cancel", theme: t)
        }
        .padding(spacing.lg)
    }
}

// MARK: - 15. Driver Pre-Trip Review

struct PreTripReviewScreen: View {
    var truckChecked: Int?
    var truckTotal: Int?
    var trailerChecked: Int?
    var trailerTotal: Int?
    var defectCount: Int?
    var remarks: String?
    var defectsCertifiedSafe: Bool? = nil
    var safeCertificationAllowed = true
    var onChangeDefectsCertifiedSafe: ((Bool) -> Void)? = nil
    var onContinueToSignature: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let truckChecked = self.truckChecked ?? 45
        let truckTotal = self.truckTotal ?? 45
        let trailerChecked = self.trailerChecked ?? 16
        let trailerTotal = self.trailerTotal ?? 16
        let defectCount = self.defectCount ?? 0
        let remarks = self.remarks ?? "No visible defects"
        let hasDefects = defectCount > 0

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Pre-Trip Review")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Items checked", theme: t) {
                FieldRow(label: "Truck items checked", value: "\(truckChecked) of \(truckTotal)", theme: t)
                FieldRow(label: "Trailer items checked", value: "\(trailerChecked) of \(trailerTotal)", theme: t)
                FieldRow(label: "Defects", value: "\(defectCount)", theme: t)
            }

            Card(title: "Remarks", theme: t) {
                Text(remarks)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            if hasDefects {
                Card(title: "Defects Reported", tone: .highlight, testID: "pretrip-review-defects", theme: t) {
                    StatusBadge(label: "Needs Review", tone: .warning)
                    Text("\(defectCount) defect\(defectCount == 1 ? "" : "s") need supervisor or mechanic review.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
                DefectSafetyCertificationCard(
                    value: defectsCertifiedSafe,
                    safeCertificationAllowed: safeCertificationAllowed,
                    onChange: { onChangeDefectsCertifiedSafe?($0) },
                    theme: t
                )
            } else {
                Card(testID: "pretrip-review-clean", theme: t) {
                    StatusBadge(label: "Complete", tone: .success)
                    Text("All inspection items are checked and no defects were reported.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            FieldButton(
                label: "Continue to Signature",
                onPress: onContinueToSignature,
                disabled: hasDefects && defectsCertifiedSafe == nil,
                testID: "pretrip-to-signature",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

struct DefectSafetyCertificationCard: View {
    var value: Bool?
    var safeCertificationAllowed = true
    var onChange: (Bool) -> Void
    var theme: Theme

    var body: some View {
        Card(title: "Safe to operate?", tone: .highlight, theme: theme) {
            Text("Required when a defect is reported. Choose No if the vehicle must not be operated.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.text)
            HStack(spacing: spacing.sm) {
                choice(label: "Yes — Safe", selected: value == true, safe: true)
                choice(label: "No — Unsafe", selected: value == false, safe: false)
            }
            if !safeCertificationAllowed {
                Text("An Unsafe severity was reported, so this vehicle cannot be certified safe to operate.")
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(theme.danger)
            } else if value == nil {
                Text("Select Yes or No to continue.")
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(theme.warning)
            }
        }
        .accessibilityIdentifier("dvir-safe-certification")
    }

    private func choice(label: String, selected: Bool, safe: Bool) -> some View {
        Button {
            onChange(safe)
        } label: {
            Text(label)
                .font(.system(size: typeScale.label, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(selected ? theme.onPrimary : theme.text)
                .frame(maxWidth: .infinity, minHeight: sizing.minTouchTarget)
                .padding(.horizontal, spacing.sm)
                .background(selected ? (safe ? theme.primary : theme.danger) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: sizing.radius)
                        .stroke(selected ? (safe ? theme.primary : theme.danger) : theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
        }
        .buttonStyle(.plain)
        .disabled(safe && !safeCertificationAllowed)
        .opacity(safe && !safeCertificationAllowed ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 16. Driver Pre-Trip Signature

/// Payload for `onCompletePreTrip` — the captured signature + signer name.
struct PreTripSignaturePayload {
    var signature: SignatureValue
    var signerName: String
}

struct PreTripSignatureScreen: View {
    var driverName: String?
    var onChangeDriverName: ((String) -> Void)?
    /// Whether the signature pad already holds a captured signature.
    /// ponytail: kept as a stored no-op prop to match the TS source exactly — the TS component never
    /// reads it either; `signed` there (and here) always comes from the pad's own local state.
    var signatureCaptured: Bool?
    var onCaptureSignature: (() -> Void)?
    var onClearSignature: (() -> Void)?
    var dateTime: String?
    var truck: String?
    var trailer: String?
    /// Driver attestation shown above the pad; defaults to the canonical DVIR pre-trip text.
    var certificationText: String?
    var onCompletePreTrip: (PreTripSignaturePayload) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirming = false
    @State private var name: String
    @State private var signature: SignatureValue?

    init(
        driverName: String? = nil,
        onChangeDriverName: ((String) -> Void)? = nil,
        signatureCaptured: Bool? = nil,
        onCaptureSignature: (() -> Void)? = nil,
        onClearSignature: (() -> Void)? = nil,
        dateTime: String? = nil,
        truck: String? = nil,
        trailer: String? = nil,
        certificationText: String? = nil,
        onCompletePreTrip: @escaping (PreTripSignaturePayload) -> Void,
        theme: Theme? = nil
    ) {
        self.driverName = driverName
        self.onChangeDriverName = onChangeDriverName
        self.signatureCaptured = signatureCaptured
        self.onCaptureSignature = onCaptureSignature
        self.onClearSignature = onClearSignature
        self.dateTime = dateTime
        self.truck = truck
        self.trailer = trailer
        self.certificationText = certificationText
        self.onCompletePreTrip = onCompletePreTrip
        self.theme = theme
        _name = State(initialValue: driverName ?? "")
    }

    var body: some View {
        let t = theme ?? envTheme
        let dateTime = self.dateTime ?? "Today, 6:12 AM"
        let truck = self.truck ?? "Truck 7"
        let trailer = self.trailer ?? "Vacuum Trailer 19"
        let signed = signature != nil
        let prefilled = !(driverName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Driver Signature")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(tone: .highlight, theme: t) {
                Text(certificationText ?? DVIR_PRETRIP_CERTIFICATION_TEXT)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            Card(title: "Driver", theme: t) {
                TextField("Your name or driver ID", text: $name)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .frame(minHeight: sizing.minTouchTarget)
                    .background(t.cardMuted)
                    .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .onChange(of: name) { next in onChangeDriverName?(next) }
                    .accessibilityIdentifier("signature-driver-name")

                if prefilled {
                    Text("From your sign-in — edit only if needed.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                        .accessibilityIdentifier("signature-driver-prefilled")
                }
            }

            Card(title: "Signature", theme: t) {
                SignatureField(
                    theme: t,
                    value: signature,
                    onChange: { next in
                        signature = next
                        if next == nil {
                            onClearSignature?()
                        } else {
                            onCaptureSignature?()
                        }
                    },
                    testID: "pretrip-signature"
                )
            }

            Card(title: "Date / Time", theme: t) {
                Text(dateTime)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            if confirming {
                Card(
                    title: "Complete Pre-Trip Inspection?",
                    tone: .highlight,
                    testID: "signature-confirm",
                    theme: t
                ) {
                    Text("You are confirming the inspection for \(truck) and \(trailer).")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    FieldButton(
                        label: "Complete Pre-Trip",
                        onPress: {
                            confirming = false
                            if let signature {
                                onCompletePreTrip(PreTripSignaturePayload(signature: signature, signerName: name))
                            }
                        },
                        testID: "signature-confirm-complete",
                        theme: t
                    )
                    FieldButton(
                        label: "Cancel",
                        onPress: { confirming = false },
                        variant: .secondary,
                        testID: "signature-confirm-cancel",
                        theme: t
                    )
                }
            } else {
                FieldButton(
                    label: "Complete Pre-Trip",
                    onPress: { confirming = true },
                    disabled: !signed || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    testID: "signature-complete",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

// MARK: - 17. Driver Pre-Trip Complete

struct PreTripCompleteScreen: View {
    var hasDefects: Bool?
    var defectCount: Int?
    var truck: String?
    var trailer: String?
    var onStartNextJob: () -> Void
    var onViewDefectStatus: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let hasDefects = self.hasDefects ?? false
        let defectCount = self.defectCount ?? 0
        let truck = self.truck ?? "Truck 7"
        let trailer = self.trailer ?? "Vacuum Trailer 19"

        if hasDefects {
            VStack(alignment: .leading, spacing: spacing.md) {
                Text("Defects Submitted")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)

                Card(tone: .highlight, testID: "pretrip-complete-defects", theme: t) {
                    StatusBadge(label: "Submitted", tone: .info)
                    Text("Job work may be locked until review is complete.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    if defectCount > 0 {
                        Text("\(defectCount) defect\(defectCount == 1 ? "" : "s") reported on \(truck) and \(trailer).")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                }

                if let onViewDefectStatus {
                    FieldButton(
                        label: "View Defect Status",
                        onPress: onViewDefectStatus,
                        testID: "pretrip-view-defect-status",
                        theme: t
                    )
                }
            }
            .padding(spacing.lg)
        } else {
            VStack(alignment: .leading, spacing: spacing.md) {
                Text("Pre-Trip Complete")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)

                Card(tone: .highlight, testID: "pretrip-complete-clean", theme: t) {
                    StatusBadge(label: "Complete", tone: .success)
                    Text("Vehicle condition marked satisfactory.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text("Next step: Start your first job.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }

                FieldButton(
                    label: "Start Next Job", onPress: onStartNextJob, testID: "pretrip-start-next-job", theme: t)
            }
            .padding(spacing.lg)
        }
    }
}

// MARK: - Local presentational helpers

/// A label : value line used inside summary cards.
private struct FieldRow: View {
    var label: String
    var value: String
    var theme: Theme

    var body: some View {
        HStack(alignment: .center, spacing: spacing.md) {
            Text(label)
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

/// Segmented control — the OK / Defect (and severity) selector. NOT a checkbox: each option is an
/// explicit, labeled choice so "checked = defective" can never be misread (GUI Master §23.4). The
/// active option is styled from the `value` the caller drives off its own state.
private struct Segmented<T: RawRepresentable & Equatable>: View where T.RawValue == String {
    var value: T
    var options: [SegmentOption<T>]
    var onSelect: (T) -> Void
    var theme: Theme
    var testID: String?

    var body: some View {
        let t = theme
        HStack(spacing: 0) {
            ForEach(options, id: \.key.rawValue) { opt in
                let selected = opt.key == value
                let danger = opt.key.rawValue == "defect" || opt.key.rawValue == "unsafe"
                let bg = selected ? (danger ? t.danger : t.primary) : Color.clear
                let fg = selected ? t.onPrimary : t.textMuted

                Button {
                    onSelect(opt.key)
                } label: {
                    Text(opt.label)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: sizing.minTouchTarget)
                        .padding(.horizontal, spacing.sm)
                        .background(bg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("\(testID ?? "segment")-\(opt.key.rawValue)")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: sizing.radius)
                .stroke(t.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
        .accessibilityIdentifier(ifPresent: testID)
    }
}

// MARK: - Sample fallbacks (used only when a prop is absent)

/// Build an all-"not-checked" item from a label (key = slugified label).
private func dvirItem(_ label: String, _ group: InspectionItem.Group) -> InspectionItem {
    let slug =
        label
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "(^-|-$)", with: "", options: .regularExpression)
    return InspectionItem(key: "\(group.rawValue)-\(slug)", label: label, result: .notChecked, group: group)
}

private let TRUCK_ITEM_LABELS: [String] = [
    "Air Compressor",
    "Air Lines",
    "Battery / Box",
    "Belts and Hoses",
    "Body",
    "Brake Accessories",
    "Brakes, Parking",
    "Brakes, Service",
    "Clutch",
    "Coolant Level",
    "Defroster / Heater",
    "Drive Line",
    "Engine Oil Level",
    "Exhaust System",
    "Fifth Wheel",
    "Visible Fluid Leaks",
    "Frame and Assembly",
    "Front Axle",
    "Fuel Tanks / Caps",
    "Glad Hands",
    "Headlights / High Beams",
    "Horn",
    "Mirrors",
    "Mud Flaps",
    "Muffler",
    "Oil Pressure Gauge",
    "Power Steering",
    "Radiator",
    "Reflectors / Reflective Tape",
    "Safe Loading",
    "Springs",
    "Starter",
    "Steering Mechanism",
    "Tail Lights / Turn Signals",
    "Tires (Tractor)",
    "Transmission",
    "Trip Recorder / ELD",
    "Wheels and Rims (Tractor)",
    "Windows",
    "Windshield",
    "Windshield Wipers / Washer",
    "Fire Extinguisher",
    "Emergency Triangles / Flares",
    "Seat Belts",
    "Cab / Doors",
    "Gauges and Warning Lights",
]

private let TRAILER_ITEM_LABELS: [String] = [
    "Brake Connections",
    "Brakes (Trailer)",
    "Coupling Devices",
    "Doors / Hatches",
    "Hitch / Pintle",
    "Landing Gear",
    "Clearance / Marker Lights",
    "Tail / Turn Lights (Trailer)",
    "Vacuum Pump",
    "Product Hoses",
    "Reflectors / Tape (Trailer)",
    "Suspension (Trailer)",
    "Tank / Vessel Integrity",
    "Tires (Trailer)",
    "Valves / Fittings",
    "Wheels and Rims (Trailer)",
]

/// The full company DVIR checklist, every item starting "not-checked" (a driver must actively mark
/// each OK or Defect; nothing is pre-passed).
private let DEFAULT_SECTION_ITEMS: [InspectionItem] =
    TRUCK_ITEM_LABELS.map { dvirItem($0, .truck) } + TRAILER_ITEM_LABELS.map { dvirItem($0, .trailer) }

func defaultPreTripInspectionItems() -> [InspectionItem] {
    DEFAULT_SECTION_ITEMS
}
