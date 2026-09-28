/**
 * Foreground sync trigger (ADR-004 follow-up): kick a sync pass whenever the app returns to the
 * foreground. Returning to foreground is the moment connectivity has usually just come back (and
 * RN may have throttled the background timer), so a prompt sweep drains backed-off evidence
 * without waiting out the periodic interval.
 *
 * Kept RN-agnostic (the `AppStateLike` seam) so the transition logic is unit-tested without
 * mounting the app or mocking the native module. `App.tsx` wires the real `AppState` to
 * `AppController.notifyQueuedSync` (which no-ops while paused-for-auth — a dead token is never
 * hammered on foreground).
 */

/** The slice of React Native's `AppState` this needs (subset, so it is trivially fakeable). */
export interface AppStateLike {
  addEventListener: (type: 'change', handler: (state: string) => void) => { remove: () => void };
}

/**
 * Fire `onForeground` on each transition INTO the foreground (`'active'`) from a non-active state.
 * The current state at subscribe time is the baseline, so mounting while already active does NOT
 * fire. Returns an unsubscribe.
 */
export function subscribeForegroundSync(
  appState: AppStateLike,
  onForeground: () => void,
  currentState: string,
): () => void {
  let previous = currentState;
  const subscription = appState.addEventListener('change', (next) => {
    // Only a real background/inactive -> active transition counts; ignore active->active and the
    // intermediate active->inactive/background steps iOS emits when leaving the foreground.
    if (next === 'active' && previous !== 'active') onForeground();
    previous = next;
  });
  return () => subscription.remove();
}
