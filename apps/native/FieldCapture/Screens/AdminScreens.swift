//
//  AdminScreens.swift
//  Ported from apps/mobile/src/screens/AdminScreens.tsx
//
//  Admin / Protected & non-driver pages (GUI Master §16 / screens 84-92).
//
//  These are the ONLY screens permitted to surface technical detail, and only AFTER the Admin lock
//  (screen 84) is unlocked. Diagnostics are for supervisors and support, never the everyday driver.
//
//  Even here we keep driver-facing hygiene: we never render UUIDs, hashes, raw payloads, queue/ack
//  internals, JSON, or storage-engine internals as free-form text in driver flows. The few "technical"
//  fields that this section is allowed to show (env name, hub URL, app version, build, storage engine,
//  device id, last sync — screen 88) are rendered as plain labelled rows, supplied by the host as
//  already-formatted display strings. This file is purely presentational: it uses only the design
//  kit + SwiftUI primitives and drives everything from local prop-style properties + closures.
//
//  Screens:
//    84 AdminModeLockScreen            85 AdminDashboardScreen        86 PrinterDiagnosticsScreen
//    87 SyncDiagnosticsScreen          88 EnvironmentDetailsScreen    89 LogsExportScreen
//    90 SupervisorDefectReviewScreen   91 MechanicDefectResolutionScreen
//    92 SupervisorOverrideScreen
//

import SwiftUI

/* ------------------------------------------------------------------------------------------------ *
 * Shared status vocabulary (GUI Master §20). Only these labels may appear as statuses.
 * ------------------------------------------------------------------------------------------------ */

enum StatusLabel: String {
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
    case failed = "Failed"
    case offlineMode = "Offline Mode"
    case punchedIn = "Punched In"
    case punchedOut = "Punched Out"
}

private let statusToneMap: [StatusLabel: Tone] = [
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
    .failed: .danger,
    .offlineMode: .warning,
    .punchedIn: .success,
    .punchedOut: .neutral,
]

private func statusTone(_ label: StatusLabel) -> Tone {
    statusToneMap[label] ?? .neutral
}

/* ------------------------------------------------------------------------------------------------ *
 * Small local building blocks (presentational only).
 * ------------------------------------------------------------------------------------------------ */

/// A labelled key/value row for diagnostics + environment detail. Value is a display string.
private struct DetailRow: View {
    var label: String
    var value: String
    var theme: Theme

    var body: some View {
        HStack(alignment: .top, spacing: spacing.md) {
            Text(label)
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.textMuted)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: typeScale.label, weight: .bold))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

/// Section header inside a screen body.
private struct ScreenTitle: View {
    var title: String
    var subtitle: String?
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(title)
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(theme.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(theme.textMuted)
            }
        }
    }
}

/// A simple inline confirm row used for destructive actions (no native alert dep).
private struct ConfirmInline: View {
    var prompt: String
    var confirmLabel: String
    var onConfirm: () -> Void
    var onCancel: () -> Void
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.sm) {
            Text(prompt)
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
            FieldButton(label: confirmLabel, onPress: onConfirm, variant: .destructive, theme: theme)
            FieldButton(label: "Cancel", onPress: onCancel, variant: .secondary, theme: theme)
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.highlight)
        .overlay(
            RoundedRectangle(cornerRadius: sizing.cardRadius)
                .stroke(theme.danger, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.cardRadius))
    }
}

/// A bordered placeholder frame (signature pad / capture area). Real capture is wired elsewhere.
private struct PlaceholderFrame: View {
    var caption: String
    var captured: Bool
    var theme: Theme

    var body: some View {
        Text(captured ? "Signature captured" : caption)
            .font(.system(size: typeScale.label, weight: .semibold))
            .foregroundStyle(captured ? theme.success : theme.textMuted)
            .padding(spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(theme.cardMuted)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.radius)
                    .stroke(captured ? theme.success : theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption)
            .accessibilityAddTraits(.isImage)
    }
}

/// A single labelled action/option: a stable key + display label (+ optional destructive flag),
/// shared by the printer/sync action lists and the mechanic/override radio-style option lists.
private struct ActionSpec<Key: Hashable> {
    var key: Key
    var label: String
    var destructive: Bool = false
}

