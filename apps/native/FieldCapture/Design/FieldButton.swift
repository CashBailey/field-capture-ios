//
//  FieldButton.swift
//  Ported from apps/mobile/src/design/Button.tsx
//
//  Button (GUI Master §21): primary = filled forest/field green, secondary = outlined/light fill,
//  destructive = red (always paired with a confirm modal by the caller). Full-width by default for a
//  screen's main next action; large touch target for gloved field use.
//
//  Named `FieldButton` (not `Button`) to avoid shadowing SwiftUI.Button, which it wraps.
//

import SwiftUI

enum ButtonVariant: String {
    case primary
    case secondary
    case destructive
}

struct FieldButton: View {
    var label: String
    var onPress: () -> Void
    var variant: ButtonVariant = .primary
    var fullWidth: Bool = true
    var disabled: Bool = false
    var testID: String?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme

        let bg: Color = variant == .primary ? t.primary : variant == .destructive ? t.danger : .clear
        let borderColor: Color = variant == .secondary ? t.border : variant == .destructive ? t.danger : bg
        let textColor: Color = variant == .primary ? t.onPrimary : variant == .destructive ? t.danger : t.text
        // destructive is always outline-only, never filled, even though `bg` above computes t.danger.
        let backgroundColor: Color = variant == .destructive ? .clear : bg

        Button(action: onPress) {
            Text(label)
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: sizing.actionButtonHeight)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, 18)
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: sizing.radius)
                        .stroke(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: sizing.radius))
                .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(FieldButtonPressStyle(disabled: disabled))
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// Pressed-state opacity (0.85), matching the RN `Pressable`'s `pressed && !disabled` style — skipped
/// when disabled since `.opacity(0.45)` already governs that state.
private struct FieldButtonPressStyle: ButtonStyle {
    var disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && !disabled ? 0.85 : 1)
    }
}
