//
//  StatusBadge.swift
//  Ported from apps/mobile/src/design/StatusBadge.tsx
//
//  StatusBadge (spec 8.6): a status pill that is legible WITHOUT color — it always shows a text
//  label plus a leading symbol, with color only reinforcing. Dep-free: the leading glyph stands in
//  for a future native line icon; swapping the glyph for an icon won't change the contract. Never
//  render status as color-alone.
//
//  Note: like the RN source, this reads colors straight from `toneColor`/`Palette` (not the resolved
//  Theme) — a status badge's meaning must not shift with light/dark mode.
//

import SwiftUI

/// Tone -> a dep-free leading glyph. Replaced by a line icon on-device; the label carries meaning.
private let toneGlyph: [Tone: String] = [
    .neutral: "\u{2022}",  // •
    .info: "i",
    .success: "\u{2713}",  // ✓
    .warning: "!",
    .danger: "\u{2715}",  // ✕
]

struct StatusBadge: View {
    var label: String
    var tone: Tone = .neutral
    var testID: String?

    var body: some View {
        let color = toneColor[tone] ?? palette.inkMuted

        HStack(spacing: 4) {
            Text(toneGlyph[tone] ?? "\u{2022}")
                .font(.system(size: typeScale.caption, weight: .bold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: typeScale.caption, weight: .bold))
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: sizing.pillRadius)
                .stroke(color, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.pillRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tone.rawValue): \(label)")
        .accessibilityIdentifier(ifPresent: testID)
    }
}
