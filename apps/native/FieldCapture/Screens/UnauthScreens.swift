//
//  UnauthScreens.swift
//  Ported from apps/mobile/src/screens/UnauthScreens.tsx
//
//  Unauth / pre-session screens (GUI Master §5 / screens 3-6) — the flows a driver hits before a
//  live session exists. All four are driver-facing and reassuring: nothing here exposes server
//  configuration, Hub URLs, version hashes, or storage internals (GUI Master §20). The recurring
//  promise across these screens is "your saved work on this phone is safe."
//
//    3. Sign-In Help            -> SignInHelpScreen          (recover access without tech clutter)
//    4. Offline Saved Work      -> OfflineSavedWorkScreen    (reassure when connection is down)
//    5. First-Run Permissions   -> FirstRunPermissionsScreen (ask per-permission, with a plain "why")
//    6. Session Expired         -> SessionExpiredScreen      (re-auth without fear of data loss)
//
//  Presentational + props-driven only: no domain/runtime/data types. The real call dispatcher,
//  OS permission prompts, connectivity checks, and re-auth are wired by the caller via callbacks.
//
//  Every interactive control is SELF-MANAGING: it seeds local state from its optional prop (if any),
//  renders its selected/active styling FROM that local state, and on press updates the local state
//  (so it re-renders) AND still calls the matching optional callback. Required nav callbacks
//  (onContinue, onFinish, onSignInAgain, onBack, etc.) drive the app and are never swallowed.
//  Scrolling is owned by the app shell — each screen's outermost element is a plain container.
//

import SwiftUI

/* -------------------------------------------------------------------------- */
/* 3. Sign-In Help (GUI Master §5 / screen 3)                                 */
/* Help the driver recover access without technical clutter. Server           */
/* configuration stays hidden unless Admin Mode is unlocked, which this       */
/* presentational screen treats as a simple boolean.                         */
/* -------------------------------------------------------------------------- */

struct SignInHelpScreen: View {
    /// Display name/number dispatch is reached at — driver-facing only, no routing internals.
    var dispatchName: String = "Dispatch"
    var supervisorName: String = "Your supervisor"
    /// Whether the "use last signed-in driver" shortcut is permitted by policy.
    var lastDriverAllowed: Bool = false
    var lastDriverName: String = "the last signed-in driver"
    /// Admin Mode gate — only then may server-config recovery be offered (GUI Master §3).
    var adminUnlocked: Bool = false
    var onCallDispatch: (() -> Void)?
    var onCallSupervisor: (() -> Void)?
    var onUseLastDriver: (() -> Void)?
    var onServerSettings: (() -> Void)?
    var onBack: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    /// Placing a call is wired by the caller; the inline line gives instant on-tap feedback so the
    /// driver sees the tap landed even before the OS dialer takes over.
    private enum CallTarget: Equatable {
        case none, dispatch, supervisor
    }
    @State private var calling: CallTarget = .none

    var body: some View {
        let t = theme ?? envTheme

        VStack(alignment: .leading, spacing: spacing.md) {
            Text("Need help signing in?")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Reach a person who can get you back to work. Your saved work on this phone stays safe.")
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            Card(title: "Get a hand", theme: t) {
                if let onCallDispatch {
                    FieldButton(
                        label: "Call \(dispatchName)",
                        onPress: {
                            calling = .dispatch
                            onCallDispatch()
                        },
                        testID: "help-call-dispatch",
                        theme: t
                    )
                }
                if let onCallSupervisor {
                    FieldButton(
                        label: "Call \(supervisorName)",
                        onPress: {
                            calling = .supervisor
                            onCallSupervisor()
                        },
                        variant: .secondary,
                        testID: "help-call-supervisor",
                        theme: t
                    )
                }
                if onCallDispatch == nil && onCallSupervisor == nil {
                    Text(
                        "Verified company contacts are unavailable on this phone. For an immediate emergency, call 911."
                    )
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                    .accessibilityIdentifier("help-contacts-unavailable")
                }
                if calling != .none {
                    Text(calling == .dispatch ? "Calling \(dispatchName)…" : "Calling \(supervisorName)…")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("help-call-status")
                }
            }

            if lastDriverAllowed, let onUseLastDriver {
                Card(title: "On a shared phone?", theme: t) {
                    Text("You can continue as \(lastDriverName) if that is still you.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    FieldButton(
                        label: "Use last signed-in driver",
                        onPress: onUseLastDriver,
                        variant: .secondary,
                        testID: "help-use-last-driver",
                        theme: t
                    )
                }
            }

            if adminUnlocked, let onServerSettings {
                Card(title: "Admin", theme: t) {
                    Text("Connection settings are available because Admin Mode is unlocked on this device.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                    FieldButton(
                        label: "Open connection settings",
                        onPress: onServerSettings,
                        variant: .secondary,
                        testID: "help-server-settings",
                        theme: t
                    )
                }
            }

            FieldButton(
                label: "Back to sign in",
                onPress: onBack,
                variant: .secondary,
                testID: "help-back",
                theme: t
            )
        }
        .padding(spacing.lg)
    }
}

