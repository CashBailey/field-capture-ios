//
//  EvidenceScreens.swift
//  Ported from apps/mobile/src/screens/EvidenceScreens.tsx
//
//  Evidence, photo, receipt, GPS, signature, and print screens (GUI Master §12 / screens 53-61):
//
//    53. Job Evidence          — evidence categories + Add Evidence menu
//    54. Camera Capture        — placeholder camera viewfinder + capture
//    55. Photo Review          — review a just-captured photo, save/retake/delete
//    56. Receipt Capture       — capture / choose / skip a receipt image
//    57. Receipt Form         — vendor / amount / category for a receipt
//    58. Signature Capture     — signer details + placeholder signature pad
//    59. GPS Capture           — driver-safe location evidence (coords hidden)
//    60. Print Ticket          — driver-safe printing of ticket / summary / receipt
//    61. Job Complete Review   — end-of-job summary + start next / end day
//
//  Presentational only. No camera/signature/GPS/print native modules — each capture surface is a
//  bordered placeholder frame; the real capture is wired elsewhere. Driver-facing language only:
//  never render UUIDs, coordinates by default, sync internals, or any storage/transport wording
//  (GUI Master §20). Statuses use the approved label set, mapped to StatusBadge tones.
//
//  Draft fields keep local editing state, but capture/save/print controls appear only when a host
//  callback can perform the action. Missing data renders as unavailable instead of falling back to
//  sample jobs, timestamps, sync results, or success confirmations.
//

import FieldDomain
import SwiftUI

// MARK: - Shared

/// The approved status labels this file uses, mapped to a reinforcing badge tone (GUI Master §20).
enum EvidenceStatus: String {
    case notStarted = "Not Started"
    case inProgress = "In Progress"
    case required = "Required"
    case needsReview = "Needs Review"
    case savedOnPhone = "Saved on Phone"
    case pendingSync = "Pending Sync"
    case syncing = "Syncing"
    case synced = "Synced"
    case submitted = "Submitted"
    case complete = "Complete"
}

let STATUS_TONE: [EvidenceStatus: Tone] = [
    .notStarted: .neutral,
    .inProgress: .info,
    .required: .warning,
    .needsReview: .warning,
    .savedOnPhone: .info,
    .pendingSync: .info,
    .syncing: .info,
    .synced: .success,
    .submitted: .success,
    .complete: .success,
]

private struct StatusPill: View {
    var status: EvidenceStatus
    var testID: String?

    var body: some View {
        StatusBadge(label: status.rawValue, tone: STATUS_TONE[status] ?? .neutral, testID: testID)
    }
}

/// A left/right row — the `styles.rowBetween` (`flexDirection: row, justifyContent: space-between`)
/// equivalent, factored out since ~15 call sites in this file use the same shape.
private struct RowBetween<Left: View, Right: View>: View {
    var testID: String?
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .center, spacing: spacing.sm) {
            left()
            Spacer(minLength: 0)
            right()
        }
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// An inline action-status line. The caller supplies the tone so an in-progress request is never
/// rendered as a confirmed success. Renders nothing until an action has started.
private struct FeedbackLine: View {
    var theme: Theme
    var message: String?
    var tone: Tone = .success
    var testID: String?

    private var badgeLabel: String {
        switch tone {
        case .success: return "Done"
        case .warning: return "Waiting"
        case .danger: return "Failed"
        case .info: return "In Progress"
        case .neutral: return "Status"
        }
    }

    var body: some View {
        if let message {
            HStack(alignment: .center, spacing: spacing.sm) {
                Text(message)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(theme.textMuted)
                Spacer(minLength: 0)
                StatusBadge(label: badgeLabel, tone: tone)
            }
            .accessibilityIdentifier(ifPresent: testID)
        }
    }
}

/// A bordered, dashed placeholder where a native capture surface (camera/pad/map) lands later.
/// When `onPress` is supplied it becomes tappable so the driver gets a visible response (e.g. the
/// signature pad "captures" a mark) even though the real surface is wired elsewhere.
private struct PlaceholderFrame: View {
    var theme: Theme
    var label: String
    var hint: String?
    var testID: String?
    var onPress: (() -> Void)?
    var active: Bool = false

