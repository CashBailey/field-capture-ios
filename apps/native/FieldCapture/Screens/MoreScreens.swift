//
//  MoreScreens.swift
//  Ported from apps/mobile/src/screens/MoreScreens.tsx
//
//  More & Settings (GUI Master §15 / screens 75–83) — the driver's settings hub. These screens are
//  low-stakes by design: profile + role, language/theme/text-size preferences, a driver-safe printer
//  panel, help/dispatch contacts, and a sign-out that is careful to say it does NOT punch you out.
//
//  Selectable preferences keep local editing state only when the host supplies real callbacks.
//  Missing capabilities and Hub profile values render as unavailable; controls never manufacture a
//  success state. Sign-out is an inline confirmation card (no native modal dependency) per the house
//  pattern. Driver-facing language only: no UUIDs, environment strings, Hub URLs, or storage
//  internals (GUI Master §20).
//

import SwiftUI
import UIKit

/* ------------------------------------------------------------------ */
/* Shared local primitives                                            */
/* ------------------------------------------------------------------ */

/// Pressed-state opacity (0.85), matching the RN Pressable's `pressed` style used by the rows below.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private func hubValue(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "Not provided by Hub" : trimmed
}

private func syncStatusLabel(for tone: Tone) -> String {
    switch tone {
    case .success: return "Up to Date"
    case .warning: return "Waiting to Sync"
    case .danger: return "Needs Attention"
    case .info: return "Syncing"
    case .neutral: return "Status Unavailable"
    }
}

/// `Linking.openURL(...).catch(...)` equivalent — best-effort URL open with an optional failure
/// callback (tel:/sms: hand-off to the OS dialer/Messages).
private func openURL(_ urlString: String, onFailure: (() -> Void)? = nil) {
    guard let url = URL(string: urlString) else {
        onFailure?()
        return
    }
    UIApplication.shared.open(url, options: [:]) { success in
        if !success { onFailure?() }
    }
}

/// A read-only "label : value" pair, used by Account and contact cards.
private struct FieldRow: View {
    var label: String
    var value: String
    var theme: Theme

