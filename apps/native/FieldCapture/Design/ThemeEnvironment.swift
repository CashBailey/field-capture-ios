//
//  ThemeEnvironment.swift
//  Ported from apps/mobile/src/design/ThemeContext.tsx
//
//  App-wide theme access — makes the light/dark choice real and reactive. Views read the resolved
//  Theme from `@Environment(\.fieldTheme)` (the `useTheme` equivalent) instead of a static import,
//  so a system appearance or More -> Theme choice re-renders the whole app. The explicit choice is
//  stored under the same Keychain service/account as the React Native app so an in-place upgrade
//  preserves the driver's preference.
//

import Security
import SwiftUI

enum ThemeChoice: String {
    case system
    case light
    case dark
}

struct ThemeChoiceContext {
    var choice: ThemeChoice
    var setChoice: (ThemeChoice) -> Bool
}

private enum ThemeChoiceStore {
    static let service = "field.themeChoice"
    static let account = "fieldcapture"

    static func load() -> ThemeChoice {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let rawValue = String(data: data, encoding: .utf8),
            let choice = ThemeChoice(rawValue: rawValue)
        else { return .system }
        return choice
    }

    static func save(_ choice: ThemeChoice) -> Bool {
        let data = Data(choice.rawValue.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = baseQuery
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct FieldThemeKey: EnvironmentKey {
    /// Default when no provider is mounted (e.g. previews/tests) — same fallback as the TS context.
    static let defaultValue: Theme = lightTheme
}

private struct FieldThemeChoiceKey: EnvironmentKey {
    static let defaultValue = ThemeChoiceContext(choice: .system, setChoice: { _ in false })
}

extension EnvironmentValues {
    /// The resolved theme to render with — the `useTheme()` equivalent.
    var fieldTheme: Theme {
        get { self[FieldThemeKey.self] }
        set { self[FieldThemeKey.self] = newValue }
    }

    var fieldThemeChoice: ThemeChoiceContext {
        get { self[FieldThemeChoiceKey.self] }
        set { self[FieldThemeChoiceKey.self] = newValue }
    }
}

/// Appearance can report `.unspecified` — treat anything not explicitly dark as light, same as the
/// TS `normalizeScheme`.
private func resolvedTheme(for choice: ThemeChoice, system colorScheme: ColorScheme) -> Theme {
    switch choice {
    case .system:
        return colorScheme == .dark ? darkTheme : lightTheme
    case .light:
        return lightTheme
    case .dark:
        return darkTheme
    }
}

private struct FieldThemeProviderModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var choice = ThemeChoiceStore.load()

    private var preferredColorScheme: ColorScheme? {
        switch choice {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func body(content: Content) -> some View {
        let currentTheme = resolvedTheme(for: choice, system: colorScheme)
        content
            .environment(\.fieldTheme, currentTheme)
            .environment(
                \.fieldThemeChoice,
                ThemeChoiceContext(choice: choice, setChoice: setChoice)
            )
            .tint(currentTheme.primary)
            .preferredColorScheme(preferredColorScheme)
    }

    private func setChoice(_ nextChoice: ThemeChoice) -> Bool {
        guard ThemeChoiceStore.save(nextChoice) else { return false }
        choice = nextChoice
        return true
    }
}

extension View {
    /// The `ThemeProvider`-equivalent: resolves light/dark from the system color scheme and makes it
    /// available to descendants via `@Environment(\.fieldTheme)`. Mount once near the app root.
    func fieldThemeProvider() -> some View {
        modifier(FieldThemeProviderModifier())
    }
}
