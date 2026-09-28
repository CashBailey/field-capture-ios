//
//  Theme.swift
//  Ported from apps/mobile/src/design/theme.ts
//
//  Design tokens — pure constants, no view logic. The single source of truth for color/spacing/type
//  so screens stop hard-coding hex. Field-readability first: large type, high contrast. Color is
//  ALWAYS paired with a text/symbol signal elsewhere (see StatusBadge) — never color-alone.
//
//  The palette follows the Acme Oilfield Services brand (GUI Master §21): forest green +
//  brighter field green, light sky blue (info), saddle brown / amber (caution), cream surface
//  highlight, charcoal text, on a warm light-gray background. `brandGreen` stays #1F6F3A (the
//  established brand primary); the rest are added alongside it.
//

import SwiftUI

extension Color {
    /// Exact-hex initializer so palette tokens below read as `#RRGGBB`, same as the TS source.
    init(hex: String) {
        var scanned: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&scanned)
        let r = Double((scanned >> 16) & 0xFF) / 255
        let g = Double((scanned >> 8) & 0xFF) / 255
        let b = Double(scanned & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Brand + semantic palette (GUI Master §21 / logo color scheme).
enum Palette {
    // Greens
    static let brandGreen = Color(hex: "#1F6F3A")  // brand primary (light mode)
    static let forestGreen = Color(hex: "#16532B")  // darker forest green — header fills, pressed states
    static let brandGreenBright = Color(hex: "#34A853")  // brighter field green — dark-mode primary, success highlight
    // Accents from the logo
    static let skyBlue = Color(hex: "#7DC2E8")  // light sky-blue info accent (logo inner circle)
    static let infoBlue = Color(hex: "#2563EB")  // saturated info (kept for the existing 'info' tone)
    static let saddleBrown = Color(hex: "#8B5A2B")  // caution accent (cowboy-hat brown)
    static let safetyAmber = Color(hex: "#F59E0B")  // warning
    static let errorRed = Color(hex: "#B42318")  // destructive / failed
    static let cream = Color(hex: "#F5EFE3")  // surface highlight (logo belly cream)
    static let fieldSand = Color(hex: "#F5EFE3")  // alias kept for existing callers
    // Neutrals
    static let ink = Color(hex: "#17202A")  // charcoal text
    static let inkMuted = Color(hex: "#55616D")
    static let warmGray = Color(hex: "#F2F1EC")  // warm light-gray app background (light mode)
    static let surface = Color(hex: "#FFFFFF")
    static let surfaceMuted = Color(hex: "#FBFCFD")
    static let border = Color(hex: "#D7DDE2")
    static let onColor = Color(hex: "#FFFFFF")
    static let successText = Color(hex: "#1B5E20")
    // Dark mode neutrals
    static let charcoal = Color(hex: "#15191C")  // dark background
    static let charcoalCard = Color(hex: "#1F262B")  // elevated dark card
    static let darkBorder = Color(hex: "#33403A")
    static let lightText = Color(hex: "#F4F6F5")
}
/// Lowercase alias so call sites can write `palette.brandGreen`, matching the TS token exactly.
typealias palette = Palette

/// Semantic theme roles. Components read these so a light/dark swap is one value.
struct Theme: Equatable {
    enum Mode: String {
        case light
        case dark
    }

    var mode: Mode
    var background: Color
    var card: Color
    var cardMuted: Color
    var primary: Color
    var primaryDark: Color
    var onPrimary: Color
    var text: Color
    var textMuted: Color
    var border: Color
    var info: Color
    var success: Color
    var warning: Color
    var danger: Color
    var highlight: Color
}

let lightTheme = Theme(
    mode: .light,
    background: palette.warmGray,
    card: palette.surface,
    cardMuted: palette.surfaceMuted,
    primary: palette.brandGreen,
    primaryDark: palette.forestGreen,
    onPrimary: palette.onColor,
    text: palette.ink,
    textMuted: palette.inkMuted,
    border: palette.border,
    info: palette.skyBlue,
    success: palette.brandGreen,
    warning: palette.saddleBrown,
    danger: palette.errorRed,
    highlight: palette.cream
)

let darkTheme = Theme(
    mode: .dark,
    background: palette.charcoal,
    card: palette.charcoalCard,
    cardMuted: Color(hex: "#262E33"),
    primary: palette.brandGreenBright,
    primaryDark: palette.brandGreen,
    onPrimary: Color(hex: "#0B1A10"),
    text: palette.lightText,
    textMuted: Color(hex: "#9AA7A0"),
    border: palette.darkBorder,
    info: palette.skyBlue,
    success: palette.brandGreenBright,
    warning: palette.safetyAmber,
    danger: Color(hex: "#F2675A"),
    highlight: Color(hex: "#1E3A2A")
)

/// Default theme. A user theme toggle (GUI Master screen 78) swaps this later.
let theme = lightTheme

/// Type scale — title 26-30, body 16-18 (the field-readable floor).
///
/// Each token maps to the SwiftUI semantic style with the same default point size. Existing screen
/// calls keep their exact `Font.system(size: typeScale.*, weight:)` shape while Dynamic Type remains
/// active, matching React Native's default `allowFontScaling` behavior.
enum FieldTextSize {
    case title
    case heading
    case body
    case label
    case caption

    fileprivate var textStyle: Font.TextStyle {
        switch self {
        case .title: return .title
        case .heading: return .title3
        case .body: return .body
        case .label: return .subheadline
        case .caption: return .footnote
        }
    }
}

enum TypeScale {
    static let title = FieldTextSize.title
    static let heading = FieldTextSize.heading
    static let body = FieldTextSize.body
    static let label = FieldTextSize.label
    static let caption = FieldTextSize.caption
}
typealias typeScale = TypeScale

extension Font {
    static func system(
        size: FieldTextSize,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size.textStyle, design: design, weight: weight)
    }
}

enum SpacingScale {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}
typealias spacing = SpacingScale

/// Full-width field action buttons 56-64px tall; 48x48 minimum touch target.
enum Sizing {
    static let actionButtonHeight: CGFloat = 56
    static let minTouchTarget: CGFloat = 48
    static let radius: CGFloat = 8
    static let cardRadius: CGFloat = 14
    static let pillRadius: CGFloat = 14
}
typealias sizing = Sizing

/// Semantic tone -> color, used by badges/messages. Tone is reinforced by text, never color-alone.
enum Tone: String {
    case neutral
    case info
    case success
    case warning
    case danger
}

let toneColor: [Tone: Color] = [
    .neutral: palette.inkMuted,
    .info: palette.infoBlue,
    .success: palette.brandGreen,
    // Status badges sit on white in both themes; the darker brown clears normal-text contrast
    // while amber remains available for large fills and dark-mode accents.
    .warning: palette.saddleBrown,
    .danger: palette.errorRed,
]

extension View {
    /// `.accessibilityIdentifier` only when a testID-equivalent is actually supplied (mirrors the
    /// RN components' optional `testID` prop instead of always stamping an empty string).
    @ViewBuilder
    func accessibilityIdentifier(ifPresent id: String?) -> some View {
        if let id {
            self.accessibilityIdentifier(id)
        } else {
            self
        }
    }
}