/// A bordered, tappable "radio" row used by the mechanic resolution and supervisor override
/// pickers. `showSelectedBadge` mirrors the one extra "In Progress" badge the mechanic screen
/// shows on the selected row (the override screen does not show it).
private struct OptionRow: View {
    var label: String
    var isSelected: Bool
    var onPress: () -> Void
    var testID: String
    var theme: Theme
    var showSelectedBadge: Bool = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: spacing.sm) {
                Text(label)
                    .font(.system(size: typeScale.body, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showSelectedBadge && isSelected {
                    StatusBadge(label: StatusLabel.inProgress.rawValue, tone: statusTone(.inProgress))
                }
            }
            .padding(.horizontal, spacing.md)
            .padding(.vertical, spacing.md)
            .frame(minHeight: sizing.minTouchTarget)
            .background(isSelected ? theme.highlight : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.radius)
                    .stroke(isSelected ? theme.primary : theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
        }
        .buttonStyle(OptionRowPressStyle())
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(testID)
    }
}

/// Pressed-state opacity (0.7), matching the RN `Pressable`'s `pressed` style.
private struct OptionRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/* ==================================================================================================== *
 * 84. Admin Mode Lock
 * ==================================================================================================== */

struct AdminModeLockScreen: View {
    /// Set when a previous unlock attempt was wrong, so we can show driver-safe guidance.
    var errorMessage: String?
    var pending: Bool = false
    var onUnlock: (String) -> Void
    var onCancel: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var pin = ""

