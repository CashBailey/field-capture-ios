/**
 * The database encryption key: 32 random bytes, hex-encoded, generated once per install and
 * held in the device keychain (small string — well under platform limits).
 * The key never leaves the device and is never derived from anything user-visible.
 *
 * If the keychain entry is lost (e.g. biometrics reset invalidated it), the SQLCipher database
 * can no longer be decrypted — callers surface that as a visible reset, never a silent wipe.
 */
import * as Keychain from 'react-native-keychain';

import { randomBytes } from '../platform/random';

const KEY_NAME = 'fieldcapture.db.key';

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

export async function getOrCreateDatabaseKey(): Promise<string> {
  const existing = await Keychain.getGenericPassword({ service: KEY_NAME });
  const existingKey = existing === false ? null : existing.password;
  if (existingKey !== null && /^[0-9a-f]{64}$/i.test(existingKey)) {
    return existingKey;
  }
  const key = toHex(randomBytes(32));
  await Keychain.setGenericPassword('fieldcapture', key, {
    service: KEY_NAME,
    // Available after first unlock so background retry can run; never synced off-device.
    accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
  });
  return key;
}
