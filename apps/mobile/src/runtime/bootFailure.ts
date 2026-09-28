/**
 * Boot-failure classification (Phase 2). When startup throws, the app must tell the worker WHICH
 * kind of failure it was and — critically — must NEVER auto-wipe local data. Only a database
 * KEY mismatch (the key in the keychain no longer opens the encrypted store) may offer a
 * destructive local reset, and only behind an explicit confirm. A missing Hub URL (`HubConfigError`)
 * or any other database/unknown error keeps the local data untouched and offers no reset.
 *
 * Pure + typed so the rule is unit-tested; `App.tsx` is a thin consumer in the PRE-nav boot gate
 * (which survives the Section-4a nav refactor).
 */
import { HubConfigError } from '../config/hubConfig';
import { DatabaseKeyMismatchError } from '../data';

export type BootFailureReason = 'hub-config' | 'db-key-mismatch' | 'db-error' | 'unknown';

export interface BootFailure {
  reason: BootFailureReason;
  /** Only a key mismatch may offer a destructive local reset — never auto-wipe on anything else. */
  canReset: boolean;
  /** Worker-facing, plain-language explanation. */
  message: string;
  /** The underlying error message, preserved for the diagnostic/developer section. */
  detail: string;
}

function detailOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

export function classifyBootFailure(error: unknown): BootFailure {
  const detail = detailOf(error);
  if (error instanceof DatabaseKeyMismatchError) {
    return {
      reason: 'db-key-mismatch',
      canReset: true,
      message:
        'This phone’s secure database key changed, so the saved local data can’t be opened. ' +
        'Resetting clears local data on THIS phone — any unsynced work would be lost.',
      detail,
    };
  }
  if (error instanceof HubConfigError) {
    return {
      reason: 'hub-config',
      canReset: false,
      message:
        'This build has no Ops Hub address configured. Reinstall the correct build — your local ' +
        'data on this phone is safe and untouched.',
      detail,
    };
  }
  // Any other startup error (DB open/migration/disk, or unexpected). Never auto-wipe; the local
  // data is left exactly as it is for recovery/support.
  return {
    reason: 'unknown',
    canReset: false,
    message:
      'Field Capture could not start. Your local data on this phone is preserved and untouched — ' +
      'please retry, and contact the office if it keeps failing.',
    detail,
  };
}