/* -------------------------------------------------------------------------- */
/* 4. Offline Saved Work Notice (GUI Master §5 / screen 4)                    */
/* Reassure the driver when a connection is unavailable: the work on the      */
/* phone is safe; only NEW assignments need a connection.                     */
/* -------------------------------------------------------------------------- */

struct OfflineSavedWorkScreen: View {
    /// Count of jobs/tickets held safely on this phone — purely informational.
    var savedItemCount: Int = 0
    var onContinue: () -> Void
    var onRetry: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    /// Self-managing "retrying": tapping Retry flips local state so the button visibly shows it's
    /// working, then still calls the caller's onRetry so the real connectivity check runs.
    @State private var retrying: Bool

    init(
        savedItemCount: Int = 0,
        retrying: Bool = false,
        onContinue: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.savedItemCount = savedItemCount
        self.onContinue = onContinue
        self.onRetry = onRetry
        self.theme = theme
        _retrying = State(initialValue: retrying)
    }

    var body: some View {
        let t = theme ?? envTheme
        let savedLine =
            savedItemCount > 0
            ? "\(savedItemCount) item\(savedItemCount == 1 ? "" : "s") saved on this phone — all safe."
            : "Saved work on this phone is safe."

        VStack(spacing: spacing.md) {
            Logo(size: 72, ring: true, testID: "offline-logo")
            StatusBadge(label: "Offline Mode", tone: .warning, testID: "offline-badge")
            Text("You’re offline")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
                .multilineTextAlignment(.center)

            Card(tone: .highlight, theme: t) {
                Text(savedLine)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                Text("New assignments may require a connection, so a few may not appear until you’re back online.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            VStack(spacing: spacing.sm) {
                FieldButton(
                    label: "Continue to saved work",
                    onPress: onContinue,
                    testID: "offline-continue",
                    theme: t
                )
                FieldButton(
                    label: retrying ? "Trying connection…" : "Try connection again",
                    onPress: {
                        retrying = true
                        onRetry()
                    },
                    variant: .secondary,
                    disabled: retrying,
                    testID: "offline-retry",
                    theme: t
                )
                if retrying {
                    Text("Checking for a connection…")
                        .font(.system(size: typeScale.label, weight: .bold))
                        .foregroundStyle(t.success)
                        .accessibilityIdentifier("offline-retry-status")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(spacing.lg)
    }
}

/* -------------------------------------------------------------------------- */
/* 5. First-Run Permissions (GUI Master §5 / screen 5)                        */
/* Ask for permissions only when needed, one page at a time, each explaining  */
/* WHY in driver terms. No "backend validation" framing — language is about   */
/* confirming arrival and capturing job evidence. The actual OS prompt is     */
/* fired by the caller through onAllow.                                       */
/* -------------------------------------------------------------------------- */

enum PermissionKey: String {
    case location
    case camera
    case photos
    case bluetooth
    case notifications
}

enum PermissionState: String {
    case pending
    case granted
    case skipped
}

struct PermissionPage {
    var key: PermissionKey
    var title: String
    /// Plain-English reason this permission helps the driver do the job.
    var why: String
    /// Whether the page may be skipped ("Not Now") — required permissions hide that option.
    var optional: Bool?
}

/// Default page set + driver-facing reasons (GUI Master §5 screen 5 examples).
private let defaultPermissionPages: [PermissionPage] = [
    PermissionPage(
        key: .location,
        title: "Location Access",
        why: "Location helps confirm arrival and job evidence.",
        optional: true
    ),
    PermissionPage(
        key: .camera,
        title: "Camera Access",
        why: "The camera lets you photograph the load, the site, and job evidence.",
        optional: true
    ),
    PermissionPage(
        key: .photos,
        title: "Photo Library Access",
        why: "Photo access lets you attach pictures you’ve already taken to a job.",
        optional: true
    ),
    PermissionPage(
        key: .bluetooth,
        title: "Bluetooth / Printer Access",
        why: "Bluetooth lets you print field tickets and receipts to a nearby printer.",
        optional: true
    ),
    PermissionPage(
        key: .notifications,
        title: "Notifications",
        why: "Notifications let dispatch reach you about new assignments and reminders.",
        optional: true
    ),
]

private let permissionBadge: [PermissionState: (label: String, tone: Tone)] = [
    .pending: (label: "Not Started", tone: .neutral),
    .granted: (label: "Synced", tone: .success),
    .skipped: (label: "Not Started", tone: .neutral),
]

struct FirstRunPermissionsScreen: View {
    /// Optional override of the page set/order; falls back to the canonical five.
    var pages: [PermissionPage] = defaultPermissionPages
    /// Zero-based index of the page currently shown.
    var index: Int?
    var onAllow: ((PermissionKey) -> Void)?
    var onSkip: ((PermissionKey) -> Void)?
    var onBack: (() -> Void)?
    /// Called when the last page is dismissed (allow/skip on the final permission).
    var onFinish: () -> Void
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    @State private var internalIndex: Int = 0
    /// Per-permission outcome is self-managing: seed from the optional `states` prop, then update on
    /// Allow/Skip so the status badge for this permission visibly flips ("Not Started" -> "Synced").
    @State private var internalStates: [PermissionKey: PermissionState]

    init(
        pages: [PermissionPage] = defaultPermissionPages,
        index: Int? = nil,
        states: [PermissionKey: PermissionState] = [:],
        onAllow: ((PermissionKey) -> Void)? = nil,
        onSkip: ((PermissionKey) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onFinish: @escaping () -> Void,
        theme: Theme? = nil
    ) {
        self.pages = pages
        self.index = index
        self.onAllow = onAllow
        self.onSkip = onSkip
        self.onBack = onBack
        self.onFinish = onFinish
        self.theme = theme
        _internalStates = State(initialValue: states)
    }

    var body: some View {
        let t = theme ?? envTheme
        let resolvedIndex = index ?? internalIndex
        let clampedIndex = min(resolvedIndex, pages.count - 1)
        let page: PermissionPage? = pages.indices.contains(clampedIndex) ? pages[clampedIndex] : nil

        if let page {
            let state = internalStates[page.key] ?? .pending
            let isOptional = page.optional ?? true
            let isLast = resolvedIndex >= pages.count - 1
            let step = resolvedIndex + 1

            let advance: () -> Void = {
                if index == nil {
                    internalIndex += 1
                }
                if isLast {
                    onFinish()
                }
            }
            let record: (PermissionKey, PermissionState) -> Void = { key, outcome in
                internalStates[key] = outcome
            }

            VStack(alignment: .leading, spacing: spacing.md) {
                HStack {
                    Text("Step \(step) of \(pages.count)")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                    Spacer()
                    StatusBadge(
                        label: permissionBadge[state]?.label ?? "",
                        tone: permissionBadge[state]?.tone ?? .neutral,
                        testID: "perm-state"
                    )
                }

                Text(page.title)
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)

                Card(tone: .highlight, testID: "perm-card-\(page.key.rawValue)", theme: t) {
                    Text(page.why)
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.text)
                    Text("You can change this later in Settings. We only ask when it helps you do the job.")
                        .font(.system(size: typeScale.body))
                        .foregroundStyle(t.textMuted)
                }

                FieldButton(
                    label: "Allow",
                    onPress: {
                        record(page.key, .granted)
                        onAllow?(page.key)
                        advance()
                    },
                    testID: "perm-allow",
                    theme: t
                )
                if isOptional {
                    FieldButton(
                        label: "Not now",
                        onPress: {
                            record(page.key, .skipped)
                            onSkip?(page.key)
                            advance()
                        },
                        variant: .secondary,
                        testID: "perm-skip",
                        theme: t
                    )
                } else {
                    Text("This permission is required to continue.")
                        .font(.system(size: typeScale.label))
                        .foregroundStyle(t.textMuted)
                }
                if resolvedIndex > 0, let onBack {
                    FieldButton(
                        label: "Back",
                        onPress: {
                            if index == nil {
                                internalIndex = max(0, internalIndex - 1)
                            }
                            onBack()
                        },
                        variant: .secondary,
                        testID: "perm-back",
                        theme: t
                    )
                }
            }
            .padding(spacing.lg)
        } else {
            VStack(spacing: spacing.md) {
                Text("You’re all set")
                    .font(.system(size: typeScale.title, weight: .heavy))
                    .foregroundStyle(t.text)
                    .multilineTextAlignment(.center)
                FieldButton(label: "Continue", onPress: onFinish, testID: "perm-finish", theme: t)
            }
            .padding(spacing.lg)
        }
    }
}

/* -------------------------------------------------------------------------- */
/* 6. Session Expired (GUI Master §5 / screen 6)                              */
/* Let the driver re-authenticate without fear of data loss. The headline     */
/* reassurance: saved work remains on the phone; signing in again just       */
/* continues.                                                                 */
/* -------------------------------------------------------------------------- */

struct SessionExpiredScreen: View {
    /// Driver name to greet, if known — keeps the prompt human.
    var driverName: String?
    /// Count of items held safely on this phone, surfaced as reassurance.
    var savedItemCount: Int = 0
    var onSignInAgain: () -> Void
    var onGetHelp: (() -> Void)?
    var theme: Theme?

    @Environment(\.fieldTheme) private var envTheme

    /// Self-managing "signingIn": tapping Sign In Again flips local state so the button visibly
    /// shows it's working, then still calls the caller's onSignInAgain to run the real re-auth.
    @State private var signingIn: Bool

    init(
        driverName: String? = nil,
        savedItemCount: Int = 0,
        signingIn: Bool = false,
        onSignInAgain: @escaping () -> Void,
        onGetHelp: (() -> Void)? = nil,
        theme: Theme? = nil
    ) {
        self.driverName = driverName
        self.savedItemCount = savedItemCount
        self.onSignInAgain = onSignInAgain
        self.onGetHelp = onGetHelp
        self.theme = theme
        _signingIn = State(initialValue: signingIn)
    }

    var body: some View {
        let t = theme ?? envTheme
        let greeting = driverName.map { "Welcome back, \($0)." } ?? "Welcome back."
        let savedLine =
            savedItemCount > 0
            ? "Your \(savedItemCount) saved item\(savedItemCount == 1 ? "" : "s") remain\(savedItemCount == 1 ? "s" : "") on this phone."
            : "Saved work remains on this phone."

        VStack(spacing: spacing.md) {
            Logo(size: 72, ring: true, testID: "expired-logo")
            StatusBadge(label: "Locked", tone: .warning, testID: "expired-badge")
            Text("Session expired")
                .font(.system(size: typeScale.title, weight: .heavy))
                .foregroundStyle(t.text)
                .multilineTextAlignment(.center)
            Text(greeting)
                .font(.system(size: typeScale.body))
                .foregroundStyle(t.textMuted)
                .multilineTextAlignment(.center)

            Card(tone: .highlight, theme: t) {
                Text(savedLine)
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
                Text("Sign in again to continue.")
                    .font(.system(size: typeScale.body))
                    .foregroundStyle(t.text)
            }

            VStack(spacing: spacing.sm) {
                FieldButton(
                    label: signingIn ? "Signing in…" : "Sign In Again",
                    onPress: {
                        signingIn = true
                        onSignInAgain()
                    },
                    disabled: signingIn,
                    testID: "expired-sign-in",
                    theme: t
                )
                if let onGetHelp {
                    FieldButton(
                        label: "Help signing in",
                        onPress: onGetHelp,
                        variant: .secondary,
                        testID: "expired-help",
                        theme: t
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(spacing.lg)
    }
}
