/**
 * Unauth / pre-session screens (GUI Master §5 / screens 3–6) — the flows a driver hits before a
 * live session exists. All four are driver-facing and reassuring: nothing here exposes server
 * configuration, Hub URLs, version hashes, or storage internals (GUI Master §20). The recurring
 * promise across these screens is "your saved work on this phone is safe."
 *
 *   3. Sign-In Help            → SignInHelpScreen          (recover access without tech clutter)
 *   4. Offline Saved Work      → OfflineSavedWorkScreen    (reassure when connection is down)
 *   5. First-Run Permissions   → FirstRunPermissionsScreen (ask per-permission, with a plain "why")
 *   6. Session Expired         → SessionExpiredScreen      (re-auth without fear of data loss)
 *
 * Presentational + props-driven only: no domain/runtime/data imports. The real call dispatcher,
 * OS permission prompts, connectivity checks, and re-auth are wired by the caller via callbacks.
 *
 * Every interactive control is SELF-MANAGING: it seeds local state from its optional prop (if any),
 * renders its selected/active styling FROM that local state, and on press updates the local state
 * (so it re-renders) AND still calls the matching optional callback. Required nav callbacks
 * (onContinue, onFinish, onSignInAgain, onBack, etc.) drive the app and are never swallowed.
 * Scrolling is owned by the app shell — each screen's outermost element is a plain View.
 */
import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  Logo,
  StatusBadge,
  spacing,
  useResolvedTheme,
  typeScale,
  type Theme,
} from '../design';
import { callDispatch as dialDispatch, callNumber, SUPERVISOR_PHONE } from '../config/contacts';

/* ------------------------------------------------------------------------------------------------
 * 3. Sign-In Help (GUI Master §5 / screen 3)
 * Help the driver recover access without technical clutter. Server configuration stays hidden
 * unless Admin Mode is unlocked, which this presentational screen treats as a simple boolean.
 * ---------------------------------------------------------------------------------------------- */

