//
//  SopExtraScreens.swift
//  Ported from apps/mobile/src/screens/SopExtraScreens.tsx
//
//  SOP extra screens (GUI Master §13 / screens 63-69) — the rest of the SOP section that sits beside
//  the SOP Library (screen 62, defined in SopScreens.swift — not duplicated here):
//
//    63. Required Driver SOPs   — the SOPs every driver must have read/acknowledged.
//    64. Job-Specific SOPs      — SOPs attached to the current job (e.g. produced water haul).
//    65. Emergency SOPs         — fast-access emergency procedures, reachable everywhere.
//    66. Recently Updated SOPs  — changed SOPs that need a fresh review.
//    67. SOP Search             — filtered search across the SOP set.
//    68. SOP Reader             — a single SOP in a mobile-friendly read layout.
//    69. SOP Acknowledgement    — the "I reviewed and understand" confirm modal.
//
//  Presentational + props-driven only. No backend calls. Driver-facing language only — no UUIDs,
//  versions-as-hashes, payloads, queues, or storage internals. Missing production data renders an
//  explicit unavailable state. Debug-only fixtures keep the screen gallery useful and are always
//  labeled as preview data.
//

import SwiftUI

/* ------------------------------------------------------------------ shared */

/// The driver-facing status of one SOP, drawn from the GUI Master §20 status set.
enum SopStatus: String {
    case required = "Required"
    case needsReview = "Needs Review"
    case complete = "Complete"
    case notStarted = "Not Started"
    case synced = "Synced"
    case savedOnPhone = "Saved on Phone"
}

private let sopStatusTone: [SopStatus: Tone] = [
    .required: .warning,
    .needsReview: .warning,
    .complete: .success,
    .notStarted: .neutral,
    .synced: .success,
    .savedOnPhone: .info,
]

/// A single SOP as the list/search/reader screens receive it (primitive fields only).
struct SopSummary {
    var id: String
    var title: String
    var role: String? = nil
    var version: String? = nil
    var updated: String? = nil
    var category: String? = nil
    var status: SopStatus? = nil
    var availableOffline: Bool? = nil
}

private struct SopPreviewNotice: View {
    var theme: Theme

    var body: some View {
        Card(tone: .highlight, theme: theme) {
            Text("Preview data")
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(theme.text)
            Text("These sample procedures are for the debug screen gallery only. They are not synced field data.")
                .font(.system(size: typeScale.label))
                .foregroundStyle(theme.textMuted)
                .lineSpacing(3)
        }
        .accessibilityIdentifier("sop-preview-notice")
    }
}

private struct SopUnavailableState: View {
    var title: String
    var message: String
    var theme: Theme

    var body: some View {
        Card(title: title, theme: theme) {
            Text(message)
                .font(.system(size: typeScale.body))
                .foregroundStyle(theme.textMuted)
                .lineSpacing(4)
        }
        .accessibilityIdentifier("sop-unavailable")
    }
}

