//
//  Card.swift
//  Ported from apps/mobile/src/design/Card.tsx
//
//  Card (GUI Master §21): rounded surface for workday status, next action, job summary, inspection
//  sections, SOPs, sync items, evidence. Optional title + a 'highlight' tone (cream surface) to mark
//  the single most-important card on a screen (e.g. Next Required Step).
//

import SwiftUI

struct Card<Content: View>: View {
    enum Tone {
        case `default`
        case highlight
    }

    var title: String?
    var tone: Tone = .default
    var testID: String?
    var theme: Theme?
    @ViewBuilder var content: () -> Content

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let highlight = tone == .highlight

        VStack(alignment: .leading, spacing: spacing.sm) {
            if let title {
                Text(title)
                    .font(.system(size: typeScale.heading, weight: .bold))
                    .foregroundStyle(t.text)
            }
            content()
        }
        .padding(spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? t.highlight : t.card)
        .overlay(
            RoundedRectangle(cornerRadius: sizing.cardRadius)
                .stroke(t.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: sizing.cardRadius))
        .accessibilityIdentifier(ifPresent: testID)
    }
}

extension Card where Content == EmptyView {
    init(title: String? = nil, tone: Tone = .default, testID: String? = nil, theme: Theme? = nil) {
        self.init(title: title, tone: tone, testID: testID, theme: theme, content: { EmptyView() })
    }
}