    var body: some View {
        HStack(alignment: .center, spacing: spacing.md) {
            Text(label)
                .font(.system(size: typeScale.label, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            Spacer(minLength: spacing.md)
            Text(value)
                .font(.system(size: typeScale.body, weight: .bold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
    }
}

/// A single-select option row (radio-style) for language / theme / text-size pickers.
private struct OptionRow: View {
    var label: String
    var hint: String? = nil
    var selected: Bool
    var onPress: () -> Void
    var testID: String? = nil
    var theme: Theme

    var body: some View {
        let t = theme
        Button(action: onPress) {
            HStack(spacing: spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: typeScale.body, weight: .bold))
                        .foregroundStyle(t.text)
                    if let hint {
                        Text(hint)
                            .font(.system(size: typeScale.caption))
                            .foregroundStyle(t.textMuted)
                    }
                }
                Spacer()
                ZStack {
                    Circle()
                        .stroke(selected ? t.primary : t.border, lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if selected {
                        Circle()
                            .fill(t.primary)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(.horizontal, spacing.md)
            .padding(.vertical, spacing.sm)
            .frame(minHeight: 52)
            .background(selected ? t.highlight : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? t.primary : t.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RowPressStyle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// A tappable navigation row used by the More Home settings list.
private struct NavRow: View {
    struct Badge {
        var label: String
        var tone: Tone
    }

    var label: String
    var badge: Badge? = nil
    var onPress: () -> Void
    var testID: String? = nil
    var theme: Theme

    var body: some View {
        let t = theme
        Button(action: onPress) {
            HStack {
                Text(label)
                    .font(.system(size: typeScale.body, weight: .semibold))
                    .foregroundStyle(t.text)
                Spacer()
                if let badge {
                    StatusBadge(label: badge.label, tone: badge.tone)
                } else {
                    Text("›")
                        .font(.system(size: typeScale.heading, weight: .bold))
                        .foregroundStyle(t.textMuted)
                }
            }
            .padding(.vertical, spacing.sm)
            .frame(minHeight: 48)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/// A short, inline confirmation line shown after an action button is tapped.
private struct FeedbackLine: View {
    var text: String
    var tone: Tone = .success
    var theme: Theme

    private var color: Color {
        switch tone {
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .info: return theme.info
        case .neutral: return theme.textMuted
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: typeScale.label, weight: .bold))
            .foregroundStyle(color)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/* ------------------------------------------------------------------ */
/* 75. More Home                                                      */
/* ------------------------------------------------------------------ */

struct MoreHomeScreen: View {
    var driverName: String?
    var driverRole: String?
    var department: String?
    /// Plain-English sync line, e.g. "All work synced" or "2 items waiting to sync".
    var syncSummary: String?
    var syncTone: Tone?
    /// Whether Admin Mode entry is shown (still locked behind a PIN elsewhere).
    var showAdminMode: Bool?
    var onOpenAccount: () -> Void
    /// Optional: when omitted, the Language row is hidden (i18n not yet shipped — see TODO).
    var onOpenLanguage: (() -> Void)?
    var onOpenTheme: () -> Void
    var onOpenTextSize: () -> Void
    var onOpenPrinter: () -> Void
    var onOpenHelp: () -> Void
    var onOpenContactDispatch: () -> Void
    var onOpenAdminMode: () -> Void
    var onSignOut: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let driverName = hubValue(self.driverName)
        let driverRole = hubValue(self.driverRole)
        let department = hubValue(self.department)
        let syncSummary = self.syncSummary ?? "Sync status is unavailable."
        let syncTone = self.syncTone ?? .neutral
        let showAdminMode = self.showAdminMode ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("More")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Profile", testID: "more-profile", theme: t) {
                Text(driverName)
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(t.text)
                FieldRow(label: "Role", value: driverRole, theme: t)
                FieldRow(label: "Department", value: department, theme: t)
            }

            Card(title: "Sync summary", testID: "more-sync", theme: t) {
                StatusBadge(label: syncStatusLabel(for: syncTone), tone: syncTone)
                Text(syncSummary)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            Card(title: "Settings", theme: t) {
                NavRow(label: "Account", onPress: onOpenAccount, testID: "more-account", theme: t)
                // Language is hidden until real i18n ships — never present a control that does nothing.
                // TODO(i18n): translate screens (DVIR/JHA Spanish) then restore onOpenLanguage.
                if let onOpenLanguage {
                    NavRow(label: "Language", onPress: onOpenLanguage, testID: "more-language", theme: t)
                }
                NavRow(label: "Theme", onPress: onOpenTheme, testID: "more-theme", theme: t)
                NavRow(
                    label: "Text & Accessibility", onPress: onOpenTextSize, testID: "more-textsize", theme: t)
                NavRow(label: "Printer", onPress: onOpenPrinter, testID: "more-printer", theme: t)
                NavRow(label: "Help and Support", onPress: onOpenHelp, testID: "more-help", theme: t)
                NavRow(
                    label: "Contact Dispatch",
                    onPress: onOpenContactDispatch,
                    testID: "more-dispatch",
                    theme: t
                )
                if showAdminMode {
                    NavRow(
                        label: "Admin Mode",
                        badge: NavRow.Badge(label: "Locked", tone: .neutral),
                        onPress: onOpenAdminMode,
                        testID: "more-admin",
                        theme: t
                    )
                }
            }

            FieldButton(
                label: "Sign Out",
                onPress: onSignOut,
                variant: .secondary,
                testID: "more-signout",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* ------------------------------------------------------------------ */
/* 76. Account                                                        */
/* ------------------------------------------------------------------ */

struct AccountScreen: View {
    var name: String?
    var role: String?
    var employeeId: String?
    var phone: String?
    var assignedYard: String?
    var defaultTruck: String?
    var defaultTrailer: String?
    var onUpdateContactInfo: (() -> Void)?
    var onContactSupervisor: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var requested = false
    @State private var contacting = false

    var body: some View {
        let t = theme ?? envTheme
        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Account")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Your details", testID: "account-details", theme: t) {
                FieldRow(label: "Name", value: hubValue(name), theme: t)
                FieldRow(label: "Role", value: hubValue(role), theme: t)
                FieldRow(label: "Employee ID", value: hubValue(employeeId), theme: t)
                FieldRow(label: "Phone", value: hubValue(phone), theme: t)
                FieldRow(label: "Assigned Yard", value: hubValue(assignedYard), theme: t)
                FieldRow(label: "Default Truck", value: hubValue(defaultTruck), theme: t)
                FieldRow(label: "Default Trailer", value: hubValue(defaultTrailer), theme: t)
            }

            Card(title: "Need a change?", theme: t) {
                Text(
                    "Your details come from the office. Ask to have them updated if anything here is wrong."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.textMuted)
                .lineSpacing(4)
                if onUpdateContactInfo != nil {
                    FieldButton(
                        label: "Update Contact Info", onPress: update, testID: "account-update", theme: t)
                    if requested {
                        FeedbackLine(text: "Update request started.", tone: .info, theme: t)
                    }
                }
                if onContactSupervisor != nil {
                    FieldButton(
                        label: "Contact Supervisor",
                        onPress: contact,
                        variant: .secondary,
                        testID: "account-supervisor",
                        theme: t
                    )
                    if contacting {
                        FeedbackLine(text: "Opening supervisor contact…", tone: .info, theme: t)
                    }
                }
                if onUpdateContactInfo == nil && onContactSupervisor == nil {
                    Text("Contact actions are unavailable until verified office contacts are provided by the Hub.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
            }
        }
        .padding(spacing.lg)
    }

    private func update() {
        requested = true
        onUpdateContactInfo?()
    }
    private func contact() {
        contacting = true
        onContactSupervisor?()
    }
}

/* ------------------------------------------------------------------ */
/* 77. Language                                                       */
/* ------------------------------------------------------------------ */

enum LanguageChoice: String {
    case en
    case es
    case device
}

private struct LanguageOption {
    var key: LanguageChoice
    var label: String
}

private let languageOptions: [LanguageOption] = [
    LanguageOption(key: .en, label: "English"),
    LanguageOption(key: .es, label: "Español"),
    LanguageOption(key: .device, label: "Use device language"),
]

struct LanguageScreen: View {
    var selected: LanguageChoice?
    var onSelect: (LanguageChoice) -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var selectedChoice: LanguageChoice

    init(selected: LanguageChoice? = nil, onSelect: @escaping (LanguageChoice) -> Void, theme: Theme? = nil) {
        self.selected = selected
        self.onSelect = onSelect
        self.theme = theme
        _selectedChoice = State(initialValue: selected ?? .en)
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Language")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "App language", theme: t) {
                ForEach(languageOptions, id: \.key) { opt in
                    OptionRow(
                        label: opt.label,
                        selected: opt.key == selectedChoice,
                        onPress: { choose(opt.key) },
                        testID: "language-\(opt.key.rawValue)",
                        theme: t
                    )
                }
            }

            Card(title: "About form languages", tone: .highlight, theme: t) {
                Text(
                    "Some forms may be English-only when no approved Spanish version exists. Your DVIR and JHA/JSA are available in English and Spanish; the field ticket is English-only for now."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                .lineSpacing(4)
            }
        }
        .padding(spacing.lg)
    }

    private func choose(_ key: LanguageChoice) {
        selectedChoice = key
        onSelect(key)
    }
}

/* ------------------------------------------------------------------ */
/* 78. Theme                                                          */
/* ------------------------------------------------------------------ */

private struct ThemeOption {
    var key: ThemeChoice
    var label: String
    var hint: String
}

private let themeOptions: [ThemeOption] = [
    ThemeOption(key: .system, label: "System", hint: "Match your phone settings"),
    ThemeOption(key: .light, label: "Light", hint: "Bright screen for daytime"),
    ThemeOption(key: .dark, label: "Dark", hint: "Dim screen for night work"),
]

/// Theme picker (More → Theme). The app-wide source of truth is persisted in Keychain; selecting an
/// option re-themes the full app immediately. `selected` and `onSelect` remain available to hosts and
/// tests that want to override or observe the choice.
struct ThemeScreen: View {
    var selected: ThemeChoice?
    var onSelect: ((ThemeChoice) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @Environment(\.fieldThemeChoice) private var themeChoice
    @State private var saveError: String?

    init(selected: ThemeChoice? = nil, onSelect: ((ThemeChoice) -> Void)? = nil, theme: Theme? = nil) {
        self.selected = selected
        self.onSelect = onSelect
        self.theme = theme
    }

    var body: some View {
        let t = theme ?? envTheme
        let selectedChoice = selected ?? themeChoice.choice

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Theme")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Appearance", theme: t) {
                ForEach(themeOptions, id: \.key) { opt in
                    OptionRow(
                        label: opt.label,
                        hint: opt.hint,
                        selected: opt.key == selectedChoice,
                        onPress: { choose(opt.key) },
                        testID: "theme-\(opt.key.rawValue)",
                        theme: t
                    )
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.danger)
                    .accessibilityIdentifier("theme-save-error")
            }
        }
        .padding(spacing.lg)
    }

    private func choose(_ key: ThemeChoice) {
        if themeChoice.setChoice(key) {
            saveError = nil
            onSelect?(key)
        } else {
            saveError = "Could not save the theme choice on this phone."
        }
    }
}

/* ------------------------------------------------------------------ */
/* 79. Text Size / Accessibility                                      */
/* ------------------------------------------------------------------ */

enum TextSizeChoice: String {
    case `default`
    case large
    case extraLarge = "extra-large"
}

private struct TextSizeOption {
    var key: TextSizeChoice
    var label: String
}

private let textSizeOptions: [TextSizeOption] = [
    TextSizeOption(key: .default, label: "Default"),
    TextSizeOption(key: .large, label: "Large"),
    TextSizeOption(key: .extraLarge, label: "Extra Large"),
]

private let accessibilityRules: [String] = [
    "Minimum touch target: 44 × 44 pt",
    "Preferred field action target: 52 × 52 pt",
    "No color-only status indicators",
    "Large labels for outdoor use",
]

struct TextSizeScreen: View {
    var selectedSize: TextSizeChoice?
    var highContrast: Bool?
    var reduceMotion: Bool?
    var onSelectSize: ((TextSizeChoice) -> Void)?
    var onToggleHighContrast: ((Bool) -> Void)?
    var onToggleReduceMotion: ((Bool) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var sizeChoice: TextSizeChoice
    @State private var highContrastOn: Bool
    @State private var reduceMotionOn: Bool

    private var controlsAvailable: Bool {
        onSelectSize != nil && onToggleHighContrast != nil && onToggleReduceMotion != nil
    }

    init(
        selectedSize: TextSizeChoice? = nil,
        highContrast: Bool? = nil,
        reduceMotion: Bool? = nil,
        onSelectSize: ((TextSizeChoice) -> Void)? = nil,
        onToggleHighContrast: ((Bool) -> Void)? = nil,
        onToggleReduceMotion: ((Bool) -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.selectedSize = selectedSize
        self.highContrast = highContrast
        self.reduceMotion = reduceMotion
        self.onSelectSize = onSelectSize
        self.onToggleHighContrast = onToggleHighContrast
        self.onToggleReduceMotion = onToggleReduceMotion
        self.theme = theme
        _sizeChoice = State(initialValue: selectedSize ?? .default)
        _highContrastOn = State(initialValue: highContrast ?? false)
        _reduceMotionOn = State(initialValue: reduceMotion ?? false)
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Text & Accessibility")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if controlsAvailable {
                Card(title: "Text size", theme: t) {
                    ForEach(textSizeOptions, id: \.key) { opt in
                        OptionRow(
                            label: opt.label,
                            selected: opt.key == sizeChoice,
                            onPress: { chooseSize(opt.key) },
                            testID: "textsize-\(opt.key.rawValue)",
                            theme: t
                        )
                    }
                }

                Card(title: "Accessibility", theme: t) {
                    ToggleRow(
                        label: "High Contrast",
                        hint: "Stronger borders and text",
                        value: highContrastOn,
                        onToggle: toggleHighContrast,
                        testID: "textsize-high-contrast",
                        theme: t
                    )
                    ToggleRow(
                        label: "Reduce Motion",
                        hint: "Limit animations",
                        value: reduceMotionOn,
                        onToggle: toggleReduceMotion,
                        testID: "textsize-reduce-motion",
                        theme: t
                    )
                }
            } else {
                Card(title: "Uses iPhone settings", tone: .highlight, theme: t) {
                    Text(
                        "Field Capture follows the text size set in iPhone Settings. App-specific contrast and motion overrides are not available in this build."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                }
            }

            Card(title: "How the app stays readable", tone: .highlight, theme: t) {
                ForEach(accessibilityRules, id: \.self) { rule in
                    Text("• \(rule)")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }
        }
        .padding(spacing.lg)
    }

    private func chooseSize(_ key: TextSizeChoice) {
        sizeChoice = key
        onSelectSize?(key)
    }
    private func toggleHighContrast(_ next: Bool) {
        highContrastOn = next
        onToggleHighContrast?(next)
    }
    private func toggleReduceMotion(_ next: Bool) {
        reduceMotionOn = next
        onToggleReduceMotion?(next)
    }
}

/// An on/off accessibility toggle rendered as an accessible switch row.
private struct ToggleRow: View {
    var label: String
    var hint: String? = nil
    var value: Bool
    var onToggle: (Bool) -> Void
    var testID: String? = nil
    var theme: Theme

    var body: some View {
        let t = theme
        Button(action: { onToggle(!value) }) {
            HStack(spacing: spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: typeScale.body, weight: .bold))
                        .foregroundStyle(t.text)
                    if let hint {
                        Text(hint)
                            .font(.system(size: typeScale.caption))
                            .foregroundStyle(t.textMuted)
                    }
                }
                Spacer()
                ZStack(alignment: value ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(value ? t.primary : t.border)
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(t.card)
                        .frame(width: 24, height: 24)
                        .padding(2)
                }
            }
            .padding(.horizontal, spacing.md)
            .padding(.vertical, spacing.sm)
            .frame(minHeight: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(value ? t.primary : t.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RowPressStyle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityValue(value ? "On" : "Off")
        .accessibilityIdentifier(ifPresent: testID)
    }
}

/* ------------------------------------------------------------------ */
/* 80. Printer Settings                                               */
/* ------------------------------------------------------------------ */

struct PrinterSettingsScreen: View {
    var printerName: String?
    var connected: Bool?
    var connectionMessage: String?
    /// Whether the test-page action is permitted for this driver/printer.
    var testPageAllowed: Bool?
    var reconnecting: Bool?
    var printing: Bool?
    var actionMessage: String?
    var actionTone: Tone?
    var onPrinterHelp: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onPrintTestPage: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    var body: some View {
        let t = theme ?? envTheme
        let printerName = self.printerName ?? "PT-210"
        let connected = self.connected ?? false
        let testPageAllowed = self.testPageAllowed ?? (onPrintTestPage != nil)
        let connectionMessage: String =
            self.connectionMessage
            ?? (connected
                ? "Your printer is connected and ready for field tickets."
                : "Printer not connected. Reconnect when you are near it to print field tickets.")
        let busy = (self.reconnecting ?? false) || (self.printing ?? false)
        let actionMessage = self.actionMessage
        let actionTone: Tone = self.actionTone ?? .info

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Printer")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Printer", testID: "printer-status", theme: t) {
                Text(printerName)
                    .font(.system(size: typeScale.heading, weight: .heavy))
                    .foregroundStyle(t.text)
                StatusBadge(
                    label: connected ? "Connected" : "Not Connected",
                    tone: connected ? .success : .warning,
                    testID: "printer-connection"
                )
                Text(connectionMessage)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }

            Card(title: "Actions", theme: t) {
                if let onPrinterHelp {
                    FieldButton(
                        label: "Printer Help",
                        onPress: onPrinterHelp,
                        variant: .secondary,
                        testID: "printer-help",
                        theme: t
                    )
                }
                if let onReconnect {
                    FieldButton(
                        label: "Reconnect Printer",
                        onPress: onReconnect,
                        disabled: busy,
                        testID: "printer-reconnect",
                        theme: t
                    )
                }
                if let actionMessage {
                    FeedbackLine(text: actionMessage, tone: actionTone, theme: t)
                }
                if let onPrintTestPage {
                    FieldButton(
                        label: "Print Test Page",
                        onPress: onPrintTestPage,
                        variant: .secondary,
                        disabled: !testPageAllowed || busy,
                        testID: "printer-test-page",
                        theme: t
                    )
                    if !testPageAllowed {
                        Text("Test page is not available for this printer.")
                            .font(.system(size: typeScale.caption))
                            .foregroundStyle(t.textMuted)
                    } else if !connected {
                        Text("Test page will reconnect first if needed.")
                            .font(.system(size: typeScale.caption))
                            .foregroundStyle(t.textMuted)
                    }
                }
                if onPrinterHelp == nil, onReconnect == nil, onPrintTestPage == nil {
                    Text("Printer actions are unavailable in this build.")
                        .font(.system(size: typeScale.caption))
                        .foregroundStyle(t.textMuted)
                }
            }

            Card(theme: t) {
                Text("Advanced printer diagnostics are kept in Admin Mode for supervisors and support.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.textMuted)
            }
        }
        .padding(spacing.lg)
    }

}

/* ------------------------------------------------------------------ */
/* 81. Help and Support                                               */
/* ------------------------------------------------------------------ */

struct HelpSupportScreen: View {
    /// Host-provided actions. Buttons are omitted when no verified destination/action is available.
    var onCallDispatch: (() -> Void)?
    var onCallSupervisor: (() -> Void)?
    var onReportAppProblem: (() -> Void)?
    var onViewSops: (() -> Void)?
    var onEmergencyContacts: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var feedback: (text: String, tone: Tone)?

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Help and Support")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Get help", theme: t) {
                if onCallDispatch != nil {
                    FieldButton(
                        label: "Call Dispatch", onPress: dispatchTapped, testID: "help-call-dispatch", theme: t)
                }
                if onCallSupervisor != nil {
                    FieldButton(
                        label: "Call Supervisor",
                        onPress: callSupervisor,
                        variant: .secondary,
                        testID: "help-call-supervisor",
                        theme: t
                    )
                }
                if onReportAppProblem != nil {
                    FieldButton(
                        label: "Report App Problem",
                        onPress: reportProblem,
                        variant: .secondary,
                        testID: "help-report-problem",
                        theme: t
                    )
                }
                if onViewSops != nil {
                    FieldButton(
                        label: "View SOPs",
                        onPress: viewSops,
                        variant: .secondary,
                        testID: "help-view-sops",
                        theme: t
                    )
                }
                if onCallDispatch == nil && onCallSupervisor == nil && onReportAppProblem == nil {
                    Text("Verified company contacts are unavailable. For an immediate emergency, call 911.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
                if let feedback {
                    FeedbackLine(text: feedback.text, tone: feedback.tone, theme: t)
                }
            }

            Card(title: "Emergency", tone: .highlight, theme: t) {
                Text(
                    "In an emergency, stop work and make the area safe first. Use only verified contacts; call 911 for immediate help."
                )
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.text)
                if onEmergencyContacts != nil {
                    FieldButton(
                        label: "Emergency Contacts",
                        onPress: emergency,
                        variant: .destructive,
                        testID: "help-emergency-contacts",
                        theme: t
                    )
                }
            }
        }
        .padding(spacing.lg)
    }

    private func dispatchTapped() {
        feedback = (text: "Opening dispatch contact…", tone: .info)
        onCallDispatch?()
    }
    private func callSupervisor() {
        feedback = (text: "Opening supervisor contact…", tone: .info)
        onCallSupervisor?()
    }
    private func reportProblem() {
        feedback = (text: "Opening problem report…", tone: .info)
        onReportAppProblem?()
    }
    private func viewSops() {
        feedback = (text: "Opening SOPs…", tone: .info)
        onViewSops?()
    }
    private func emergency() {
        feedback = (text: "Opening emergency contacts…", tone: .danger)
        onEmergencyContacts?()
    }
}

/* ------------------------------------------------------------------ */
/* 82. Contact Dispatch                                               */
/* ------------------------------------------------------------------ */

struct ContactEntry {
    var key: String
    /// Driver-facing role label, e.g. "Dispatch", "Office", "Supervisor".
    var role: String
    var name: String?
    var phone: String?
}

/// Strip a display phone down to a dialable string.
private func dialable(_ phone: String?) -> String? {
    guard let phone else { return nil }
    let digits = phone.filter { $0.isNumber || $0 == "+" }
    return digits.isEmpty ? nil : digits
}

struct ContactDispatchScreen: View {
    var contacts: [ContactEntry]?
    /// Optional observers — the screen itself dials/messages via the OS, these just notify the host.
    var onCall: ((String) -> Void)?
    var onMessage: ((String) -> Void)?
    var onSendJobLocation: ((String) -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    /// Per-contact inline confirmation, keyed by contact key.
    @State private var feedback: [String: (text: String, tone: Tone)] = [:]

    private var resolvedContacts: [ContactEntry] {
        contacts ?? []
    }

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Contact Dispatch")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            if resolvedContacts.isEmpty {
                Card(title: "Contacts unavailable", tone: .highlight, testID: "contacts-unavailable", theme: t) {
                    Text("The Hub has not provided verified company contacts. For an immediate emergency, call 911.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                }
            }

            ForEach(resolvedContacts, id: \.key) { c in
                let emergency = c.key == "emergency"
                let line = feedback[c.key]
                Card(title: c.role, tone: emergency ? .highlight : .default, testID: "contact-\(c.key)", theme: t) {
                    if let name = c.name {
                        Text(name)
                            .font(.system(size: typeScale.body, weight: .semibold))
                            .foregroundStyle(t.text)
                    }
                    if let phone = c.phone {
                        Text(phone)
                            .font(.system(size: typeScale.body))
                            .foregroundStyle(t.textMuted)
                    }
                    if phoneFor(c.key) != nil {
                        FieldButton(
                            label: "Call",
                            onPress: { call(c.key) },
                            variant: emergency ? .destructive : .primary,
                            testID: "contact-call-\(c.key)",
                            theme: t
                        )
                        FieldButton(
                            label: "Message",
                            onPress: { message(c.key) },
                            variant: .secondary,
                            testID: "contact-message-\(c.key)",
                            theme: t
                        )
                    }
                    if onSendJobLocation != nil {
                        FieldButton(
                            label: "Send Job Location",
                            onPress: { sendLocation(c.key) },
                            variant: .secondary,
                            testID: "contact-location-\(c.key)",
                            theme: t
                        )
                    }
                    if let line {
                        FeedbackLine(text: line.text, tone: line.tone, theme: t)
                    }
                }
            }
        }
        .padding(spacing.lg)
    }

    private func setLine(_ key: String, _ text: String, _ tone: Tone) {
        feedback[key] = (text: text, tone: tone)
    }

    private func phoneFor(_ key: String) -> String? {
        dialable(resolvedContacts.first(where: { $0.key == key })?.phone)
    }

    private func call(_ key: String) {
        guard let num = phoneFor(key) else {
            setLine(key, "No phone number on file.", .warning)
            return
        }
        setLine(key, "Calling…", .info)
        openURL("tel:\(num)") { setLine(key, "Could not start the call.", .warning) }
        onCall?(key)
    }
    private func message(_ key: String) {
        guard let num = phoneFor(key) else {
            setLine(key, "No phone number on file.", .warning)
            return
        }
        setLine(key, "Opening a message…", .info)
        openURL("sms:\(num)") { setLine(key, "Could not open messages.", .warning) }
        onMessage?(key)
    }
    private func sendLocation(_ key: String) {
        guard let num = phoneFor(key) else {
            setLine(key, "No phone number on file.", .warning)
            return
        }
        setLine(key, "Opening a message with your job location…", .info)
        let body = "My current job location: ".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openURL("sms:\(num)?body=\(body)") { setLine(key, "Could not open messages.", .warning) }
        onSendJobLocation?(key)
    }
}

/* ------------------------------------------------------------------ */
/* 83. Sign Out Confirmation                                          */
/* ------------------------------------------------------------------ */

struct SignOutConfirmScreen: View {
    /// When true, the screen warns the driver they are still on the clock.
    var punchedIn: Bool?
    var onCancel: () -> Void
    var onConfirmSignOut: () async throws -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let t = theme ?? envTheme
        let punchedIn = self.punchedIn ?? false

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Sign out?")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)

            Card(title: "Sign out of the app", tone: .highlight, testID: "signout-confirm", theme: t) {
                Text("This only signs you out of the app. It does not punch you out.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                Text("Saved work will stay on this phone.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            if punchedIn {
                Card(testID: "signout-punch-warning", theme: t) {
                    StatusBadge(label: "Punched In", tone: .warning)
                    Text(
                        "You are still punched in. Punch out from the Day screen when your workday is complete."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: typeScale.label, weight: .semibold))
                    .foregroundStyle(t.danger)
                    .accessibilityIdentifier("signout-error")
            }

            VStack(spacing: spacing.sm) {
                FieldButton(
                    label: "Cancel",
                    onPress: onCancel,
                    variant: .secondary,
                    disabled: busy,
                    testID: "signout-cancel",
                    theme: t
                )
                FieldButton(
                    label: busy ? "Signing Out…" : "Sign Out",
                    onPress: confirm,
                    variant: .destructive,
                    disabled: busy,
                    testID: "signout-confirm-action",
                    theme: t
                )
            }
        }
        .padding(spacing.lg)
    }

    private func confirm() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                try await onConfirmSignOut()
            } catch {
                busy = false
                errorMessage = "Could not sign out securely on this phone. Try again."
            }
        }
    }
}