/// Runtime fallback used until an authoritative SOP catalog is supplied by Ops Hub.
struct SopCatalogUnavailableScreen: View {
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
            SopUnavailableState(
                title: "SOP catalog unavailable",
                message:
                    "No verified procedures are available on this phone. Contact dispatch or your supervisor before relying on an SOP.",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

private struct StatusPill: View {
    var status: SopStatus

    var body: some View {
        StatusBadge(label: status.rawValue, tone: sopStatusTone[status] ?? .neutral)
    }
}

/// One SOP row rendered as a tappable Card; shared by the list-style screens.
private struct SopRow: View {
    var sop: SopSummary
    var onPress: (String) -> Void
    var theme: Theme
    var testID: String?

    var body: some View {
        Button(action: { onPress(sop.id) }) {
            Card(title: sop.title, theme: theme) {
                HStack(spacing: spacing.md) {
                    if let role = sop.role {
                        Text("Role: \(role)")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(theme.textMuted)
                    }
                    if let category = sop.category {
                        Text(category)
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(theme.textMuted)
                    }
                    if let version = sop.version {
                        Text(version)
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(theme.textMuted)
                    }
                    if let updated = sop.updated {
                        Text("Updated \(updated)")
                            .font(.system(size: typeScale.label))
                            .foregroundStyle(theme.textMuted)
                    }
                }
                HStack(spacing: spacing.xs) {
                    if let status = sop.status {
                        StatusPill(status: status)
                    }
                    if sop.availableOffline == true {
                        StatusBadge(label: "Available Offline", tone: .info)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sop.title)
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/* -------------------------------------------------- 63. Required Driver SOPs */

#if DEBUG
    private let previewRequiredBase: [SopSummary] = [
        SopSummary(id: "r1", title: "Driver Daily Workday Procedure", status: .complete),
        SopSummary(id: "r2", title: "DVIR / Vehicle Inspection", status: .complete),
        SopSummary(id: "r3", title: "Vacuum Truck Loading and Unloading", status: .required),
        SopSummary(id: "r4", title: "H2S Safety", status: .needsReview),
        SopSummary(id: "r5", title: "PPE Requirements", status: .complete),
        SopSummary(id: "r6", title: "Hose Handling", status: .required),
        SopSummary(id: "r7", title: "Spill Response", status: .required),
        SopSummary(id: "r8", title: "Stop Work Authority", status: .complete),
        SopSummary(id: "r9", title: "Heat Stress", status: .notStarted),
        SopSummary(id: "r10", title: "Vehicle Incident Response", status: .required),
    ]

    private let previewRequiredSops: [SopSummary] = previewRequiredBase.map { s in
        var copy = s
        copy.role = "Driver"
        copy.version = "Version 3"
        copy.updated = "May 14, 2026"
        copy.availableOffline = true
        return copy
    }
#endif

struct RequiredDriverSopsScreen: View {
    var sops: [SopSummary]? = nil
    var title: String? = nil
    var onOpenSop: (String) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    private var displayedSops: [SopSummary]? {
        #if DEBUG
            sops ?? previewRequiredSops
        #else
            sops
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sops == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme
        let reviewNeeded =
            displayedSops?.filter {
                $0.status == .required || $0.status == .needsReview || $0.status == .notStarted
            }.count ?? 0
        let completed = displayedSops?.filter { $0.status == .complete }.count ?? 0

        VStack(alignment: .leading, spacing: spacing.md) {
            Text(title ?? "Required Driver SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if let displayedSops {
                if displayedSops.isEmpty {
                    SopUnavailableState(
                        title: "No required SOPs assigned",
                        message: "No required driver procedures are currently assigned to this account.",
                        theme: t
                    )
                } else {
                    Card(tone: .highlight, theme: t) {
                        Text(
                            reviewNeeded > 0
                                ? "\(reviewNeeded) of \(displayedSops.count) SOPs still need your review."
                                : completed == displayedSops.count
                                    ? "You have reviewed every SOP required for your role."
                                    : "Review status is unavailable for one or more required SOPs."
                        )
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                        .lineSpacing(4)
                    }
                }

                ForEach(displayedSops, id: \.id) { sop in
                    SopRow(sop: sop, onPress: onOpenSop, theme: t, testID: "required-sop-\(sop.id)")
                }
            } else {
                SopUnavailableState(
                    title: "Required SOPs unavailable",
                    message: "Required driver procedures have not been supplied by Ops Hub.",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ------------------------------------------------------ 64. Job-Specific SOPs */

#if DEBUG
    private let previewJobSopsBase: [SopSummary] = [
        SopSummary(id: "j1", title: "Vacuum Truck Loading and Unloading", status: .complete),
        SopSummary(id: "j2", title: "H2S Safety", status: .needsReview),
        SopSummary(id: "j3", title: "Hose Handling", status: .required),
        SopSummary(id: "j4", title: "Spill Response", status: .required),
        SopSummary(id: "j5", title: "Stop Work Authority", status: .complete),
        SopSummary(id: "j6", title: "Customer Site Rules", status: .required),
    ]

    private let previewJobSops: [SopSummary] = previewJobSopsBase.map { s in
        var copy = s
        copy.role = "Driver"
        copy.version = "Version 2"
        copy.availableOffline = true
        return copy
    }
#endif

struct JobSpecificSopsScreen: View {
    var jobType: String? = nil
    var customer: String? = nil
    var lease: String? = nil
    var well: String? = nil
    var sops: [SopSummary]? = nil
    var onOpenSop: (String) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    private var displayedSops: [SopSummary]? {
        #if DEBUG
            sops ?? previewJobSops
        #else
            sops
        #endif
    }

    private var displayedJobType: String? {
        #if DEBUG
            sops == nil ? (jobType ?? "Produced Water Haul") : jobType
        #else
            jobType
        #endif
    }

    private var displayedSiteDetails: [String] {
        #if DEBUG
            if sops == nil {
                return [customer ?? "Acme Energy", lease ?? "Northfield", well ?? "114H"]
            }
            return [customer, lease, well].compactMap { $0 }
        #else
            [customer, lease, well].compactMap { $0 }
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sops == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Job-Specific SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if displayedJobType != nil || !displayedSiteDetails.isEmpty {
                Card(title: displayedJobType ?? "Current job", theme: t) {
                    if !displayedSiteDetails.isEmpty {
                        Text(displayedSiteDetails.joined(separator: " · "))
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.textMuted)
                    }
                    Text("Review the procedures supplied for this job before starting work on site.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            if let displayedSops {
                if displayedSops.isEmpty {
                    SopUnavailableState(
                        title: "No job SOPs assigned",
                        message: "No job-specific procedures are currently attached to this assignment.",
                        theme: t
                    )
                }
                ForEach(displayedSops, id: \.id) { sop in
                    SopRow(sop: sop, onPress: onOpenSop, theme: t, testID: "job-sop-\(sop.id)")
                }
            } else {
                SopUnavailableState(
                    title: "Job SOPs unavailable",
                    message: "Verified procedures for this job have not been supplied by Ops Hub.",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ---------------------------------------------------------- 65. Emergency SOPs */

struct EmergencySop {
    var id: String
    var title: String
    var availableOffline: Bool? = nil
}

#if DEBUG
    private let previewEmergencySops: [EmergencySop] = [
        EmergencySop(id: "e1", title: "H2S Alarm", availableOffline: true),
        EmergencySop(id: "e2", title: "Spill / Release", availableOffline: true),
        EmergencySop(id: "e3", title: "Fire", availableOffline: true),
        EmergencySop(id: "e4", title: "Heat Illness", availableOffline: true),
        EmergencySop(id: "e5", title: "Vehicle Incident", availableOffline: true),
        EmergencySop(id: "e6", title: "Unsafe Road", availableOffline: true),
        EmergencySop(id: "e7", title: "Stop Work Authority", availableOffline: true),
        EmergencySop(id: "e8", title: "Emergency Contacts", availableOffline: true),
    ]
#endif

struct EmergencySopsScreen: View {
    var sops: [EmergencySop]? = nil
    var onOpenSop: (String) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    private var displayedSops: [EmergencySop]? {
        #if DEBUG
            sops ?? previewEmergencySops
        #else
            sops
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sops == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Emergency SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(tone: .highlight, theme: t) {
                Text(
                    "Stop work and make the area safe first. Use only a verified procedure supplied for the current emergency."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .lineSpacing(4)
            }

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if let displayedSops {
                if displayedSops.isEmpty {
                    SopUnavailableState(
                        title: "No emergency SOPs available",
                        message: "Contact dispatch or your supervisor for the verified emergency procedure.",
                        theme: t
                    )
                }
                ForEach(displayedSops, id: \.id) { sop in
                    Card(title: sop.title, testID: "emergency-sop-\(sop.id)", theme: t) {
                        if sop.availableOffline == true {
                            HStack(spacing: spacing.xs) {
                                StatusBadge(label: "Available Offline", tone: .info)
                            }
                        }
                        FieldButton(
                            label: "Open Emergency Procedure",
                            onPress: { onOpenSop(sop.id) },
                            variant: .destructive,
                            testID: "emergency-open-\(sop.id)",
                            theme: t
                        )
                    }
                }
            } else {
                SopUnavailableState(
                    title: "Emergency SOPs unavailable",
                    message:
                        "No verified emergency procedures are available on this phone. Contact dispatch or your supervisor.",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ----------------------------------------------------- 66. Recently Updated SOPs */

#if DEBUG
    private let previewRecentSopsBase: [SopSummary] = [
        SopSummary(id: "u1", title: "H2S Safety Procedure", updated: "May 14, 2026", status: .needsReview),
        SopSummary(id: "u2", title: "Hose Handling", updated: "May 9, 2026", status: .needsReview),
        SopSummary(id: "u3", title: "Spill Response", updated: "May 2, 2026", status: .needsReview),
    ]

    private let previewRecentSops: [SopSummary] = previewRecentSopsBase.map { s in
        var copy = s
        copy.role = "Driver"
        copy.version = "Version 4"
        copy.availableOffline = true
        return copy
    }
#endif

struct RecentlyUpdatedSopsScreen: View {
    var sops: [SopSummary]? = nil
    var onReviewSop: (String) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    private var displayedSops: [SopSummary]? {
        #if DEBUG
            sops ?? previewRecentSops
        #else
            sops
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sops == nil
        #else
            false
        #endif
    }

    var body: some View {
        let t = theme ?? envTheme
        let reviewNeeded =
            displayedSops?.filter {
                $0.status == .required || $0.status == .needsReview || $0.status == .notStarted
            }.count ?? 0

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Recently Updated SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if let displayedSops {
                Card(tone: .highlight, theme: t) {
                    Text(
                        displayedSops.isEmpty
                            ? "No recently updated SOPs are assigned to you."
                            : reviewNeeded > 0
                                ? "\(reviewNeeded) recently updated SOP\(reviewNeeded == 1 ? " needs" : "s need") your review."
                                : "\(displayedSops.count) recently updated SOP\(displayedSops.count == 1 ? " is" : "s are") available."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    .lineSpacing(4)
                }

                ForEach(displayedSops, id: \.id) { sop in
                    Card(title: sop.title, testID: "recent-sop-\(sop.id)", theme: t) {
                        if let updated = sop.updated {
                            Text("Updated \(updated)")
                                .font(.system(size: typeScale.label))
                                .foregroundStyle(t.textMuted)
                        }
                        HStack(spacing: spacing.xs) {
                            if let status = sop.status {
                                StatusPill(status: status)
                            }
                            if sop.availableOffline == true {
                                StatusBadge(label: "Available Offline", tone: .info)
                            }
                        }
                        FieldButton(
                            label: "Review SOP",
                            onPress: { onReviewSop(sop.id) },
                            testID: "recent-review-\(sop.id)",
                            theme: t
                        )
                    }
                }
            } else {
                SopUnavailableState(
                    title: "Recent SOP updates unavailable",
                    message: "SOP update history has not been supplied by Ops Hub.",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/* ---------------------------------------------------------------- 67. SOP Search */

enum SopSearchFilter: String {
    case all
    case driver
    case emergency
    case job
    case ackNeeded = "ack-needed"
    case offline
}

private struct SopSearchFilterOption {
    var key: SopSearchFilter
    var label: String
}

private let searchFilters: [SopSearchFilterOption] = [
    SopSearchFilterOption(key: .all, label: "All"),
    SopSearchFilterOption(key: .driver, label: "Driver"),
    SopSearchFilterOption(key: .job, label: "Job"),
    SopSearchFilterOption(key: .ackNeeded, label: "Acknowledgement Needed"),
    SopSearchFilterOption(key: .offline, label: "Available Offline"),
]

#if DEBUG
    private let previewSearchResults: [SopSummary] = [
        SopSummary(
            id: "s1", title: "H2S Safety", role: "Driver", version: "Version 4", category: "Emergency",
            status: .needsReview, availableOffline: true),
        SopSummary(
            id: "s2", title: "Vacuum Truck Loading and Unloading", role: "Driver", version: "Version 3",
            category: "Driver",
            status: .required, availableOffline: true),
        SopSummary(
            id: "s3", title: "Customer Site Rules", role: "Driver", version: "Version 2", category: "Job",
            status: .required, availableOffline: false),
        SopSummary(
            id: "s4", title: "PPE Requirements", role: "Driver", version: "Version 1", category: "Driver",
            status: .complete, availableOffline: true),
    ]
#endif

private func matchesFilter(_ sop: SopSummary, _ filter: SopSearchFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .driver:
        return sop.category == "Driver"
    case .emergency:
        return sop.category == "Emergency"
    case .job:
        return sop.category == "Job"
    case .ackNeeded:
        return sop.status == .needsReview || sop.status == .required
    case .offline:
        return sop.availableOffline == true
    }
}

struct SopSearchScreen: View {
    var results: [SopSummary]? = nil
    var query: String? = nil
    var filter: SopSearchFilter? = nil
    var onQueryChange: ((String) -> Void)? = nil
    var onFilterChange: ((SopSearchFilter) -> Void)? = nil
    var onOpenSop: (String) -> Void
    var theme: Theme?

    @State private var queryState: String
    @State private var filterState: SopSearchFilter
    @Environment(\.fieldTheme) private var envTheme

    private var displayedResults: [SopSummary]? {
        #if DEBUG
            results ?? previewSearchResults
        #else
            results
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            results == nil
        #else
            false
        #endif
    }

    init(
        results: [SopSummary]? = nil,
        query: String? = nil,
        filter: SopSearchFilter? = nil,
        onQueryChange: ((String) -> Void)? = nil,
        onFilterChange: ((SopSearchFilter) -> Void)? = nil,
        onOpenSop: @escaping (String) -> Void,
        theme: Theme? = nil
    ) {
        self.results = results
        self.query = query
        self.filter = filter
        self.onQueryChange = onQueryChange
        self.onFilterChange = onFilterChange
        self.onOpenSop = onOpenSop
        self.theme = theme
        _queryState = State(initialValue: query ?? "")
        _filterState = State(initialValue: filter ?? .all)
    }

    var body: some View {
        let t = theme ?? envTheme
        let q = queryState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredResults =
            displayedResults?.filter { sop in
                matchesFilter(sop, filterState) && (q.isEmpty || sop.title.lowercased().contains(q))
            } ?? []

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("SOP Search")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if displayedResults != nil {
                TextField("Search SOPs", text: $queryState)
                    .onChange(of: queryState) { newValue in
                        onQueryChange?(newValue)
                    }
                    .foregroundStyle(t.text)
                    .padding(.horizontal, spacing.md)
                    .frame(minHeight: 48)
                    .background(t.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(t.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Search SOPs")
                    .accessibilityIdentifier("sop-search-input")

                SopSearchFlowLayout(spacing: spacing.xs) {
                    ForEach(searchFilters, id: \.key) { f in
                        let selected = f.key == filterState
                        Button(action: {
                            filterState = f.key
                            onFilterChange?(f.key)
                        }) {
                            Text(f.label)
                                .font(.system(size: typeScale.caption, weight: .semibold))
                                .foregroundStyle(selected ? t.onPrimary : t.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selected ? t.primary : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(selected ? t.primary : t.border, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("sop-search-filter-\(f.key.rawValue)")
                    }
                }

                if filteredResults.isEmpty {
                    Card(theme: t) {
                        Text("No SOPs match your search. Try a different word or filter.")
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.textMuted)
                    }
                } else {
                    ForEach(filteredResults, id: \.id) { sop in
                        SopRow(sop: sop, onPress: onOpenSop, theme: t, testID: "sop-search-result-\(sop.id)")
                    }
                }
            } else {
                SopUnavailableState(
                    title: "SOP search unavailable",
                    message: "There is no verified SOP catalog to search on this phone.",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for the filter chip strip. Native
/// `Layout` protocol, no dependency. (File-local copy: other Screens files keep their own; see
/// `SopScreens.swift`'s `SopFlowLayout` / `AppHeader.swift`'s `FlowLayout`.)
private struct SopSearchFlowLayout: Layout {
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

/* ---------------------------------------------------------------- 68. SOP Reader */

struct SopReaderContent {
    var title: String
    var version: String? = nil
    var role: String? = nil
    var status: SopStatus? = nil
    var availableOffline: Bool? = nil
    var summary: String? = nil
    var steps: [String]? = nil
    var ppe: [String]? = nil
    var warnings: [String]? = nil
    var emergencyActions: [String]? = nil
    var relatedForms: [String]? = nil
}

#if DEBUG
    private let previewReader = SopReaderContent(
        title: "H2S Safety",
        version: "Version 4",
        role: "Driver",
        status: .needsReview,
        availableOffline: true,
        summary:
            "Hydrogen sulfide can be present at well sites and tank batteries. Always wear your monitor, know the wind direction, and move upwind and uphill if an alarm sounds.",
        steps: [
            "Turn on and bump-test your H2S monitor before leaving the yard.",
            "On arrival, check the wind sock and note your upwind escape route.",
            "Keep your monitor on and within hearing range at all times.",
            "If an alarm sounds, hold your breath, move upwind and uphill, and account for others.",
        ],
        ppe: ["Personal H2S monitor", "FR clothing", "Safety glasses", "Steel-toe boots", "Hard hat"],
        warnings: [
            "H2S is heavier than air and collects in low spots.",
            "You can lose your sense of smell at dangerous concentrations — never rely on odor.",
        ],
        emergencyActions: [
            "Move upwind and uphill to the muster point.",
            "Call for help and account for all personnel.",
            "Do not re-enter the area until it is declared safe.",
        ],
        relatedForms: ["JHA / JSA", "Vehicle Incident Report"]
    )
#endif

private struct ReaderSection<Content: View>: View {
    var title: String
    var theme: Theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        Card(title: title, theme: theme) {
            content()
        }
    }
}

private struct BulletList: View {
    var items: [String]
    var theme: Theme

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .top, spacing: spacing.sm) {
                Text("•")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.textMuted)
                Text(item)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.text)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct StepList: View {
    var items: [String]
    var theme: Theme

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
            HStack(alignment: .top, spacing: spacing.sm) {
                Text("\(i + 1).")
                    .font(.system(size: typeScale.body, weight: .bold))
                    .foregroundStyle(theme.primary)
                    .frame(minWidth: 22, alignment: .leading)
                Text(item)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(theme.text)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }
}

struct SopReaderScreen: View {
    var sop: SopReaderContent? = nil
    var onAcknowledge: (() -> Void)? = nil
    var onSaveOffline: (() -> Void)? = nil
    var onShareWithSupervisor: (() -> Void)? = nil
    var onBackToJob: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var savedOffline: Bool
    @State private var shared = false

    private var displayedSop: SopReaderContent? {
        #if DEBUG
            sop ?? previewReader
        #else
            sop
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sop == nil
        #else
            false
        #endif
    }

    init(
        sop: SopReaderContent? = nil,
        onAcknowledge: (() -> Void)? = nil,
        onSaveOffline: (() -> Void)? = nil,
        onShareWithSupervisor: (() -> Void)? = nil,
        onBackToJob: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.sop = sop
        self.onAcknowledge = onAcknowledge
        self.onSaveOffline = onSaveOffline
        self.onShareWithSupervisor = onShareWithSupervisor
        self.onBackToJob = onBackToJob
        self.theme = theme
        _savedOffline = State(initialValue: sop?.availableOffline ?? false)
    }

    private func doSaveOffline() {
        guard let onSaveOffline else { return }
        onSaveOffline()
        savedOffline = true
    }

    private func doShare() {
        guard let onShareWithSupervisor else { return }
        onShareWithSupervisor()
        shared = true
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text(displayedSop?.title ?? "SOP")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if let displayedSop {
                let availableOffline = savedOffline || displayedSop.availableOffline == true
                if displayedSop.version != nil || displayedSop.role != nil || displayedSop.status != nil
                    || availableOffline
                {
                    Card(theme: t) {
                        HStack(spacing: spacing.md) {
                            if let version = displayedSop.version {
                                Text(version)
                                    .font(.system(size: typeScale.label))
                                    .foregroundStyle(t.textMuted)
                            }
                            if let role = displayedSop.role {
                                Text("Role: \(role)")
                                    .font(.system(size: typeScale.label))
                                    .foregroundStyle(t.textMuted)
                            }
                        }
                        HStack(spacing: spacing.xs) {
                            if let status = displayedSop.status {
                                StatusPill(status: status)
                            }
                            if availableOffline {
                                StatusBadge(label: "Available Offline", tone: .info)
                            }
                        }
                    }
                }

                if let summary = displayedSop.summary {
                    Card(title: "Important summary", tone: .highlight, theme: t) {
                        Text(summary)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                            .lineSpacing(4)
                    }
                }

                if let steps = displayedSop.steps, !steps.isEmpty {
                    ReaderSection(title: "Procedure steps", theme: t) {
                        StepList(items: steps, theme: t)
                    }
                }

                if let ppe = displayedSop.ppe, !ppe.isEmpty {
                    ReaderSection(title: "Required PPE", theme: t) {
                        BulletList(items: ppe, theme: t)
                    }
                }

                if let warnings = displayedSop.warnings, !warnings.isEmpty {
                    ReaderSection(title: "Warnings", theme: t) {
                        BulletList(items: warnings, theme: t)
                    }
                }

                if let emergencyActions = displayedSop.emergencyActions, !emergencyActions.isEmpty {
                    ReaderSection(title: "Emergency actions", theme: t) {
                        BulletList(items: emergencyActions, theme: t)
                    }
                }

                if let relatedForms = displayedSop.relatedForms, !relatedForms.isEmpty {
                    ReaderSection(title: "Related forms", theme: t) {
                        BulletList(items: relatedForms, theme: t)
                    }
                }

                if let onAcknowledge {
                    FieldButton(
                        label: "Acknowledge",
                        onPress: onAcknowledge,
                        testID: "sop-reader-acknowledge",
                        theme: t
                    )
                }
                if onSaveOffline != nil {
                    FieldButton(
                        label: savedOffline ? "Saved Offline" : "Save Offline",
                        onPress: doSaveOffline,
                        variant: .secondary,
                        disabled: savedOffline,
                        testID: "sop-reader-save-offline",
                        theme: t
                    )
                    if savedOffline {
                        Text("Saved on this phone")
                            .font(.system(size: typeScale.label, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                            .accessibilityIdentifier("sop-reader-save-feedback")
                    }
                }
                if onShareWithSupervisor != nil {
                    FieldButton(
                        label: shared ? "Shared with Supervisor" : "Share with Supervisor",
                        onPress: doShare,
                        variant: .secondary,
                        testID: "sop-reader-share",
                        theme: t
                    )
                    if shared {
                        Text("Sent to your supervisor")
                            .font(.system(size: typeScale.label, weight: .semibold))
                            .foregroundStyle(t.textMuted)
                            .accessibilityIdentifier("sop-reader-share-feedback")
                    }
                }
            } else {
                SopUnavailableState(
                    title: "SOP unavailable",
                    message: "This procedure has not been supplied by Ops Hub.",
                    theme: t
                )
            }

            FieldButton(
                label: "Back to Job",
                onPress: onBackToJob,
                variant: .secondary,
                testID: "sop-reader-back",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* ------------------------------------------------------- 69. SOP Acknowledgement */

struct SopAcknowledgementScreen: View {
    var sopTitle: String? = nil
    var acknowledgedBy: String? = nil
    var acknowledgedAt: String? = nil
    var onAcknowledge: () -> Void
    var onCancel: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var acknowledged: Bool

    private var displayedTitle: String? {
        #if DEBUG
            sopTitle ?? "H2S Safety"
        #else
            sopTitle
        #endif
    }

    private var isShowingPreviewData: Bool {
        #if DEBUG
            sopTitle == nil
        #else
            false
        #endif
    }

    private var acknowledgementMessage: String {
        switch (acknowledgedBy, acknowledgedAt) {
        case (let by?, let at?):
            "\(by) acknowledged this SOP on \(at)."
        case (let by?, nil):
            "\(by) acknowledged this SOP."
        case (nil, let at?):
            "This SOP was acknowledged on \(at)."
        case (nil, nil):
            "Acknowledgement recorded."
        }
    }

    init(
        sopTitle: String? = nil,
        acknowledged: Bool? = nil,
        acknowledgedBy: String? = nil,
        acknowledgedAt: String? = nil,
        onAcknowledge: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.sopTitle = sopTitle
        self.acknowledgedBy = acknowledgedBy
        self.acknowledgedAt = acknowledgedAt
        self.onAcknowledge = onAcknowledge
        self.onCancel = onCancel
        self.theme = theme
        _acknowledged = State(initialValue: acknowledged ?? false)
    }

    private func doAcknowledge() {
        acknowledged = true
        onAcknowledge()
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Acknowledge SOP?")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if isShowingPreviewData {
                SopPreviewNotice(theme: t)
            }

            if let displayedTitle {
                Card(title: displayedTitle, tone: .highlight, theme: t) {
                    if acknowledged {
                        HStack(spacing: spacing.xs) {
                            StatusBadge(label: "Acknowledged", tone: .success)
                        }
                        Text(acknowledgementMessage)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.text)
                        FieldButton(
                            label: "Done",
                            onPress: onCancel,
                            variant: .secondary,
                            testID: "sop-ack-done",
                            theme: t
                        )
                    } else {
                        Text(
                            "By acknowledging, you confirm that you reviewed this SOP and understand the driver requirements."
                        )
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                        FieldButton(
                            label: "Acknowledge",
                            onPress: doAcknowledge,
                            testID: "sop-ack-confirm",
                            theme: t
                        )
                        FieldButton(
                            label: "Cancel",
                            onPress: onCancel,
                            variant: .secondary,
                            testID: "sop-ack-cancel",
                            theme: t
                        )
                    }
                }
            } else {
                SopUnavailableState(
                    title: "Acknowledgement unavailable",
                    message: "No verified SOP was supplied for acknowledgement.",
                    theme: t
                )
                FieldButton(
                    label: "Cancel",
                    onPress: onCancel,
                    variant: .secondary,
                    testID: "sop-ack-cancel",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }
}
