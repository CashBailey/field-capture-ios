//
//  SyncScreens.swift
//  Ported from apps/mobile/src/screens/SyncScreens.tsx
//
//  Sync pages (GUI Master §14 / screens 70-74) — the driver's reassurance surface: "is my work
//  safe?" Every screen here is honest and calm — work is always saved on the phone first, then
//  synced to Ops Hub when a connection is available. Driver-facing only (GUI Master §20): we
//  never render payloads, queues, UUIDs, server versions, hub URLs, or raw errors. Failed items
//  get a plain-English reason, a Retry, and a path to support — the technical detail stays
//  admin-only.
//
//  Screens:
//    70. SyncHomeScreen         — overall state + Pending/Failed/Synced counts + Sync Now
//    71. PendingSyncItemsScreen — the per-item list with per-item status
//    72. SyncFailedItemsScreen  — only-when-needed failed cards with Retry / Details / Support
//    73. SyncItemDetailScreen   — one item's driver-facing detail + admin-only technical expander
//    74. SyncCompleteScreen     — the calm "All Work Synced" confirmation
//
//  Presentational + props-driven only: no domain/runtime/data types. The real sync engine lives
//  elsewhere and feeds these screens primitive props + callbacks.
//

import SwiftUI

/* -------------------------------------------------------------------------- */
/* Shared status vocabulary (GUI Master §20 status set)                       */
/* -------------------------------------------------------------------------- */

/// The sync lifecycle states a driver is allowed to see.
enum SyncItemStatus: String {
    case savedOnPhone = "Saved on Phone"
    case pendingSync = "Pending Sync"
    case syncing = "Syncing"
    case synced = "Synced"
    case failed = "Failed"
}

/// The overall state of the phone's outbox, shown on Sync Home.
enum SyncOverallState: String {
    case allWorkSynced = "All Work Synced"
    case savedOnPhone = "Saved on Phone"
    case pendingSync = "Pending Sync"
    case syncFailed = "Sync Failed"
    case offlineMode = "Offline Mode"
}

private let itemStatusTone: [SyncItemStatus: Tone] = [
    .savedOnPhone: .info,
    .pendingSync: .warning,
    .syncing: .info,
    .synced: .success,
    .failed: .danger,
]

private let overallTone: [SyncOverallState: Tone] = [
    .allWorkSynced: .success,
    .savedOnPhone: .info,
    .pendingSync: .warning,
    .syncFailed: .danger,
    .offlineMode: .neutral,
]

/// A single item in the phone's outbox, in driver-facing language (no IDs/payloads).
struct SyncItem {
    /// Stable list key — a short driver-safe slug, never a UUID.
    var key: String
    /// Driver-readable label, e.g. "Field Ticket TKT-10488".
    var label: String
    var status: SyncItemStatus
}

/* -------------------------------------------------------------------------- */
/* 70. Sync Home                                                              */
/* -------------------------------------------------------------------------- */

/// Plain-English reassurance line for each overall state.
private func overallDetail(_ state: SyncOverallState, _ pending: Int) -> String {
    switch state {
    case .allWorkSynced:
        return "Everything on this phone has been sent to Ops Hub."
    case .savedOnPhone:
        return "Work saved on this phone will sync when it is ready."
    case .pendingSync:
        return "\(pending) item\(pending == 1 ? "" : "s") will sync when connection returns."
    case .syncFailed:
        return "Some items could not sync. Your work is still safe on this phone."
    case .offlineMode:
        return "You are offline. Work is saved on this phone and will sync automatically when you reconnect."
    }
    // Note: the TS source also has a `default:` branch returning "Your work is saved on this
    // phone." — unreachable there too, since the four cases above already cover every literal in
    // the SyncOverallState union. Omitted here as dead code.
}

