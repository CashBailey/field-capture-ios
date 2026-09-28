/**
 * `TokenStore` over the iOS Keychain.
 * The session never touches SQLite or AsyncStorage. Corrupt or unreadable credentials resolve to
 * signed-out, never to a frozen boot screen.
 */
import * as Keychain from 'react-native-keychain';

import type { AuthSession, StoreDurability, TokenStore } from '../../domain';

const SESSION_KEY = 'fieldcapture.auth.session';

function isAuthSession(value: unknown): value is AuthSession {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { sessionToken?: unknown }).sessionToken === 'string' &&
    (value as { sessionToken: string }).sessionToken.length > 0
  );
}

export class KeychainTokenStore implements TokenStore {
  readonly durability: StoreDurability = 'durable-encrypted';

  async load(): Promise<AuthSession | null> {
    try {
      const credentials = await Keychain.getGenericPassword({ service: SESSION_KEY });
      if (credentials === false) return null;
      const parsed: unknown = JSON.parse(credentials.password);
      if (!isAuthSession(parsed)) {
        await Keychain.resetGenericPassword({ service: SESSION_KEY });
        return null;
      }
      return parsed;
    } catch {
      try {
        await Keychain.resetGenericPassword({ service: SESSION_KEY });
      } catch {
        // A broken keychain still means "signed out" to the app.
      }
      return null;
    }
  }

  async save(session: AuthSession): Promise<void> {
    await Keychain.setGenericPassword('fieldcapture', JSON.stringify(session), {
      service: SESSION_KEY,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
  }

  async clear(): Promise<void> {
    await Keychain.resetGenericPassword({ service: SESSION_KEY });
  }
}
