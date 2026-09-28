//
//  SopScreens.swift
//  Ported from apps/mobile/src/screens/SopScreens.tsx
//
//  SOP Library (GUI Master §13 / §22) — role-based SOP access with filter chips. This is the
//  scaffold: the filters and the offline-first empty state are real; SOP content syncs from the Hub
//  as that slice lands (no fake SOPs are shown). Emergency SOPs are always reachable from here.
//

import SwiftUI

enum SopFilter: String {
    case all
    case required
    case job
    case emergency
    case ackNeeded = "ack-needed"
    case offline
    case recent
}

private struct SopFilterOption {
    var key: SopFilter
    var label: String
}

private let sopFilters: [SopFilterOption] = [
    SopFilterOption(key: .all, label: "All SOPs"),
    SopFilterOption(key: .required, label: "Required for Driver"),
    SopFilterOption(key: .job, label: "Job SOPs"),
    SopFilterOption(key: .emergency, label: "Emergency SOPs"),
    SopFilterOption(key: .ackNeeded, label: "Acknowledgement Needed"),
    SopFilterOption(key: .offline, label: "Available Offline"),
    SopFilterOption(key: .recent, label: "Recently Updated"),
]

struct SopLibraryScreen: View {
    var theme: Theme?

    @State private var filter: SopFilter = .all
    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("SOPs")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            SopFlowLayout(spacing: spacing.xs) {
                ForEach(sopFilters, id: \.key) { f in
                    let selected = f.key == filter
                    Button(action: { filter = f.key }) {
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
                    .accessibilityIdentifier("sop-filter-\(f.key.rawValue)")
                }
            }

            Card(title: "Procedures for your role", theme: t) {
                Text(
                    "Standard operating procedures sync to this phone so they are available in the field — even offline. None are downloaded yet; they will appear here once your role’s SOPs sync from Ops Hub."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.textMuted)
                .lineSpacing(4)
            }

            Card(title: "Emergency information", tone: .highlight, theme: t) {
                Text(
                    "In an emergency, stop work and make the area safe first. Emergency contacts and procedures are reachable from the Day screen, every job, and Help."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .lineSpacing(4)
            }
        }
        .padding(spacing.lg)
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for the filter chip strip.
/// Native `Layout` protocol, no dependency. (File-local copy: `AppHeader.swift`'s `FlowLayout` is
/// `private` to that file.)
private struct SopFlowLayout: Layout {
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