export function SignInHelpScreen(props: {
  /** Display name/number dispatch is reached at — driver-facing only, no routing internals. */
  dispatchName?: string;
  supervisorName?: string;
  /** Whether the "use last signed-in driver" shortcut is permitted by policy. */
  lastDriverAllowed?: boolean;
  lastDriverName?: string;
  /** Admin Mode gate — only then may server-config recovery be offered (GUI Master §3). */
  adminUnlocked?: boolean;
  onCallDispatch?: () => void;
  onCallSupervisor?: () => void;
  onUseLastDriver?: () => void;
  onServerSettings?: () => void;
  onBack: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const dispatchName = props.dispatchName ?? 'Dispatch';
  const supervisorName = props.supervisorName ?? 'Your supervisor';
  const lastDriverAllowed = props.lastDriverAllowed ?? false;
  const lastDriverName = props.lastDriverName ?? 'the last signed-in driver';
  const adminUnlocked = props.adminUnlocked ?? false;

  // Placing a call is wired by the caller; the inline line gives instant on-tap feedback so the
  // driver sees the tap landed even before the OS dialer takes over.
  const [calling, setCalling] = useState<'none' | 'dispatch' | 'supervisor'>('none');

  return (
    <View style={styles.body}>
      <Text style={[styles.h1, { color: t.text }]}>Need help signing in?</Text>
      <Text style={[styles.lede, { color: t.textMuted }]}>
        Reach a person who can get you back to work. Your saved work on this phone stays safe.
      </Text>

      <Card theme={t} title="Get a hand">
        <Button
          theme={t}
          label={`Call ${dispatchName}`}
          onPress={() => {
            setCalling('dispatch');
            dialDispatch();
            props.onCallDispatch?.();
          }}
          testID="help-call-dispatch"
        />
        <Button
          theme={t}
          variant="secondary"
          label={`Call ${supervisorName}`}
          onPress={() => {
            setCalling('supervisor');
            callNumber(SUPERVISOR_PHONE);
            props.onCallSupervisor?.();
          }}
          testID="help-call-supervisor"
        />
        {calling !== 'none' ? (
          <Text style={[styles.confirm, { color: t.success }]} testID="help-call-status">
            {calling === 'dispatch' ? `Calling ${dispatchName}…` : `Calling ${supervisorName}…`}
          </Text>
        ) : null}
      </Card>

      {lastDriverAllowed && props.onUseLastDriver !== undefined ? (
        <Card theme={t} title="On a shared phone?">
          <Text style={[styles.body2, { color: t.text }]}>
            You can continue as {lastDriverName} if that is still you.
          </Text>
          <Button
            theme={t}
            variant="secondary"
            label="Use last signed-in driver"
            onPress={props.onUseLastDriver}
            testID="help-use-last-driver"
          />
        </Card>
      ) : null}

      {adminUnlocked && props.onServerSettings !== undefined ? (
        <Card theme={t} title="Admin">
          <Text style={[styles.body2, { color: t.textMuted }]}>
            Connection settings are available because Admin Mode is unlocked on this device.
          </Text>
          <Button
            theme={t}
            variant="secondary"
            label="Open connection settings"
            onPress={props.onServerSettings}
            testID="help-server-settings"
          />
        </Card>
      ) : null}

      <Button
        theme={t}
        variant="secondary"
        label="Back to sign in"
        onPress={props.onBack}
        testID="help-back"
      />
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------
 * 4. Offline Saved Work Notice (GUI Master §5 / screen 4)
 * Reassure the driver when a connection is unavailable: the work on the phone is safe; only NEW
 * assignments need a connection.
 * ---------------------------------------------------------------------------------------------- */

export function OfflineSavedWorkScreen(props: {
  /** Count of jobs/tickets held safely on this phone — purely informational. */
  savedItemCount?: number;
  /** True while a fresh connection attempt is in flight (button shows a working label). */
  retrying?: boolean;
  onContinue: () => void;
  onRetry: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const savedItemCount = props.savedItemCount ?? 0;

  // Self-managing "retrying": tapping Retry flips local state so the button visibly shows it's
  // working, then still calls the caller's onRetry so the real connectivity check runs.
  const [retrying, setRetrying] = useState(props.retrying ?? false);

  const savedLine =
    savedItemCount > 0
      ? `${savedItemCount} item${savedItemCount === 1 ? '' : 's'} saved on this phone — all safe.`
      : 'Saved work on this phone is safe.';

  return (
    <View style={styles.bodyCentered}>
      <Logo size={72} ring testID="offline-logo" />
      <StatusBadge label="Offline Mode" tone="warning" testID="offline-badge" />
      <Text style={[styles.h1, { color: t.text }]}>You’re offline</Text>

      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>{savedLine}</Text>
        <Text style={[styles.body2, { color: t.text }]}>
          New assignments may require a connection, so a few may not appear until you’re back
          online.
        </Text>
      </Card>

      <View style={styles.actions}>
        <Button
          theme={t}
          label="Continue to saved work"
          onPress={props.onContinue}
          testID="offline-continue"
        />
        <Button
          theme={t}
          variant="secondary"
          label={retrying ? 'Trying connection…' : 'Try connection again'}
          onPress={() => {
            setRetrying(true);
            props.onRetry();
          }}
          disabled={retrying}
          testID="offline-retry"
        />
        {retrying ? (
          <Text style={[styles.confirm, { color: t.success }]} testID="offline-retry-status">
            Checking for a connection…
          </Text>
        ) : null}
      </View>
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------
 * 5. First-Run Permissions (GUI Master §5 / screen 5)
 * Ask for permissions only when needed, one page at a time, each explaining WHY in driver terms.
 * No "backend validation" framing — language is about confirming arrival and capturing job
 * evidence. The actual OS prompt is fired by the caller through onAllow.
 * ---------------------------------------------------------------------------------------------- */

export type PermissionKey = 'location' | 'camera' | 'photos' | 'bluetooth' | 'notifications';

export type PermissionState = 'pending' | 'granted' | 'skipped';

export interface PermissionPage {
  key: PermissionKey;
  title: string;
  /** Plain-English reason this permission helps the driver do the job. */
  why: string;
  /** Whether the page may be skipped ("Not Now") — required permissions hide that option. */
  optional?: boolean;
}

/** Default page set + driver-facing reasons (GUI Master §5 screen 5 examples). */
const DEFAULT_PERMISSION_PAGES: readonly PermissionPage[] = [
  {
    key: 'location',
    title: 'Location Access',
    why: 'Location helps confirm arrival and job evidence.',
    optional: true,
  },
  {
    key: 'camera',
    title: 'Camera Access',
    why: 'The camera lets you photograph the load, the site, and job evidence.',
    optional: true,
  },
  {
    key: 'photos',
    title: 'Photo Library Access',
    why: 'Photo access lets you attach pictures you’ve already taken to a job.',
    optional: true,
  },
  {
    key: 'bluetooth',
    title: 'Bluetooth / Printer Access',
    why: 'Bluetooth lets you print field tickets and receipts to a nearby printer.',
    optional: true,
  },
  {
    key: 'notifications',
    title: 'Notifications',
    why: 'Notifications let dispatch reach you about new assignments and reminders.',
    optional: true,
  },
];

const PERMISSION_BADGE: Record<PermissionState, { label: string; tone: 'neutral' | 'success' }> = {
  pending: { label: 'Not Started', tone: 'neutral' },
  granted: { label: 'Synced', tone: 'success' },
  skipped: { label: 'Not Started', tone: 'neutral' },
};

export function FirstRunPermissionsScreen(props: {
  /** Optional override of the page set/order; falls back to the canonical five. */
  pages?: PermissionPage[];
  /** Zero-based index of the page currently shown. */
  index?: number;
  /** Per-permission outcome so far, keyed by PermissionKey. */
  states?: Partial<Record<PermissionKey, PermissionState>>;
  onAllow?: (key: PermissionKey) => void;
  onSkip?: (key: PermissionKey) => void;
  onBack?: () => void;
  /** Called when the last page is dismissed (allow/skip on the final permission). */
  onFinish: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const pages = props.pages ?? DEFAULT_PERMISSION_PAGES;
  const [internalIndex, setInternalIndex] = useState(0);
  const index = props.index ?? internalIndex;

  // Per-permission outcome is self-managing: seed from the optional `states` prop, then update on
  // Allow/Skip so the status badge for this permission visibly flips ("Not Started" → "Synced").
  const [internalStates, setInternalStates] = useState<
    Partial<Record<PermissionKey, PermissionState>>
  >(props.states ?? {});

  const page = pages[Math.min(index, pages.length - 1)];
  if (page === undefined) {
    return (
      <View style={styles.bodyCentered}>
        <Text style={[styles.h1, { color: t.text }]}>You’re all set</Text>
        <Button theme={t} label="Continue" onPress={props.onFinish} testID="perm-finish" />
      </View>
    );
  }

  const state = internalStates[page.key] ?? 'pending';
  const optional = page.optional ?? true;
  const isLast = index >= pages.length - 1;
  const step = index + 1;

  const advance = () => {
    if (props.index === undefined) {
      setInternalIndex((i) => i + 1);
    }
    if (isLast) {
      props.onFinish();
    }
  };

  const record = (key: PermissionKey, outcome: PermissionState) => {
    setInternalStates((prev) => ({ ...prev, [key]: outcome }));
  };

  return (
    <View style={styles.body}>
      <View style={styles.row}>
        <Text style={[styles.meta, { color: t.textMuted }]}>
          Step {step} of {pages.length}
        </Text>
        <StatusBadge
          label={PERMISSION_BADGE[state].label}
          tone={PERMISSION_BADGE[state].tone}
          testID="perm-state"
        />
      </View>

      <Text style={[styles.h1, { color: t.text }]}>{page.title}</Text>

      <Card theme={t} tone="highlight" testID={`perm-card-${page.key}`}>
        <Text style={[styles.body2, { color: t.text }]}>{page.why}</Text>
        <Text style={[styles.body2, { color: t.textMuted }]}>
          You can change this later in Settings. We only ask when it helps you do the job.
        </Text>
      </Card>

      <Button
        theme={t}
        label="Allow"
        onPress={() => {
          record(page.key, 'granted');
          props.onAllow?.(page.key);
          advance();
        }}
        testID="perm-allow"
      />
      {optional ? (
        <Button
          theme={t}
          variant="secondary"
          label="Not now"
          onPress={() => {
            record(page.key, 'skipped');
            props.onSkip?.(page.key);
            advance();
          }}
          testID="perm-skip"
        />
      ) : (
        <Text style={[styles.meta, { color: t.textMuted }]}>
          This permission is required to continue.
        </Text>
      )}
      {index > 0 && props.onBack !== undefined ? (
        <Button
          theme={t}
          variant="secondary"
          label="Back"
          onPress={() => {
            if (props.index === undefined) {
              setInternalIndex((i) => Math.max(0, i - 1));
            }
            if (props.onBack !== undefined) {
              props.onBack();
            }
          }}
          testID="perm-back"
        />
      ) : null}
    </View>
  );
}

/* ------------------------------------------------------------------------------------------------
 * 6. Session Expired (GUI Master §5 / screen 6)
 * Let the driver re-authenticate without fear of data loss. The headline reassurance: saved work
 * remains on the phone; signing in again just continues.
 * ---------------------------------------------------------------------------------------------- */

export function SessionExpiredScreen(props: {
  /** Driver name to greet, if known — keeps the prompt human. */
  driverName?: string;
  /** Count of items held safely on this phone, surfaced as reassurance. */
  savedItemCount?: number;
  /** True while re-auth is being processed. */
  signingIn?: boolean;
  onSignInAgain: () => void;
  onGetHelp?: () => void;
  theme?: Theme;
}) {
  const t = useResolvedTheme(props.theme);
  const savedItemCount = props.savedItemCount ?? 0;

  // Self-managing "signingIn": tapping Sign In Again flips local state so the button visibly shows
  // it's working, then still calls the caller's onSignInAgain to run the real re-auth.
  const [signingIn, setSigningIn] = useState(props.signingIn ?? false);

  const greeting =
    props.driverName !== undefined ? `Welcome back, ${props.driverName}.` : 'Welcome back.';
  const savedLine =
    savedItemCount > 0
      ? `Your ${savedItemCount} saved item${savedItemCount === 1 ? '' : 's'} remain${savedItemCount === 1 ? 's' : ''} on this phone.`
      : 'Saved work remains on this phone.';

  return (
    <View style={styles.bodyCentered}>
      <Logo size={72} ring testID="expired-logo" />
      <StatusBadge label="Locked" tone="warning" testID="expired-badge" />
      <Text style={[styles.h1, { color: t.text }]}>Session expired</Text>
      <Text style={[styles.lede, { color: t.textMuted }]}>{greeting}</Text>

      <Card theme={t} tone="highlight">
        <Text style={[styles.body2, { color: t.text }]}>{savedLine}</Text>
        <Text style={[styles.body2, { color: t.text }]}>Sign in again to continue.</Text>
      </Card>

      <View style={styles.actions}>
        <Button
          theme={t}
          label={signingIn ? 'Signing in…' : 'Sign In Again'}
          onPress={() => {
            setSigningIn(true);
            props.onSignInAgain();
          }}
          disabled={signingIn}
          testID="expired-sign-in"
        />
        {props.onGetHelp !== undefined ? (
          <Button
            theme={t}
            variant="secondary"
            label="Help signing in"
            onPress={props.onGetHelp}
            testID="expired-help"
          />
        ) : null}
      </View>
    </View>
  );
}

/* ---------------------------------------------------------------------------------------------- */

const styles = StyleSheet.create({
  body: {
    padding: spacing.lg,
    gap: spacing.md,
  },
  bodyCentered: {
    padding: spacing.lg,
    gap: spacing.md,
    alignItems: 'center',
  },
  h1: {
    fontSize: typeScale.title,
    fontWeight: '800',
    textAlign: 'center',
  },
  lede: {
    fontSize: typeScale.body,
    lineHeight: 23,
    textAlign: 'center',
  },
  body2: {
    fontSize: typeScale.body,
    lineHeight: 23,
  },
  confirm: {
    fontSize: typeScale.label,
    fontWeight: '700',
  },
  meta: {
    fontSize: typeScale.label,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  actions: {
    alignSelf: 'stretch',
    gap: spacing.sm,
  },
});