struct SyncHomeScreen: View {
    var overallState: SyncOverallState = .savedOnPhone
    var pendingCount: Int = 0
    var failedCount: Int = 0
    var syncedCount: Int = 0
    var lastHubContactAt: String?
    var syncing: Bool = false
    var onSyncNow: () -> Void
    var onViewPending: () -> Void
    var onViewFailed: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let state = overallState
        let pending = pendingCount
        let failed = failedCount
        let synced = syncedCount

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Sync")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Your work is safe", testID: "sync-home-status", theme: t) {
                StatusBadge(label: state.rawValue, tone: overallTone[state] ?? .neutral, testID: "sync-home-state")
                Text(overallDetail(state, pending))
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                if let lastHubContactAt {
                    Text("Last Hub contact: \(lastHubContactAt).")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                } else {
                    Text("No Hub contact time is available yet.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }

            Card(title: "Counts", theme: t) {
                HStack(spacing: spacing.sm) {
                    CountTile(label: "Pending", value: pending, tone: .warning, theme: t)
                    CountTile(label: "Failed", value: failed, tone: failed > 0 ? .danger : .neutral, theme: t)
                    CountTile(label: "Synced", value: synced, tone: .success, theme: t)
                }
            }

            Card(title: "Keep your work moving", tone: .highlight, theme: t) {
                Text(
                    state == .allWorkSynced
                        ? "Nothing is waiting. You can keep working — new items sync on their own."
                        : "Your saved work syncs automatically. Tap Sync Now to push waiting work and re-check with Ops Hub. If you are offline, items go automatically when connection returns."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                FieldButton(
                    label: syncing ? "Syncing…" : "Sync Now",
                    onPress: onSyncNow,
                    disabled: syncing,
                    testID: "sync-home-sync-now",
                    theme: t
                )
            }

            Card(title: "Review items", theme: t) {
                Text("See exactly what is waiting, or fix anything that did not go through.")
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(t.textMuted)
                FieldButton(
                    label: pending > 0 ? "View Pending Items (\(pending))" : "View Pending Items",
                    onPress: onViewPending,
                    variant: .secondary,
                    testID: "sync-home-view-pending",
                    theme: t
                )
                if failed > 0 {
                    FieldButton(
                        label: "View Failed Items (\(failed))",
                        onPress: onViewFailed,
                        variant: .secondary,
                        testID: "sync-home-view-failed",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

private struct CountTile: View {
    var label: String
    var value: Int
    var tone: Tone
    var theme: Theme

    var body: some View {
        VStack(spacing: spacing.xs) {
            Text("\(value)")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(theme.text)
            StatusBadge(label: label, tone: tone)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, spacing.md)
        .padding(.horizontal, spacing.sm)
        .background(theme.cardMuted)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/* -------------------------------------------------------------------------- */
/* 71. Pending Sync Items                                                     */
/* -------------------------------------------------------------------------- */

struct PendingSyncItemsScreen: View {
    var items: [SyncItem] = []
    var reportedPendingCount: Int?
    var syncing: Bool = false
    var onSyncNow: () -> Void
    var onOpenItem: (String) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let listedWaiting = items.filter { $0.status != .synced }.count
        let waiting = max(listedWaiting, reportedPendingCount ?? 0)

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Sync Items")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text(
                waiting == 0
                    ? "All items have synced to Ops Hub."
                    : "\(waiting) item\(waiting == 1 ? "" : "s") still to sync. Everything here is saved on this phone."
            )
            .font(.system(size: typeScale.label))
            .foregroundStyle(t.textMuted)

            if items.isEmpty {
                Card(title: "No item details available", tone: .highlight, theme: t) {
                    Text(
                        "The current sync summary does not include item-level details. Tap Sync Now to refresh from Ops Hub."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                }
            } else {
                Card(title: "Today’s items", theme: t) {
                    ForEach(items, id: \.key) { item in
                        SyncItemRow(item: item, onPress: onOpenItem, theme: t)
                    }
                }
            }

            FieldButton(
                label: syncing ? "Syncing…" : "Sync Now",
                onPress: onSyncNow,
                disabled: syncing || waiting == 0,
                testID: "pending-sync-now",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/// A bordered, full-width tappable row showing a sync item's label + its status badge.
private struct SyncItemRow: View {
    var item: SyncItem
    var onPress: (String) -> Void
    var theme: Theme

    var body: some View {
        Button(action: { onPress(item.key) }) {
            HStack(spacing: spacing.sm) {
                Text(item.label)
                    .font(.system(size: typeScale.body, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusBadge(label: item.status.rawValue, tone: itemStatusTone[item.status] ?? .neutral)
            }
            .padding(spacing.md)
            .frame(minHeight: 56)
            .background(theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SyncItemRowPressStyle())
        .accessibilityLabel("\(item.label), \(item.status.rawValue)")
        .accessibilityIdentifier("pending-item-\(item.key)")
    }
}

/// Pressed-state opacity (0.7), matching the RN `Pressable`'s `pressed` style.
private struct SyncItemRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/* -------------------------------------------------------------------------- */
/* 72. Sync Failed Items                                                      */
/* -------------------------------------------------------------------------- */

/// A failed item in driver-facing language — no error codes, stack traces, or payloads.
struct FailedSyncItem {
    var key: String
    var label: String
    /// Plain-English reason, e.g. "Could not reach Ops Hub." Defaults to a generic line.
    var reason: String?
}

struct SyncFailedItemsScreen: View {
    var items: [FailedSyncItem] = []
    var reportedCount: Int?
    var retryingKey: String?
    var onRetry: ((String) -> Void)?
    var onViewDetails: ((String) -> Void)?
    var onContactSupport: ((String) -> Void)?
    var onRetryAll: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Couldn’t Sync")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            Text("These items are still saved on this phone. Nothing has been lost — try again, or get help.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(t.textMuted)

            if items.isEmpty {
                Card(title: "Item details unavailable", tone: .highlight, theme: t) {
                    if let reportedCount, reportedCount > 0 {
                        Text(
                            "Ops Hub reported \(reportedCount) item\(reportedCount == 1 ? "" : "s") that need attention, but item-level details are not available on this phone."
                        )
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    } else {
                        Text("No failed item details are available.")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                    }
                    if let onRetryAll {
                        FieldButton(
                            label: "Retry Sync", onPress: onRetryAll, testID: "failed-retry-all", theme: t)
                    }
                }
            } else {
                ForEach(items, id: \.key) { item in
                    FailedItemCard(
                        item: item,
                        initialRetrying: retryingKey == item.key,
                        onRetry: onRetry,
                        onViewDetails: onViewDetails,
                        onContactSupport: onContactSupport,
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }
}

/// A single failed-item card. Self-managing: tapping Retry / View Details / Contact Support flips
/// internal state so the driver sees an inline confirmation line, while still calling the existing
/// navigation callbacks the app drives.
private struct FailedItemCard: View {
    var item: FailedSyncItem
    var onRetry: ((String) -> Void)?
    var onViewDetails: ((String) -> Void)?
    var onContactSupport: ((String) -> Void)?
    var theme: Theme

    @State private var retrying: Bool
    @State private var notice: String?

    init(
        item: FailedSyncItem,
        initialRetrying: Bool,
        onRetry: ((String) -> Void)?,
        onViewDetails: ((String) -> Void)?,
        onContactSupport: ((String) -> Void)?,
        theme: Theme
    ) {
        self.item = item
        self.onRetry = onRetry
        self.onViewDetails = onViewDetails
        self.onContactSupport = onContactSupport
        self.theme = theme
        _retrying = State(initialValue: initialRetrying)
        _notice = State(initialValue: nil)
    }

    var body: some View {
        Card(title: item.label, testID: "failed-item-\(item.key)", theme: theme) {
            StatusBadge(label: "Failed", tone: .danger)
            Text(item.reason ?? "Could not sync.")
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.text)
            Text("Saved on this phone.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.textMuted)
            if let onRetry {
                FieldButton(
                    label: retrying ? "Retrying…" : "Retry",
                    onPress: {
                        retrying = true
                        notice = "Retry requested…"
                        onRetry(item.key)
                    },
                    disabled: retrying,
                    testID: "failed-retry-\(item.key)",
                    theme: theme
                )
            }
            if let onViewDetails {
                FieldButton(
                    label: "View Details",
                    onPress: {
                        notice = "Opening details…"
                        onViewDetails(item.key)
                    },
                    variant: .secondary,
                    testID: "failed-details-\(item.key)",
                    theme: theme
                )
            }
            if let onContactSupport {
                FieldButton(
                    label: "Contact Support",
                    onPress: {
                        notice = "Opening support…"
                        onContactSupport(item.key)
                    },
                    variant: .secondary,
                    testID: "failed-support-\(item.key)",
                    theme: theme
                )
            }
            if let notice {
                Text(notice)
                    .font(.system(size: typeScale.label))
                    .foregroundStyle(theme.textMuted)
                    .accessibilityIdentifier("failed-notice-\(item.key)")
            }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* 73. Sync Item Detail                                                       */
/* -------------------------------------------------------------------------- */

struct SyncItemDetailScreen: View {
    var itemLabel: String?
    var status: SyncItemStatus?
    var savedAt: String?
    var lastAttemptAt: String?
    /// Plain-English line shown for a failed item. Drivers never see raw errors.
    var failureReason: String?
    /// Whether this device is an admin device that may reveal technical detail.
    var isAdmin: Bool = false
    /// Admin-only technical lines (only rendered when isAdmin AND expanded).
    var technicalDetails: [String] = []
    var onRetry: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var showTech = false

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Item")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if let itemLabel, let status {
                Card(title: itemLabel, testID: "item-detail-card", theme: t) {
                    DetailRow(field: "Status", theme: t) {
                        StatusBadge(
                            label: status.rawValue, tone: itemStatusTone[status] ?? .neutral,
                            testID: "item-detail-status")
                    }
                    if let savedAt {
                        DetailRow(field: "Saved", theme: t) {
                            Text(savedAt)
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.text)
                        }
                    }
                    if let lastAttemptAt {
                        DetailRow(field: "Last attempt", theme: t) {
                            Text(lastAttemptAt)
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.text)
                        }
                    }
                    if let failureReason {
                        DetailRow(field: "What happened", theme: t) {
                            Text(failureReason)
                                .font(.system(size: typeScale.body))
                                .foregroundStyle(t.text)
                        }
                    }
                    if savedAt == nil, lastAttemptAt == nil {
                        Text("Timing details are not available for this item.")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.textMuted)
                    }
                }
            } else {
                Card(title: "Item details unavailable", tone: .highlight, testID: "item-detail-card", theme: t) {
                    Text("Select an item from the current sync list to view its status.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            if status == .failed, let onRetry {
                FieldButton(label: "Retry", onPress: onRetry, testID: "item-detail-retry", theme: t)
            }

            if isAdmin {
                Card(title: "Admin", theme: t) {
                    FieldButton(
                        label: showTech ? "Hide Technical Details" : "Technical Details",
                        onPress: { showTech.toggle() },
                        variant: .secondary,
                        testID: "item-detail-tech-toggle",
                        theme: t
                    )
                    if showTech {
                        VStack(alignment: .leading, spacing: spacing.xs) {
                            if technicalDetails.isEmpty {
                                Text("No additional technical detail recorded.")
                                    .font(.system(size: typeScale.label))
                                    .foregroundStyle(t.textMuted)
                            } else {
                                ForEach(Array(technicalDetails.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: typeScale.caption))
                                        .foregroundStyle(t.textMuted)
                                }
                            }
                        }
                        .padding(.top, spacing.sm)
                    }
                }
            }
        }
        .padding(spacing.lg)
    }
}

private struct DetailRow<Content: View>: View {
    var field: String
    var theme: Theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing.xs) {
            Text(field)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            content()
        }
        .padding(.vertical, spacing.sm)
    }
}

/* -------------------------------------------------------------------------- */
/* 74. Sync Complete                                                          */
/* -------------------------------------------------------------------------- */

struct SyncCompleteScreen: View {
    var syncConfirmed: Bool = false
    var lastSyncedAt: String?
    var syncedCount: Int?
    var onDone: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let synced = syncedCount
        let confirmed = syncConfirmed

        VStack(spacing: spacing.md) {
            Card(
                title: confirmed ? "All Work Synced" : "Sync status unavailable", tone: .highlight,
                testID: "sync-complete-card", theme: t
            ) {
                StatusBadge(
                    label: confirmed ? "Synced" : "Not Available", tone: confirmed ? .success : .neutral,
                    testID: "sync-complete-state")
                if confirmed, let synced {
                    Text("\(synced) item\(synced == 1 ? "" : "s") sent to Ops Hub.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } else if confirmed {
                    Text("Ops Hub confirmed that all work is synced.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                } else if !confirmed {
                    Text("A confirmed Hub sync result was not provided.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
                if let lastSyncedAt {
                    Text("Last synced \(lastSyncedAt).")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                FieldButton(label: "Done", onPress: onDone, testID: "sync-complete-done", theme: t)
            }
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
