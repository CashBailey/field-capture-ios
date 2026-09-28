// Port of src/runtime/foregroundSync.ts — Foreground sync trigger (ADR-004 follow-up): kick a sync
// pass whenever the app returns to the foreground. Returning to foreground is the moment
// connectivity has usually just come back (and the OS may have throttled the background timer), so
// a prompt sweep drains backed-off evidence without waiting out the periodic interval.
//
// Kept UIKit-agnostic (the `AppStateLike` seam) so the transition logic is unit-tested without
// mounting the app or observing the real notification center. The App target wires the real
// `UIApplication` foreground notifications to `AppController.notifyQueuedSync` (which no-ops while
// paused-for-auth — a dead token is never hammered on foreground).

/// A subscription handle: call `remove()` to stop observing.
public struct AppStateSubscription {
    public let remove: () -> Void
    public init(remove: @escaping () -> Void) {
        self.remove = remove
    }
}

/// The slice of the platform's foreground/background notifications this needs (subset, so it is
/// trivially fakeable). Mirrors the TS `AppStateLike` seam — `addEventListener('change', handler)`.
public protocol AppStateLike {
    func addEventListener(_ handler: @escaping (String) -> Void) -> AppStateSubscription
}

/// Fire `onForeground` on each transition INTO the foreground (`"active"`) from a non-active state.
/// The current state at subscribe time is the baseline, so subscribing while already active does
/// NOT fire. Returns an unsubscribe closure.
public func subscribeForegroundSync(
    _ appState: AppStateLike, _ onForeground: @escaping () -> Void, _ currentState: String
) -> () -> Void {
    var previous = currentState
    let subscription = appState.addEventListener { next in
        // Only a real background/inactive -> active transition counts; ignore active->active and
        // the intermediate active->inactive/background steps iOS emits when leaving the foreground.
        if next == "active" && previous != "active" { onForeground() }
        previous = next
    }
    return { subscription.remove() }
}
