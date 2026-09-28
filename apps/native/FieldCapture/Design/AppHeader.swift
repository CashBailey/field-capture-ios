//
//  AppHeader.swift
//  Ported from apps/mobile/src/design/AppHeader.tsx
//
//  App header (GUI Master §3): a compact branded bar — "Field Capture" with the small circular logo —
//  plus an optional thin status strip of chips (Punched In, Offline Mode, N Pending Sync, Truck 7).
//  Show ONLY the chips that matter. Never put env labels, hub URLs, or backend strings here.
//

import SwiftUI

struct HeaderChip: Equatable {
    var label: String
    var tone: Tone = .neutral
}

private struct Chip: View {
    var chip: HeaderChip
    var theme: Theme

    var body: some View {
        let color = toneColor[chip.tone] ?? palette.inkMuted
        Text(chip.label)
            .font(.system(size: typeScale.caption, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, spacing.sm)
            .padding(.vertical, 2)
            .background(theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: sizing.pillRadius)
                    .stroke(color, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sizing.pillRadius))
    }
}

struct AppHeader: View {
    var title: String?
    var subtitle: String?
    var chips: [HeaderChip] = []
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.sm) {
            HStack(spacing: spacing.md) {
                Logo(size: 36, ring: true, testID: "app-logo")
                VStack(alignment: .leading, spacing: 0) {
                    Text(title ?? "Field Capture")
                        .font(.system(size: typeScale.heading, weight: .heavy))
                        .foregroundStyle(t.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: typeScale.caption))
                            .foregroundStyle(t.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }

            if !chips.isEmpty {
                FlowLayout(spacing: spacing.xs) {
                    ForEach(chips, id: \.label) { chip in
                        Chip(chip: chip, theme: t)
                    }
                }
                .accessibilityIdentifier("status-strip")
            }
        }
        .padding(.horizontal, spacing.lg)
        .padding(.bottom, spacing.sm)
        .background(t.card)
        .overlay(
            Rectangle()
                .fill(t.border)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

/// Minimal wrapping row layout — the `flexWrap: 'wrap'` equivalent for the chip strip. Native
/// `Layout` protocol, no dependency.
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