    var body: some View {
        Group {
            if let onPress {
                Button(action: onPress) { frameBody }
                    .buttonStyle(FramePressStyle())
            } else {
                frameBody
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
            }
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(ifPresent: testID)
    }

    private var frameBody: some View {
        let t = theme
        let borderColor = active ? t.primary : t.border
        return VStack(spacing: spacing.xs) {
            Text(label)
                .font(.system(size: typeScale.heading, weight: .bold))
                .foregroundStyle(t.textMuted)
            if let hint {
                Text(hint)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(t.cardMuted)
        .overlay(
            RoundedRectangle(cornerRadius: sizing.radius)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(borderColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
    }
}

private struct FramePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for the chip rows below.
/// ponytail: duplicated from the same-named private layout in Design/AppHeader.swift (file-private
/// there, so unreachable from here) rather than promoting a two-line layout into a shared file —
/// promote it if a third caller needs it.
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

/// A simple labeled chip row used to pick a category / type. Selection is presentational.
private struct ChipPicker: View {
    var theme: Theme
    var options: [String]
    var selected: String
    var onSelect: (String) -> Void
    var idPrefix: String

    var body: some View {
        let t = theme
        FlowLayout(spacing: spacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    onSelect(option)
                } label: {
                    Text(option)
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .foregroundStyle(isSelected ? t.onPrimary : t.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 40)
                        .background(isSelected ? t.primary : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? t.primary : t.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("\(idPrefix)-\(option)")
            }
        }
    }
}

/// TS string-literal union `'default' | 'numeric'` on the un-exported `Field` helper's keyboard type.
private enum FieldKeyboardType: String {
    case `default`
    case numeric
}

private struct Field: View {
    var theme: Theme
    var label: String
    var value: String
    var onChangeText: (String) -> Void
    var placeholder: String
    var testID: String
    var keyboardType: FieldKeyboardType = .default

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(label)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(t.textMuted)
            TextField(
                "",
                text: Binding(get: { value }, set: onChangeText),
                prompt: Text(placeholder).foregroundColor(t.textMuted)
            )
            .keyboardType(keyboardType == .numeric ? .decimalPad : .default)
            .font(.system(size: typeScale.body))
            .foregroundStyle(t.text)
            .padding(.horizontal, spacing.md)
            .frame(minHeight: 48)
            .background(t.card)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.radius)
                    .stroke(t.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
            .accessibilityLabel(label)
            .accessibilityIdentifier(testID)
        }
    }
}

// MARK: - 53. Job Evidence

struct EvidenceCategory: Equatable {
    var key: String
    /// Driver-facing category name, e.g. "Field Photos".
    var label: String
    var count: Int
    var status: EvidenceStatus
    /// Plain time of last capture, e.g. "Today 8:47 AM". Nil if nothing captured yet.
    var lastCaptured: String?
}

let DEFAULT_EVIDENCE_CATEGORIES: [EvidenceCategory] = []

/// A single add-evidence menu entry. `key` is reported verbatim to `onAddEvidence`.
struct EvidenceMenuItem {
    var key: String
    var label: String
}

enum EvidenceMenuRoute: String {
    case camera
    case receipt
    case signature
}

func evidenceRouteForMenuKey(_ key: String) -> EvidenceMenuRoute {
    switch key {
    case "receipt-photo":
        return .receipt
    case "signature", "customer-signature":
        return .signature
    default:
        return .camera
    }
}

/**
 * The add-evidence menu the driver sees, derived from the job context so the offered items match
 * what this job actually needs (items 5-8):
 *  - `ticket-photo` is offered ONLY when the ticket's captureMethod is 'hybrid'.
 *  - `customer-signature` is offered ONLY for flowback jobs (driver signature is always available).
 *  - `gps-event` is NOT offered — location evidence is captured automatically (background geofence),
 *    never a manual driver step.
 *  - an OPTIONAL `photo` item is always offered so the driver can add multiple captioned photos.
 */
func buildEvidenceMenu(captureMethod: TicketCaptureMethod? = nil, jobType: String? = nil) -> [EvidenceMenuItem] {
    let flowback = isFlowbackJob(jobType)
    var menu: [EvidenceMenuItem] = [
        EvidenceMenuItem(key: "field-photo", label: "Field Photo"),
        EvidenceMenuItem(key: "disposal-photo", label: "Disposal Photo"),
    ]
    if captureMethod == .hybrid {
        menu.append(EvidenceMenuItem(key: "ticket-photo", label: "Ticket Photo"))
    }
    menu.append(EvidenceMenuItem(key: "receipt-photo", label: "Receipt Photo"))
    menu.append(EvidenceMenuItem(key: "signature", label: "Driver Signature"))
    if flowback {
        menu.append(EvidenceMenuItem(key: "customer-signature", label: "Customer Signature"))
    }
    // GPS event intentionally omitted — captured automatically, not a driver step (item 7).
    menu.append(EvidenceMenuItem(key: "photo", label: "Add Photo (optional)"))
    menu.append(EvidenceMenuItem(key: "other", label: "Other"))
    return menu
}

struct JobEvidenceScreen: View {
    var jobLabel: String?
    var categories: [EvidenceCategory]?
    /// The ticket's capture method — gates whether Ticket Photo is offered (item 5).
    var captureMethod: TicketCaptureMethod?
    /// The SR's job type — gates whether Customer Signature is offered (item 6, flowback only).
    var jobType: String?
    /// Called with the menu item key (e.g. "field-photo") when the driver picks what to add.
    var onAddEvidence: ((String) -> Void)?
    /// Called when the driver adds an optional, self-titled photo (item 8). Never required.
    var onAddPhoto: ((String) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var menuOpen = false
    @State private var picked: String?
    // Optional photos the driver titles themselves — multiple allowed, never required (item 8).
    @State private var photoTitle = ""

    var body: some View {
        let t = theme ?? envTheme
        let categories = self.categories ?? DEFAULT_EVIDENCE_CATEGORIES
        let menuItems = buildEvidenceMenu(captureMethod: captureMethod, jobType: jobType)

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job Evidence")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text(jobLabel ?? "Job details not provided")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            if categories.isEmpty {
                Card(title: "No evidence summary available", tone: .highlight, theme: t) {
                    Text("No saved evidence categories were provided for this job.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            } else {
                ForEach(categories, id: \.key) { cat in
                    Card(title: cat.label, testID: "evidence-cat-\(cat.key)", theme: t) {
                        RowBetween {
                            Text(
                                cat.count == 0
                                    ? "Nothing captured yet" : "\(cat.count) item\(cat.count == 1 ? "" : "s")"
                            )
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                        } right: {
                            StatusPill(status: cat.status, testID: "evidence-status-\(cat.key)")
                        }
                        if let lastCaptured = cat.lastCaptured {
                            Text("Last captured \(lastCaptured)")
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.textMuted)
                        }
                    }
                }
            }

            if onAddPhoto != nil {
                Card(title: "Optional photos", testID: "optional-photos", theme: t) {
                    Text("Add as many photos as you like and title each one. These are optional.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                    Field(
                        theme: t,
                        label: "Photo title",
                        value: photoTitle,
                        onChangeText: { photoTitle = $0 },
                        placeholder: "e.g. Tank gauge before load",
                        testID: "optional-photo-title-input"
                    )
                    FieldButton(
                        label: "Add Photo", onPress: addOptionalPhoto, variant: .secondary,
                        testID: "optional-photo-add")
                }
            }

            Card(title: "Add evidence", tone: .highlight, theme: t) {
                if onAddEvidence == nil {
                    Text("Evidence capture is unavailable from this screen.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } else if menuOpen {
                    VStack(spacing: spacing.sm) {
                        ForEach(menuItems, id: \.key) { item in
                            FieldButton(
                                label: item.label,
                                onPress: {
                                    menuOpen = false
                                    picked = "Opening \(item.label.lowercased()) capture…"
                                    onAddEvidence?(item.key)
                                },
                                variant: .secondary,
                                testID: "evidence-add-\(item.key)"
                            )
                        }
                        FieldButton(
                            label: "Cancel", onPress: { menuOpen = false }, variant: .secondary,
                            testID: "evidence-add-cancel")
                    }
                } else {
                    FieldButton(label: "Add Evidence", onPress: { menuOpen = true }, testID: "evidence-add-open")
                }
                FeedbackLine(theme: t, message: picked, tone: .info, testID: "evidence-add-feedback")
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("job-evidence")
    }

    private func addOptionalPhoto() {
        let title = photoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        photoTitle = ""
        picked = "Opening photo capture for \"\(title)\"…"
        onAddPhoto?(title)
    }
}

// MARK: - 54. Camera Capture

struct CameraCaptureScreen: View {
    var categoryLabel: String?
    /// Called when the driver presses the shutter; the captured photo is reviewed elsewhere.
    var onCapture: (() -> Void)?
    var onCancel: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var actionMessage: String?

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Take Photo")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text(categoryLabel ?? "Field Photo")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            PlaceholderFrame(
                theme: t,
                label: "Camera view",
                hint: onCapture == nil
                    ? "Camera capture is unavailable in this build." : "Open the camera to take a photo.",
                testID: "camera-viewfinder"
            )

            FieldButton(
                label: "Open Camera",
                onPress: {
                    actionMessage = "Opening camera…"
                    onCapture?()
                },
                disabled: onCapture == nil,
                testID: "camera-capture-btn"
            )
            FeedbackLine(theme: t, message: actionMessage, tone: .info, testID: "camera-feedback")
            if let onCancel {
                FieldButton(label: "Cancel", onPress: onCancel, variant: .secondary, testID: "camera-cancel")
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("camera-capture")
    }
}

// MARK: - 55. Photo Review

let PHOTO_CATEGORIES: [String] = ["Field Photo", "Disposal Photo", "Ticket Photo", "Receipt Photo", "Other"]

struct PhotoReviewScreen: View {
    var category: String?
    var caption: String?
    var jobLabel: String?
    var timestamp: String?
    var gpsAttached: Bool?
    /// Status after the driver presses Use Photo; shown once saved.
    var savedStatus: EvidenceStatus?
    var onChangeCategory: ((String) -> Void)?
    var onChangeCaption: ((String) -> Void)?
    var onUsePhoto: (() -> Void)?
    var onRetake: (() -> Void)?
    var onDelete: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var categoryState: String
    @State private var captionState: String
    @State private var actionMessage: String?

    init(
        category: String? = nil,
        caption: String? = nil,
        jobLabel: String? = nil,
        timestamp: String? = nil,
        gpsAttached: Bool? = nil,
        savedStatus: EvidenceStatus? = nil,
        onChangeCategory: ((String) -> Void)? = nil,
        onChangeCaption: ((String) -> Void)? = nil,
        onUsePhoto: (() -> Void)? = nil,
        onRetake: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.category = category
        self.caption = caption
        self.jobLabel = jobLabel
        self.timestamp = timestamp
        self.gpsAttached = gpsAttached
        self.savedStatus = savedStatus
        self.onChangeCategory = onChangeCategory
        self.onChangeCaption = onChangeCaption
        self.onUsePhoto = onUsePhoto
        self.onRetake = onRetake
        self.onDelete = onDelete
        self.theme = theme
        _categoryState = State(initialValue: category ?? "Field Photo")
        _captionState = State(initialValue: caption ?? "")
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Photo Review")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            PlaceholderFrame(theme: t, label: "Photo preview", testID: "photo-preview")

            if let savedStatus {
                RowBetween {
                    Text("Saved")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } right: {
                    StatusPill(status: savedStatus, testID: "photo-saved-status")
                }
            }

            Card(title: "Details", theme: t) {
                Text("Category")
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                ChipPicker(
                    theme: t,
                    options: PHOTO_CATEGORIES,
                    selected: categoryState,
                    onSelect: { value in
                        categoryState = value
                        onChangeCategory?(value)
                    },
                    idPrefix: "photo-category"
                )
                Field(
                    theme: t,
                    label: "Caption",
                    value: captionState,
                    onChangeText: { value in
                        captionState = value
                        onChangeCaption?(value)
                    },
                    placeholder: "Add a short caption",
                    testID: "photo-caption-input"
                )
                RowBetween {
                    Text("Job")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                } right: {
                    Text(jobLabel ?? "Not provided")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.text)
                }
                RowBetween {
                    Text("Timestamp")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                } right: {
                    Text(timestamp ?? "Not provided")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.text)
                }
                HStack(alignment: .center, spacing: spacing.sm) {
                    Text("GPS attached")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                    Spacer(minLength: 0)
                    StatusBadge(
                        label: gpsAttached == true ? "Yes" : "No", tone: gpsAttached == true ? .success : .neutral,
                        testID: "photo-gps-attached")
                }
                .accessibilityLabel("GPS attached")
                .accessibilityValue(gpsAttached == true ? "Yes" : "No")
            }

            if let onUsePhoto {
                FieldButton(
                    label: "Use Photo",
                    onPress: {
                        actionMessage = "Saving photo…"
                        onUsePhoto()
                    },
                    testID: "photo-use"
                )
            }
            if let onRetake {
                FieldButton(
                    label: "Retake",
                    onPress: onRetake,
                    variant: .secondary,
                    testID: "photo-retake"
                )
            }
            if let onDelete {
                FieldButton(
                    label: "Delete",
                    onPress: onDelete,
                    variant: .destructive,
                    testID: "photo-delete"
                )
            }
            if onUsePhoto == nil, onRetake == nil, onDelete == nil {
                Text("Photo actions are unavailable in this build.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: actionMessage, tone: .info, testID: "photo-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("photo-review")
    }
}

// MARK: - 56. Receipt Capture

struct ReceiptCaptureScreen: View {
    var onCaptureReceipt: (() -> Void)?
    var onChooseFromPhotos: (() -> Void)?
    var onSkipPhoto: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var message: String?

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Receipt Photo")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text("Capture the receipt so it stays with this job.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            PlaceholderFrame(
                theme: t,
                label: "Receipt image",
                hint: "Lay the receipt flat and fill the frame.",
                testID: "receipt-frame"
            )

            if let onCaptureReceipt {
                FieldButton(
                    label: "Capture Receipt",
                    onPress: {
                        message = "Opening camera…"
                        onCaptureReceipt()
                    },
                    testID: "receipt-capture-btn"
                )
            }
            if let onChooseFromPhotos {
                FieldButton(
                    label: "Choose from Photos",
                    onPress: {
                        message = "Opening photo library…"
                        onChooseFromPhotos()
                    },
                    variant: .secondary,
                    testID: "receipt-choose"
                )
            }
            if let onSkipPhoto {
                FieldButton(
                    label: "Skip Photo",
                    onPress: onSkipPhoto,
                    variant: .secondary,
                    testID: "receipt-skip"
                )
            }
            if onCaptureReceipt == nil, onChooseFromPhotos == nil, onSkipPhoto == nil {
                Text("Receipt image capture is unavailable in this build.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: message, tone: .info, testID: "receipt-capture-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("receipt-capture")
    }
}

// MARK: - 57. Receipt Form

let RECEIPT_CATEGORIES: [String] = ["Disposal", "Fuel", "Parts", "Other"]

/// The shape the driver's receipt entry is reported as on Save (mirrors the TS inline object type).
struct ReceiptDraft {
    var category: String
    var vendor: String
    var receiptNumber: String
    var amount: String
    var notes: String
}

struct ReceiptFormScreen: View {
    var category: String?
    var vendor: String?
    var receiptNumber: String?
    var amount: String?
    var notes: String?
    var hasPhoto: Bool?
    var onSave: ((ReceiptDraft) -> Void)?
    var onAddPhoto: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var categoryState: String
    @State private var vendorState: String
    @State private var receiptNumberState: String
    @State private var amountState: String
    @State private var notesState: String
    @State private var savedMessage: String?

    init(
        category: String? = nil,
        vendor: String? = nil,
        receiptNumber: String? = nil,
        amount: String? = nil,
        notes: String? = nil,
        hasPhoto: Bool? = nil,
        onSave: ((ReceiptDraft) -> Void)? = nil,
        onAddPhoto: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.category = category
        self.vendor = vendor
        self.receiptNumber = receiptNumber
        self.amount = amount
        self.notes = notes
        self.hasPhoto = hasPhoto
        self.onSave = onSave
        self.onAddPhoto = onAddPhoto
        self.theme = theme
        _categoryState = State(initialValue: category ?? "Disposal")
        _vendorState = State(initialValue: vendor ?? "")
        _receiptNumberState = State(initialValue: receiptNumber ?? "")
        _amountState = State(initialValue: amount ?? "")
        _notesState = State(initialValue: notes ?? "")
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Receipt")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Receipt details", theme: t) {
                Text("Category")
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.textMuted)
                ChipPicker(
                    theme: t,
                    options: RECEIPT_CATEGORIES,
                    selected: categoryState,
                    onSelect: { categoryState = $0 },
                    idPrefix: "receipt-category"
                )
                Field(
                    theme: t,
                    label: "Vendor",
                    value: vendorState,
                    onChangeText: { vendorState = $0 },
                    placeholder: "e.g. Acme Disposal Yard",
                    testID: "receipt-vendor-input"
                )
                Field(
                    theme: t,
                    label: "Receipt Number",
                    value: receiptNumberState,
                    onChangeText: { receiptNumberState = $0 },
                    placeholder: "e.g. 2026-000001",
                    testID: "receipt-number-input"
                )
                Field(
                    theme: t,
                    label: "Amount",
                    value: amountState,
                    onChangeText: { amountState = $0 },
                    placeholder: "0.00",
                    testID: "receipt-amount-input",
                    keyboardType: .numeric
                )
                Field(
                    theme: t,
                    label: "Notes",
                    value: notesState,
                    onChangeText: { notesState = $0 },
                    placeholder: "Anything worth noting",
                    testID: "receipt-notes-input"
                )
            }

            Card(title: "Receipt Photo", theme: t) {
                RowBetween {
                    Text(hasPhoto == true ? "Photo attached" : "No photo attached yet")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } right: {
                    StatusBadge(
                        label: hasPhoto == true ? "Attached" : "Optional", tone: hasPhoto == true ? .success : .neutral,
                        testID: "receipt-photo-state")
                }
                if let onAddPhoto {
                    FieldButton(
                        label: hasPhoto == true ? "Replace Photo" : "Add Photo",
                        onPress: onAddPhoto,
                        variant: .secondary,
                        testID: "receipt-add-photo"
                    )
                }
            }

            FieldButton(
                label: "Save Receipt",
                onPress: {
                    savedMessage = "Save requested…"
                    onSave?(
                        ReceiptDraft(
                            category: categoryState,
                            vendor: vendorState.trimmingCharacters(in: .whitespacesAndNewlines),
                            receiptNumber: receiptNumberState.trimmingCharacters(in: .whitespacesAndNewlines),
                            amount: amountState.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: notesState.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                },
                disabled: onSave == nil,
                testID: "receipt-save"
            )
            if onSave == nil {
                Text("Receipt saving is unavailable in this build.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: savedMessage, tone: .info, testID: "receipt-save-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("receipt-form")
    }
}

// MARK: - 58. Signature Capture

let SIGNATURE_TYPES: [String] = ["Customer", "Driver", "Disposal Site", "Supervisor", "Other"]

/// The shape the driver's signature entry is reported as on Save (mirrors the TS inline object type).
struct SignatureDraft {
    var signatureType: String
    var signerName: String
    var company: String
    var role: String
}

struct SignatureCaptureScreen: View {
    var signatureType: String?
    var signerName: String?
    var company: String?
    var role: String?
    var dateTime: String?
    /// True once the driver has drawn something on the pad placeholder.
    /// ponytail: kept for prop-shape fidelity with the TS source, which declares it but never reads
    /// it either — `hasSignature` is derived from the local `signature` state below instead.
    var hasSignature: Bool?
    var onClear: (() -> Void)?
    var onSave: ((SignatureDraft) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var signatureTypeState: String
    @State private var signerNameState: String
    @State private var companyState: String
    @State private var roleState: String
    @State private var signature: SignatureValue?
    @State private var savedMessage: String?

    init(
        signatureType: String? = nil,
        signerName: String? = nil,
        company: String? = nil,
        role: String? = nil,
        dateTime: String? = nil,
        hasSignature: Bool? = nil,
        onClear: (() -> Void)? = nil,
        onSave: ((SignatureDraft) -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.signatureType = signatureType
        self.signerName = signerName
        self.company = company
        self.role = role
        self.dateTime = dateTime
        self.hasSignature = hasSignature
        self.onClear = onClear
        self.onSave = onSave
        self.theme = theme
        _signatureTypeState = State(initialValue: signatureType ?? "Customer")
        _signerNameState = State(initialValue: signerName ?? "")
        _companyState = State(initialValue: company ?? "")
        _roleState = State(initialValue: role ?? "")
    }

    var body: some View {
        let t = theme ?? envTheme
        let hasSignatureDrawn = signature != nil

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Signature")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Signature type", theme: t) {
                ChipPicker(
                    theme: t,
                    options: SIGNATURE_TYPES,
                    selected: signatureTypeState,
                    onSelect: { signatureTypeState = $0 },
                    idPrefix: "signature-type"
                )
            }

            Card(title: "Signer", theme: t) {
                Field(
                    theme: t,
                    label: "Signer Name",
                    value: signerNameState,
                    onChangeText: { signerNameState = $0 },
                    placeholder: "Full name",
                    testID: "signature-name-input"
                )
                Field(
                    theme: t,
                    label: "Company",
                    value: companyState,
                    onChangeText: { companyState = $0 },
                    placeholder: "e.g. Acme Energy",
                    testID: "signature-company-input"
                )
                Field(
                    theme: t,
                    label: "Role",
                    value: roleState,
                    onChangeText: { roleState = $0 },
                    placeholder: "e.g. Pumper",
                    testID: "signature-role-input"
                )
            }

            Card(title: "Signature Pad", theme: t) {
                SignatureField(
                    theme: t,
                    value: signature,
                    onChange: { next in
                        signature = next
                        savedMessage = nil
                        if next == nil { onClear?() }
                    },
                    testID: "signature-pad"
                )
            }

            RowBetween {
                Text("Date / Time")
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.textMuted)
            } right: {
                Text(dateTime ?? "Recorded when saved")
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(t.text)
            }

            FieldButton(
                label: "Save Signature",
                onPress: {
                    savedMessage = "Save requested…"
                    onSave?(
                        SignatureDraft(
                            signatureType: signatureTypeState,
                            signerName: signerNameState.trimmingCharacters(in: .whitespacesAndNewlines),
                            company: companyState.trimmingCharacters(in: .whitespacesAndNewlines),
                            role: roleState.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                },
                disabled: !hasSignatureDrawn || signerNameState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || onSave == nil,
                testID: "signature-save"
            )
            if onSave == nil {
                Text("Signature saving is unavailable in this build.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: savedMessage, tone: .info, testID: "signature-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("signature-capture")
    }
}

// MARK: - 59. GPS Capture

// Yard Arrival/Departure are intentionally absent: yard events are captured automatically by the
// background geofence, not chosen by the driver (items 4 & 7). Only job/disposal events remain for
// any residual manual classification, and "out"/departure is the final event in the sequence.
let GPS_EVENT_TYPES: [String] = ["Job Arrival", "Disposal Arrival", "Disposal Departure", "Job Departure", "Other"]

struct GpsCaptureScreen: View {
    var eventType: String?
    /// Whether the last capture confirmed the driver is in the expected area.
    var verified: Bool?
    var withinArea: Bool?
    /// Plain accuracy text, e.g. "18 ft".
    var accuracy: String?
    var capturedAt: String?
    /// Human-readable coordinates, only revealed under "Show Details".
    var coordinates: String?
    /// Plain area name, e.g. "well-site area".
    var areaName: String?
    var onChangeEventType: ((String) -> Void)?
    var onCapture: (() -> Void)?
    /// Called when the driver could not verify and saves with a written reason.
    var onSaveUnverified: ((String) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var eventTypeState: String
    @State private var showDetails = false
    @State private var reason = ""
    @State private var captureMessage: String?
    @State private var savedMessage: String?

    init(
        eventType: String? = nil,
        verified: Bool? = nil,
        withinArea: Bool? = nil,
        accuracy: String? = nil,
        capturedAt: String? = nil,
        coordinates: String? = nil,
        areaName: String? = nil,
        onChangeEventType: ((String) -> Void)? = nil,
        onCapture: (() -> Void)? = nil,
        onSaveUnverified: ((String) -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.eventType = eventType
        self.verified = verified
        self.withinArea = withinArea
        self.accuracy = accuracy
        self.capturedAt = capturedAt
        self.coordinates = coordinates
        self.areaName = areaName
        self.onChangeEventType = onChangeEventType
        self.onCapture = onCapture
        self.onSaveUnverified = onSaveUnverified
        self.theme = theme
        _eventTypeState = State(initialValue: eventType ?? "Job Arrival")
    }

    var body: some View {
        let t = theme ?? envTheme
        let withinArea = self.withinArea ?? false
        let areaName = self.areaName ?? "expected area"

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Capture Location")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text("This records where you are for this job. No map reading needed.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            Card(title: "Event", theme: t) {
                ChipPicker(
                    theme: t,
                    options: GPS_EVENT_TYPES,
                    selected: eventTypeState,
                    onSelect: { value in
                        eventTypeState = value
                        onChangeEventType?(value)
                    },
                    idPrefix: "gps-event"
                )
            }

            if verified == true {
                Card(title: "GPS Captured", tone: .highlight, testID: "gps-result", theme: t) {
                    RowBetween {
                        Text(withinArea ? "Within \(areaName)" : "Outside \(areaName)")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    } right: {
                        StatusBadge(
                            label: withinArea ? "Verified" : "Needs Review",
                            tone: withinArea ? .success : .warning,
                            testID: "gps-verify-state"
                        )
                    }
                    if let accuracy {
                        Text("Accuracy: \(accuracy)")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                    if let capturedAt {
                        Text("Captured \(capturedAt)")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                    }
                    if let coordinates {
                        FieldButton(
                            label: showDetails ? "Hide Details" : "Show Details",
                            onPress: { showDetails.toggle() },
                            variant: .secondary,
                            testID: "gps-show-details"
                        )
                        if showDetails {
                            Text(coordinates)
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.textMuted)
                                .accessibilityIdentifier("gps-coordinates")
                        }
                    }
                }
            } else if verified == false {
                Card(title: "Could not verify location", testID: "gps-unverified", theme: t) {
                    Text(
                        "We could not confirm your location for this event. Add a short reason and you can still save it."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    Field(
                        theme: t,
                        label: "Reason required",
                        value: reason,
                        onChangeText: { reason = $0 },
                        placeholder: "Why couldn\u{2019}t we verify?",
                        testID: "gps-reason-input"
                    )
                    FieldButton(
                        label: "Save Unverified Location",
                        onPress: {
                            savedMessage = "Save requested…"
                            onSaveUnverified?(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                        },
                        disabled: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || onSaveUnverified == nil,
                        testID: "gps-save-unverified"
                    )
                    FeedbackLine(
                        theme: t, message: savedMessage, tone: .info, testID: "gps-unverified-feedback")
                }
            } else {
                Card(title: "No location result", tone: .highlight, theme: t) {
                    Text("Capture a location to see a verified or needs-review result.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            FieldButton(
                label: "Capture GPS",
                onPress: {
                    captureMessage = "Capturing location…"
                    onCapture?()
                },
                disabled: onCapture == nil,
                testID: "gps-capture-btn"
            )
            if onCapture == nil {
                Text("GPS capture is unavailable from this screen.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: captureMessage, tone: .info, testID: "gps-capture-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("gps-capture")
    }
}

// MARK: - 60. Print Ticket

struct PrintDocument: Equatable {
    var key: String
    var label: String
}

let DEFAULT_PRINT_DOCS: [PrintDocument] = []

struct PrintTicketScreen: View {
    var printerName: String?
    var printerConnected: Bool?
    var documents: [PrintDocument]?
    var selectedDocumentKey: String?
    var onSelectDocument: ((String) -> Void)?
    var onPrintTicket: (() -> Void)?
    var onReprintLast: (() -> Void)?
    var onPrinterHelp: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var selected: String
    @State private var printMessage: String?

    init(
        printerName: String? = nil,
        printerConnected: Bool? = nil,
        documents: [PrintDocument]? = nil,
        selectedDocumentKey: String? = nil,
        onSelectDocument: ((String) -> Void)? = nil,
        onPrintTicket: (() -> Void)? = nil,
        onReprintLast: (() -> Void)? = nil,
        onPrinterHelp: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.printerName = printerName
        self.printerConnected = printerConnected
        self.documents = documents
        self.selectedDocumentKey = selectedDocumentKey
        self.onSelectDocument = onSelectDocument
        self.onPrintTicket = onPrintTicket
        self.onReprintLast = onReprintLast
        self.onPrinterHelp = onPrinterHelp
        self.theme = theme
        let docs = documents ?? DEFAULT_PRINT_DOCS
        _selected = State(initialValue: selectedDocumentKey ?? docs.first?.key ?? "")
    }

    var body: some View {
        let t = theme ?? envTheme
        let documents = self.documents ?? DEFAULT_PRINT_DOCS
        let connected = printerConnected ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Print")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Printer", theme: t) {
                RowBetween {
                    Text(printerName ?? "Printer not provided")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } right: {
                    StatusBadge(
                        label: connected ? "Connected" : "Offline Mode", tone: connected ? .success : .warning,
                        testID: "printer-state")
                }
            }

            Card(title: "Documents", theme: t) {
                if documents.isEmpty {
                    Text("No printable documents were provided for this job.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                } else {
                    ForEach(documents, id: \.key) { doc in
                        let isSelected = doc.key == selected
                        Button {
                            selected = doc.key
                            onSelectDocument?(doc.key)
                        } label: {
                            HStack(alignment: .center, spacing: spacing.sm) {
                                Text(doc.label)
                                    .font(.system(size: typeScale.body, weight: .semibold))
                                    .foregroundStyle(t.text)
                                Spacer(minLength: 0)
                                if isSelected {
                                    StatusBadge(label: "Selected", tone: .info)
                                }
                            }
                            .padding(.horizontal, spacing.md)
                            .padding(.vertical, spacing.md)
                            .frame(minHeight: 48)
                            .background(isSelected ? t.cardMuted : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: sizing.radius)
                                    .stroke(isSelected ? t.primary : t.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectDocument == nil)
                        .accessibilityLabel(doc.label)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("print-doc-\(doc.key)")
                    }
                }
            }

            if let onPrintTicket {
                FieldButton(
                    label: "Print Ticket",
                    onPress: {
                        printMessage = "Sending to printer…"
                        onPrintTicket()
                    },
                    disabled: !connected || selected.isEmpty,
                    testID: "print-ticket-btn"
                )
            }
            if let onReprintLast {
                FieldButton(
                    label: "Reprint Last",
                    onPress: {
                        printMessage = "Sending last document…"
                        onReprintLast()
                    },
                    variant: .secondary,
                    testID: "print-reprint"
                )
            }
            if let onPrinterHelp {
                FieldButton(
                    label: "Printer Help",
                    onPress: onPrinterHelp,
                    variant: .secondary,
                    testID: "print-help"
                )
            }
            if onPrintTicket == nil, onReprintLast == nil, onPrinterHelp == nil {
                Text("Printing actions are unavailable from this screen.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
            FeedbackLine(theme: t, message: printMessage, tone: .info, testID: "print-feedback")
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("print-ticket")
    }
}

// MARK: - 61. Job Complete Review

struct JobCompleteReviewScreen: View {
    var jobLabel: String?
    var completionConfirmed: Bool?
    var jhaStatus: EvidenceStatus?
    var ticketStatus: EvidenceStatus?
    var evidenceCount: Int?
    var pendingSync: Int?
    /// When false, the day is done and End Day is shown instead of Start Next Job.
    var hasMoreJobs: Bool?
    var onStartNextJob: (() -> Void)?
    var onEndDay: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let completionConfirmed = self.completionConfirmed ?? (jhaStatus != nil || ticketStatus != nil)
        let jhaStatus = self.jhaStatus ?? .notStarted
        let ticketStatus = self.ticketStatus ?? .notStarted
        let evidenceCount = self.evidenceCount ?? 0
        let pendingSync = self.pendingSync ?? 0
        let hasMoreJobs = self.hasMoreJobs ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text(completionConfirmed ? "Job Complete" : "Job Status")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text(jobLabel ?? "Job details not provided")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            if completionConfirmed {
                Card(title: "Summary", tone: .highlight, theme: t) {
                    RowBetween {
                        Text("JHA/JSA")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    } right: {
                        StatusPill(status: jhaStatus, testID: "complete-jha-status")
                    }
                    RowBetween {
                        Text("Field Ticket")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    } right: {
                        StatusPill(status: ticketStatus, testID: "complete-ticket-status")
                    }
                    RowBetween {
                        Text("Evidence")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    } right: {
                        Text("\(evidenceCount) item\(evidenceCount == 1 ? "" : "s")")
                            .font(.system(size: typeScale.label, weight: .bold))
                            .foregroundStyle(t.text)
                    }
                    RowBetween {
                        Text("Sync")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    } right: {
                        StatusBadge(
                            label: pendingSync == 0 ? "Synced" : "Pending Sync",
                            tone: pendingSync == 0 ? .success : .info,
                            testID: "complete-sync-status")
                    }
                    if pendingSync > 0 {
                        Text(
                            "\(pendingSync) item\(pendingSync == 1 ? "" : "s") waiting to sync. Your work is safe on this phone."
                        )
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                    }
                }
            } else {
                Card(title: "Completion not confirmed", tone: .highlight, theme: t) {
                    Text("A completed job summary was not provided.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            if completionConfirmed {
                if hasMoreJobs, let onStartNextJob {
                    FieldButton(label: "Start Next Job", onPress: onStartNextJob, testID: "complete-start-next")
                } else if !hasMoreJobs, let onEndDay {
                    FieldButton(label: "End Day", onPress: onEndDay, testID: "complete-end-day")
                }
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("job-complete-review")
    }
}