    var body: some View {
        let t = theme ?? envTheme
        let canSubmit = pin.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 && !pending

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(title: "Admin Mode", theme: t)

            Card(tone: .highlight, theme: t) {
                Text("Diagnostics are for supervisors and support only.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            Card(title: "Admin PIN", theme: t) {
                SecureField("Enter Admin PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .padding(.vertical, spacing.sm)
                    .frame(minHeight: sizing.minTouchTarget)
                    .background(t.card)
                    .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .accessibilityLabel("Admin PIN")
                    .accessibilityIdentifier("admin-pin")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: typeScale.label, weight: .semibold))
                        .foregroundStyle(t.danger)
                }

                FieldButton(
                    label: pending ? "Checking…" : "Unlock Admin Mode",
                    onPress: { onUnlock(pin.trimmingCharacters(in: .whitespacesAndNewlines)) },
                    disabled: !canSubmit,
                    testID: "admin-unlock",
                    theme: t
                )
                FieldButton(
                    label: "Cancel",
                    onPress: onCancel,
                    variant: .secondary,
                    testID: "admin-cancel",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 85. Admin Dashboard
 * ==================================================================================================== */

enum AdminSectionKey: String {
    case environment
    case device
    case sync
    case printer
    case storage
    case logs
    case role
}

struct AdminSectionSummary {
    var key: AdminSectionKey
    /// Short summary line for the section (a display string supplied by the host).
    var detail: String
    /// Optional status badge for the section.
    var status: StatusLabel?
}

private let adminSectionMeta: [AdminSectionKey: (title: String, nav: String)] = [
    .environment: (title: "Environment", nav: "Open environment details"),
    .device: (title: "Device", nav: "Open device info"),
    .sync: (title: "Sync Queue", nav: "Open sync diagnostics"),
    .printer: (title: "Printer", nav: "Open printer diagnostics"),
    .storage: (title: "Local Storage", nav: "Open local storage"),
    .logs: (title: "Logs", nav: "Open logs"),
    .role: (title: "User Role", nav: "View role"),
]

private let adminOrder: [AdminSectionKey] = [
    .environment,
    .device,
    .sync,
    .printer,
    .storage,
    .logs,
    .role,
]

private let defaultAdminSections: [AdminSectionSummary] = [
    AdminSectionSummary(key: .environment, detail: "Production Hub · app up to date", status: .synced),
    AdminSectionSummary(key: .device, detail: "Truck 7 phone · battery healthy", status: .inProgress),
    AdminSectionSummary(key: .sync, detail: "No items waiting to sync", status: .synced),
    AdminSectionSummary(key: .printer, detail: "Receipt printer connected", status: .complete),
    AdminSectionSummary(key: .storage, detail: "Plenty of space for offline work", status: .savedOnPhone),
    AdminSectionSummary(key: .logs, detail: "Diagnostic logs available to export", status: .notStarted),
    AdminSectionSummary(key: .role, detail: "Driver · Alex Ramirez", status: .punchedIn),
]

struct AdminDashboardScreen: View {
    var sections: [AdminSectionSummary] = defaultAdminSections
    var onOpenSection: (AdminSectionKey) -> Void
    var onLockAdmin: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let byKey = Dictionary(sections.map { ($0.key, $0) }, uniquingKeysWith: { _, later in later })

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Admin Dashboard",
                subtitle: "Technical details are visible because Admin Mode is unlocked.",
                theme: t
            )

            ForEach(adminOrder, id: \.self) { key in
                let section = byKey[key]
                let detail = section?.detail ?? "—"
                let status = section?.status

                if let meta = adminSectionMeta[key] {
                    Card(title: meta.title, testID: "admin-section-\(key.rawValue)", theme: t) {
                        if let status {
                            StatusBadge(label: status.rawValue, tone: statusTone(status))
                        }
                        Text(detail)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                        FieldButton(
                            label: meta.nav,
                            onPress: { onOpenSection(key) },
                            variant: .secondary,
                            testID: "admin-open-\(key.rawValue)",
                            theme: t
                        )
                    }
                }
            }

            FieldButton(
                label: "Lock Admin Mode",
                onPress: onLockAdmin,
                variant: .secondary,
                testID: "admin-lock",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 86. Printer Diagnostics
 * ==================================================================================================== */

enum PrinterAction: String {
    case discover
    case connect
    case reconnect
    case disconnect
    case testReceipt = "test-receipt"
    case status
    case runQueue = "run-queue"
    case purge
}

private let printerActions: [ActionSpec<PrinterAction>] = [
    ActionSpec(key: .discover, label: "Discover Printer"),
    ActionSpec(key: .connect, label: "Connect"),
    ActionSpec(key: .reconnect, label: "Reconnect"),
    ActionSpec(key: .disconnect, label: "Disconnect"),
    ActionSpec(key: .testReceipt, label: "Test Receipt"),
    ActionSpec(key: .status, label: "Status"),
    ActionSpec(key: .runQueue, label: "Run Queue"),
    ActionSpec(key: .purge, label: "Purge Synced Print Jobs", destructive: true),
]

/// Plain-English feedback line for a tapped printer action (visible response, no real effect yet).
private let printerFeedback: [PrinterAction: String] = [
    .discover: "Looking for nearby printers…",
    .connect: "Connecting to printer…",
    .reconnect: "Reconnecting to printer…",
    .disconnect: "Disconnected from printer",
    .testReceipt: "Test receipt sent to printer",
    .status: "Checked printer status",
    .runQueue: "Running print queue…",
    .purge: "Purged synced print jobs from this phone",
]

struct PrinterDiagnosticsScreen: View {
    /// Connection status (driver-safe label).
    var connectionStatus: StatusLabel = .notStarted
    /// Friendly printer name, e.g. "Receipt printer · Truck 7".
    var printerName: String = "Receipt printer · Truck 7"
    /// Plain-English last-result line for the most recent action.
    var lastResult: String?
    /// Count of receipts waiting to print.
    var pendingPrintJobs: Int = 0
    var busy: Bool = false
    var onAction: ((PrinterAction) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirmPurge = false
    @State private var feedback: String?

    private func runAction(_ action: PrinterAction) {
        feedback = printerFeedback[action]
        onAction?(action)
    }

    var body: some View {
        let t = theme ?? envTheme
        let pending = pendingPrintJobs

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(title: "Printer Diagnostics", theme: t)

            Card(title: printerName, theme: t) {
                StatusBadge(
                    label: connectionStatus.rawValue, tone: statusTone(connectionStatus), testID: "printer-status")
                Text(
                    pending == 0
                        ? "No receipts waiting to print."
                        : "\(pending) receipt\(pending == 1 ? "" : "s") waiting to print."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                if let lastResult {
                    Text(lastResult)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("printer-feedback")
                }
            }

            Card(title: "Actions", theme: t) {
                ForEach(printerActions.filter { !$0.destructive }, id: \.key) { a in
                    FieldButton(
                        label: a.label,
                        onPress: { runAction(a.key) },
                        variant: .secondary,
                        disabled: busy,
                        testID: "printer-\(a.key.rawValue)",
                        theme: t
                    )
                }
            }

            Card(title: "Maintenance", theme: t) {
                if confirmPurge {
                    ConfirmInline(
                        prompt: "Purge synced print jobs from this phone? Already-printed receipts stay in Ops Hub.",
                        confirmLabel: "Purge Synced Print Jobs",
                        onConfirm: {
                            confirmPurge = false
                            runAction(.purge)
                        },
                        onCancel: { confirmPurge = false },
                        theme: t
                    )
                } else {
                    FieldButton(
                        label: "Purge Synced Print Jobs",
                        onPress: { confirmPurge = true },
                        variant: .destructive,
                        disabled: busy,
                        testID: "printer-purge",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 87. Sync Diagnostics
 * ==================================================================================================== */

enum SyncAction: String {
    case viewQueue = "view-queue"
    case retry
    case exportSummary = "export-summary"
    case syncAck = "sync-ack"
    case purgeSynced = "purge-synced"
    case viewFailed = "view-failed"
}

private let syncActions: [ActionSpec<SyncAction>] = [
    ActionSpec(key: .viewQueue, label: "View Queue"),
    ActionSpec(key: .retry, label: "Retry Queue"),
    ActionSpec(key: .exportSummary, label: "Export Queue Summary"),
    ActionSpec(key: .syncAck, label: "Sync Ack"),
    ActionSpec(key: .viewFailed, label: "View Failed Payload Summary"),
    ActionSpec(key: .purgeSynced, label: "Purge Synced", destructive: true),
]

/// Plain-English feedback line for a tapped sync action (visible response, no real effect yet).
private let syncFeedback: [SyncAction: String] = [
    .viewQueue: "Opened the sync queue",
    .retry: "Retrying queued items…",
    .exportSummary: "Queue summary exported",
    .syncAck: "Sent acknowledgements…",
    .purgeSynced: "Purged synced items from this phone",
    .viewFailed: "Opened the failed payload summary",
]

struct SyncDiagnosticsScreen: View {
    /// Counts shown as plain numbers — never raw payloads.
    var pending: Int = 0
    var failed: Int = 0
    var synced: Int = 0
    var status: StatusLabel?
    var lastResult: String?
    var busy: Bool = false
    var onAction: ((SyncAction) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirmPurge = false
    @State private var feedback: String?

    private func runAction(_ action: SyncAction) {
        feedback = syncFeedback[action]
        onAction?(action)
    }

    var body: some View {
        let t = theme ?? envTheme
        let resolvedStatus = status ?? (failed > 0 ? .failed : (pending > 0 ? .pendingSync : .synced))

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Sync Diagnostics",
                subtitle: "Summaries only — full sensitive payloads stay hidden unless support needs them.",
                theme: t
            )

            Card(title: "Queue", theme: t) {
                StatusBadge(label: resolvedStatus.rawValue, tone: statusTone(resolvedStatus), testID: "sync-status")
                DetailRow(label: "Waiting to sync", value: "\(pending)", theme: t)
                DetailRow(label: "Failed", value: "\(failed)", theme: t)
                DetailRow(label: "Synced", value: "\(synced)", theme: t)
                if let lastResult {
                    Text(lastResult)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("sync-feedback")
                }
            }

            Card(title: "Actions", theme: t) {
                ForEach(syncActions.filter { !$0.destructive }, id: \.key) { a in
                    FieldButton(
                        label: a.label,
                        onPress: { runAction(a.key) },
                        variant: .secondary,
                        disabled: busy,
                        testID: "sync-\(a.key.rawValue)",
                        theme: t
                    )
                }
            }

            Card(title: "Maintenance", theme: t) {
                if confirmPurge {
                    ConfirmInline(
                        prompt: "Purge synced items from this phone? Synced work is already saved in Ops Hub.",
                        confirmLabel: "Purge Synced",
                        onConfirm: {
                            confirmPurge = false
                            runAction(.purgeSynced)
                        },
                        onCancel: { confirmPurge = false },
                        theme: t
                    )
                } else {
                    FieldButton(
                        label: "Purge Synced",
                        onPress: { confirmPurge = true },
                        variant: .destructive,
                        disabled: busy,
                        testID: "sync-purge",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 88. Environment Details
 * ==================================================================================================== */

/// All fields are pre-formatted display strings supplied by the host (never raw/unsafe values).
struct EnvironmentInfo {
    var hubEnvironment: String
    var hubUrl: String
    var appVersion: String
    var build: String
    var storageEngine: String
    var deviceId: String
    var lastSync: String
}

private let defaultEnvironment = EnvironmentInfo(
    hubEnvironment: "Production",
    hubUrl: "hub.example.com",
    appVersion: "1.0.0",
    build: "100",
    storageEngine: "On-device secure store",
    deviceId: "Truck 7 phone",
    lastSync: "Today, 9:42 AM"
)

struct EnvironmentDetailsScreen: View {
    var environment: EnvironmentInfo = defaultEnvironment
    var onCopy: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var copied = false

    var body: some View {
        let t = theme ?? envTheme
        let env = environment

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Environment Details",
                subtitle: "Visible only in Admin Mode, for support.",
                theme: t
            )

            Card(title: "Connection", theme: t) {
                DetailRow(label: "Hub Environment", value: env.hubEnvironment, theme: t)
                DetailRow(label: "Hub URL", value: env.hubUrl, theme: t)
                DetailRow(label: "Last Sync", value: env.lastSync, theme: t)
            }
            Card(title: "App", theme: t) {
                DetailRow(label: "App Version", value: env.appVersion, theme: t)
                DetailRow(label: "Build", value: env.build, theme: t)
                DetailRow(label: "Storage Engine", value: env.storageEngine, theme: t)
            }
            Card(title: "Device", theme: t) {
                DetailRow(label: "Device ID", value: env.deviceId, theme: t)
            }
            FieldButton(
                label: "Copy for Support",
                onPress: {
                    copied = true
                    onCopy?()
                },
                variant: .secondary,
                testID: "env-copy",
                theme: t
            )
            if copied {
                Text("Copied details for support")
                    .font(.system(size: typeScale.label, weight: .bold))
                    .foregroundStyle(t.success)
                    .accessibilityIdentifier("env-copy-feedback")
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 89. Logs / Export
 * ==================================================================================================== */

enum LogAction: String {
    case export
    case sendSupport = "send-support"
    case clear
}

/// Plain-English feedback line for a tapped log action (visible response, no real effect yet).
private let logFeedback: [LogAction: String] = [
    .export: "Logs exported",
    .sendSupport: "Sent to support",
    .clear: "Local logs cleared from this phone",
]

struct LogsExportScreen: View {
    /// Count of log entries held on this phone (a plain number, no contents shown).
    var entryCount: Int = 0
    var lastResult: String?
    var busy: Bool = false
    var onAction: ((LogAction) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirmClear = false
    @State private var feedback: String?

    private func runAction(_ action: LogAction) {
        feedback = logFeedback[action]
        onAction?(action)
    }

    var body: some View {
        let t = theme ?? envTheme
        let count = entryCount

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(title: "Logs / Export", theme: t)

            Card(title: "Diagnostic logs", theme: t) {
                Text(
                    count == 0
                        ? "No diagnostic logs are stored on this phone."
                        : "\(count) diagnostic \(count == 1 ? "entry is" : "entries are") stored on this phone."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                if let lastResult {
                    Text(lastResult)
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                if let feedback {
                    Text(feedback)
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("logs-feedback")
                }
            }

            Card(title: "Actions", theme: t) {
                FieldButton(
                    label: "Export Logs",
                    onPress: { runAction(.export) },
                    variant: .secondary,
                    disabled: busy,
                    testID: "logs-export",
                    theme: t
                )
                FieldButton(
                    label: "Send to Support",
                    onPress: { runAction(.sendSupport) },
                    variant: .secondary,
                    disabled: busy,
                    testID: "logs-send",
                    theme: t
                )
            }

            Card(title: "Maintenance", theme: t) {
                if confirmClear {
                    ConfirmInline(
                        prompt:
                            "Clear local logs from this phone? This cannot be undone. Export or send to support first if you may need them.",
                        confirmLabel: "Clear Local Logs",
                        onConfirm: {
                            confirmClear = false
                            runAction(.clear)
                        },
                        onCancel: { confirmClear = false },
                        theme: t
                    )
                } else {
                    FieldButton(
                        label: "Clear Local Logs",
                        onPress: { confirmClear = true },
                        variant: .destructive,
                        disabled: busy,
                        testID: "logs-clear",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 90. Supervisor Defect Review
 * ==================================================================================================== */

enum DefectReviewDecision: String {
    case approve
    case outOfService = "out-of-service"
    case requestMechanic = "request-mechanic"
}

struct DefectReviewInfo {
    var truck: String
    var trailer: String
    var driver: String
    /// Inspection kind, e.g. "Pre-Trip" / "Post-Trip".
    var inspection: String
    var defectCount: Int
    var photoCount: Int
    var remarks: String
    var status: StatusLabel?
}

private let defaultDefectReview = DefectReviewInfo(
    truck: "Truck 7",
    trailer: "Vacuum Trailer 19",
    driver: "Alex Ramirez",
    inspection: "Pre-Trip",
    defectCount: 2,
    photoCount: 1,
    remarks: "Left rear marker light intermittent. Slack adjuster within limits but noted.",
    status: .needsReview
)

struct SupervisorDefectReviewScreen: View {
    var review: DefectReviewInfo = defaultDefectReview
    var busy: Bool = false
    var onDecision: (DefectReviewDecision) -> Void
    var onViewPhotos: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var confirmOos = false
    @State private var photosOpened = false

    var body: some View {
        let t = theme ?? envTheme
        let r = review
        let status = r.status ?? .needsReview

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Defect Review",
                subtitle: "Review driver-reported DVIR defects.",
                theme: t
            )

            Card(title: "\(r.truck) · \(r.trailer)", theme: t) {
                StatusBadge(label: status.rawValue, tone: statusTone(status), testID: "defect-status")
                DetailRow(label: "Driver", value: r.driver, theme: t)
                DetailRow(label: "Inspection", value: r.inspection, theme: t)
                DetailRow(label: "Defects", value: "\(r.defectCount)", theme: t)
                DetailRow(label: "Photos", value: "\(r.photoCount)", theme: t)
            }

            Card(title: "Remarks", theme: t) {
                Text(r.remarks)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                FieldButton(
                    label: "View Photos (\(r.photoCount))",
                    onPress: {
                        photosOpened = true
                        onViewPhotos?()
                    },
                    variant: .secondary,
                    disabled: r.photoCount == 0,
                    testID: "defect-view-photos",
                    theme: t
                )
                if photosOpened {
                    Text("Opened \(r.photoCount) photo\(r.photoCount == 1 ? "" : "s")")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("defect-photos-feedback")
                }
            }

            Card(title: "Decision", theme: t) {
                FieldButton(
                    label: "Approve Safe to Operate",
                    onPress: { onDecision(.approve) },
                    disabled: busy,
                    testID: "defect-approve",
                    theme: t
                )
                FieldButton(
                    label: "Request Mechanic Review",
                    onPress: { onDecision(.requestMechanic) },
                    variant: .secondary,
                    disabled: busy,
                    testID: "defect-request-mechanic",
                    theme: t
                )
                if confirmOos {
                    ConfirmInline(
                        prompt:
                            "Mark \(r.truck) out of service? The driver will be blocked from operating it until cleared.",
                        confirmLabel: "Mark Out of Service",
                        onConfirm: {
                            confirmOos = false
                            onDecision(.outOfService)
                        },
                        onCancel: { confirmOos = false },
                        theme: t
                    )
                } else {
                    FieldButton(
                        label: "Mark Out of Service",
                        onPress: { confirmOos = true },
                        variant: .destructive,
                        disabled: busy,
                        testID: "defect-out-of-service",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 91. Mechanic Defect Resolution
 * ==================================================================================================== */

enum MechanicResolution: String {
    case corrected
    case noCorrectionNeeded = "no-correction-needed"
    case outOfService = "out-of-service"
}

private let mechanicResolutions: [ActionSpec<MechanicResolution>] = [
    ActionSpec(key: .corrected, label: "Defects Corrected"),
    ActionSpec(key: .noCorrectionNeeded, label: "Defects Need Not Be Corrected for Safe Operation"),
    ActionSpec(key: .outOfService, label: "Out of Service"),
]

struct MechanicDefectResolutionScreen: View {
    var truck: String
    var trailer: String
    var defectCount: Int
    /// Already-captured mechanic signature flag (real capture wired elsewhere).
    var signatureCaptured: Bool
    var busy: Bool
    var onSelect: (MechanicResolution) -> Void
    var onCaptureSignature: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var selected: MechanicResolution?
    @State private var captured: Bool

    init(
        truck: String = "Truck 7",
        trailer: String = "Vacuum Trailer 19",
        defectCount: Int = 2,
        signatureCaptured: Bool = false,
        busy: Bool = false,
        onSelect: @escaping (MechanicResolution) -> Void,
        onCaptureSignature: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.truck = truck
        self.trailer = trailer
        self.defectCount = defectCount
        self.signatureCaptured = signatureCaptured
        self.busy = busy
        self.onSelect = onSelect
        self.onCaptureSignature = onCaptureSignature
        self.theme = theme
        _captured = State(initialValue: signatureCaptured)
    }

    var body: some View {
        let t = theme ?? envTheme
        let canSubmit = selected != nil && captured && !busy

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Defect Resolution",
                subtitle: "Mechanic resolution and correction language.",
                theme: t
            )

            Card(title: "\(truck) · \(trailer)", theme: t) {
                DetailRow(label: "Defects", value: "\(defectCount)", theme: t)
            }

            Card(title: "Resolution", theme: t) {
                ForEach(mechanicResolutions, id: \.key) { r in
                    OptionRow(
                        label: r.label,
                        isSelected: r.key == selected,
                        onPress: { selected = r.key },
                        testID: "mechanic-\(r.key.rawValue)",
                        theme: t,
                        showSelectedBadge: true
                    )
                }
            }

            Card(title: "Mechanic signature", theme: t) {
                PlaceholderFrame(caption: "Sign to certify this resolution", captured: captured, theme: t)
                FieldButton(
                    label: captured ? "Re-sign" : "Sign",
                    onPress: {
                        captured = true
                        onCaptureSignature?()
                    },
                    variant: .secondary,
                    testID: "mechanic-sign",
                    theme: t
                )
                if captured {
                    Text("Signature captured")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("mechanic-sign-feedback")
                }
            }

            FieldButton(
                label: "Submit Resolution",
                onPress: {
                    if let selected { onSelect(selected) }
                },
                disabled: !canSubmit,
                testID: "mechanic-submit",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* ==================================================================================================== *
 * 92. Supervisor Override
 * ==================================================================================================== */

enum OverrideKind: String {
    case allowJobAfterReview = "allow-job-after-review"
    case allowPunchOutPending = "allow-punch-out-pending"
    case unlockTicket = "unlock-ticket"
    case returnTicket = "return-ticket"
}

private let overrideKinds: [ActionSpec<OverrideKind>] = [
    ActionSpec(key: .allowJobAfterReview, label: "Allow job work after defect review"),
    ActionSpec(key: .allowPunchOutPending, label: "Allow punch out with pending issue"),
    ActionSpec(key: .unlockTicket, label: "Unlock ticket for correction"),
    ActionSpec(key: .returnTicket, label: "Return ticket to driver"),
]

struct OverrideAuditEntry {
    /// Plain-English audit line, e.g. "Unlock ticket — J. Doe — Today 9:42 AM".
    var summary: String
}

/// Payload for `onApply` — the chosen override kind + the typed-in reason (same "single payload
/// struct" convention as other screens' object-shaped callbacks, e.g. PostTripSignaturePayload).
struct SupervisorOverrideApplyInput {
    var kind: OverrideKind
    var reason: String
}

struct SupervisorOverrideScreen: View {
    /// Pre-formatted timestamp the override will be stamped with.
    var timestamp: String
    var signatureCaptured: Bool
    /// Recent audit-log lines (display strings only).
    var auditLog: [OverrideAuditEntry]
    var busy: Bool
    var onApply: (SupervisorOverrideApplyInput) -> Void
    var onCaptureSignature: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var kind: OverrideKind?
    @State private var reason = ""
    @State private var confirm = false
    @State private var captured: Bool

    init(
        timestamp: String = "Now",
        signatureCaptured: Bool = false,
        auditLog: [OverrideAuditEntry] = [],
        busy: Bool = false,
        onApply: @escaping (SupervisorOverrideApplyInput) -> Void,
        onCaptureSignature: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.timestamp = timestamp
        self.signatureCaptured = signatureCaptured
        self.auditLog = auditLog
        self.busy = busy
        self.onApply = onApply
        self.onCaptureSignature = onCaptureSignature
        self.theme = theme
        _captured = State(initialValue: signatureCaptured)
    }

    var body: some View {
        let t = theme ?? envTheme
        let canApply =
            kind != nil
            && reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
            && captured
            && !busy

        VStack(alignment: .leading, spacing: spacing.md) {
            ScreenTitle(
                title: "Supervisor Override",
                subtitle: "Controlled override for blocked states. Every override is signed and logged.",
                theme: t
            )

            Card(title: "Override", theme: t) {
                ForEach(overrideKinds, id: \.key) { o in
                    OptionRow(
                        label: o.label,
                        isSelected: o.key == kind,
                        onPress: { kind = o.key },
                        testID: "override-\(o.key.rawValue)",
                        theme: t
                    )
                }
            }

            Card(title: "Reason", theme: t) {
                TextField("Why is this override needed?", text: $reason, axis: .vertical)
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .padding(.vertical, spacing.sm)
                    .frame(minHeight: 96, alignment: .top)
                    .background(t.card)
                    .overlay(RoundedRectangle(cornerRadius: sizing.radius).stroke(t.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                    .accessibilityLabel("Override reason")
                    .accessibilityIdentifier("override-reason")
            }

            Card(title: "Supervisor signature", theme: t) {
                PlaceholderFrame(caption: "Sign to authorize this override", captured: captured, theme: t)
                FieldButton(
                    label: captured ? "Re-sign" : "Sign",
                    onPress: {
                        captured = true
                        onCaptureSignature?()
                    },
                    variant: .secondary,
                    testID: "override-sign",
                    theme: t
                )
                if captured {
                    Text("Signature captured")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("override-sign-feedback")
                }
                DetailRow(label: "Timestamp", value: timestamp, theme: t)
            }

            Card(title: "Audit log", theme: t) {
                if auditLog.isEmpty {
                    Text("No overrides recorded for this item yet.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                } else {
                    ForEach(Array(auditLog.enumerated()), id: \.offset) { i, entry in
                        Text(entry.summary)
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(t.textMuted)
                            .accessibilityIdentifier("override-audit-\(i)")
                    }
                }
            }

            if confirm {
                ConfirmInline(
                    prompt: "Apply this override? It will be signed, timestamped, and recorded in the audit log.",
                    confirmLabel: "Apply Override",
                    onConfirm: {
                        confirm = false
                        if let kind {
                            onApply(
                                SupervisorOverrideApplyInput(
                                    kind: kind,
                                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
                                ))
                        }
                    },
                    onCancel: { confirm = false },
                    theme: t
                )
            } else {
                FieldButton(
                    label: "Apply Override",
                    onPress: { confirm = true },
                    disabled: !canApply,
                    testID: "override-apply",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}
