/**
 * DB-encryption critical path: the random key in the keychain, and the open path that proves
 * SQLCipher is REALLY decrypting (verified, never assumed) and surfaces a lost/rotated key as a
 * visible error instead of silently wiping local evidence.
 *
 * react-native-keychain is faked in jest.setup.js (an in-memory Map). The native SQLite adapter
 * (quickSqliteDriver) is mocked here so openFieldDatabase runs against a controllable fake driver
 * — same SqlDriver seam as on-device.
 */
import * as Keychain from 'react-native-keychain';

import { DatabaseKeyMismatchError, getOrCreateDatabaseKey, openFieldDatabase } from '../src/data';
import type { SqlDriver } from '../src/data/sqlDriver';

// Mock the native adapter: each test installs the SqlDriver openQuickSqliteDriver should return.
// jest.mock factories may only touch `mock`-prefixed out-of-scope vars, hence this holder.
const mockSqlite: { nextDriver: SqlDriver | null; opened: string[]; deleted: string[] } = {
  nextDriver: null,
  opened: [],
  deleted: [],
};
jest.mock('../src/data/quickSqliteDriver', () => ({
  openQuickSqliteDriver: jest.fn((name: string) => {
    mockSqlite.opened.push(name);
    return mockSqlite.nextDriver;
  }),
  deleteQuickSqliteDatabase: jest.fn((name: string) => {
    mockSqlite.deleted.push(name);
  }),
}));

const KEY_SERVICE = 'fieldcapture.db.key';

beforeEach(async () => {
  mockSqlite.nextDriver = null;
  mockSqlite.opened = [];
  mockSqlite.deleted = [];
  await Keychain.resetGenericPassword({ service: KEY_SERVICE });
  jest.clearAllMocks();
});

/** A fake driver that records exec'd SQL and lets a test decide what `first` does. */
function fakeDriver(
  opts: {
    cipherVersion?: string;
    firstThrowsOnMaster?: boolean;
  } = {},
): SqlDriver & { execed: string[] } {
  const execed: string[] = [];
  return {
    execed,
    exec(sql: string) {
      execed.push(sql);
    },
    run() {},
    all() {
      return [];
    },
    first<T>(sql: string): T | null {
      if (sql.includes('cipher_version')) {
        return opts.cipherVersion ? ({ cipher_version: opts.cipherVersion } as unknown as T) : null;
      }
      if (sql.includes('sqlite_master')) {
        if (opts.firstThrowsOnMaster) {
          throw new Error('file is not a database (SQLITE_NOTADB)');
        }
        return { n: 0 } as unknown as T;
      }
      return null;
    },
    transaction<T>(fn: () => T): T {
      return fn();
    },
  };
}

describe('getOrCreateDatabaseKey', () => {
  it('reuses an existing valid 64-hex key from the keychain (does not regenerate)', async () => {
    const stored = 'a'.repeat(64);
    await Keychain.setGenericPassword('fieldcapture', stored, { service: KEY_SERVICE });
    (Keychain.setGenericPassword as jest.Mock).mockClear();

    const key = await getOrCreateDatabaseKey();

    expect(key).toBe(stored);
    // reuse means it must NOT write a new key back
    expect(Keychain.setGenericPassword).not.toHaveBeenCalled();
  });

  it('generates a fresh 32-byte (64-hex-char) key when none exists and persists it', async () => {
    expect(await Keychain.getGenericPassword({ service: KEY_SERVICE })).toBe(false);

    const key = await getOrCreateDatabaseKey();

    expect(key).toMatch(/^[0-9a-f]{64}$/);
    // 64 hex chars == 32 random bytes
    expect(key).toHaveLength(64);
    // persisted under the db-key service so a restart reuses it
    expect(Keychain.setGenericPassword).toHaveBeenCalledWith(
      'fieldcapture',
      key,
      expect.objectContaining({ service: KEY_SERVICE }),
    );
    const persisted = await Keychain.getGenericPassword({ service: KEY_SERVICE });
    expect(persisted !== false && persisted.password).toBe(key);
  });

  it('is stable across calls once generated (a second call reuses the persisted key)', async () => {
    const first = await getOrCreateDatabaseKey();
    (Keychain.setGenericPassword as jest.Mock).mockClear();
    const second = await getOrCreateDatabaseKey();
    expect(second).toBe(first);
    expect(Keychain.setGenericPassword).not.toHaveBeenCalled();
  });

  it('regenerates when the stored key is non-hex (rejects a corrupt entry, never returns it)', async () => {
    await Keychain.setGenericPassword('fieldcapture', 'not-a-hex-key!!!', { service: KEY_SERVICE });

    const key = await getOrCreateDatabaseKey();

    expect(key).not.toBe('not-a-hex-key!!!');
    expect(key).toMatch(/^[0-9a-f]{64}$/);
    expect(Keychain.setGenericPassword).toHaveBeenCalled();
  });

  it('regenerates when the stored key is the wrong length (hex but not 64 chars)', async () => {
    const tooShort = 'abcdef'; // valid hex, wrong length
    await Keychain.setGenericPassword('fieldcapture', tooShort, { service: KEY_SERVICE });

    const key = await getOrCreateDatabaseKey();

    expect(key).not.toBe(tooShort);
    expect(key).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('openFieldDatabase (verified durability; visible key-mismatch, never a silent wipe)', () => {
  const HEX_KEY = 'a'.repeat(64);

  it('rejects a non-hex encryption key before touching the database', () => {
    mockSqlite.nextDriver = fakeDriver({ cipherVersion: '4.5.0' });
    expect(() => openFieldDatabase({ encryptionKey: 'plaintext-not-hex' })).toThrow(/hex/i);
  });

  it('reports durable-encrypted when SQLCipher is really active (cipher_version present)', () => {
    const driver = fakeDriver({ cipherVersion: '4.5.0' });
    mockSqlite.nextDriver = driver;
    const { durability } = openFieldDatabase({ encryptionKey: HEX_KEY });
    expect(durability).toBe('durable-encrypted');
    // PRAGMA key must be applied as a hex-quoted blob literal
    expect(driver.execed[0]).toBe(`PRAGMA key = "x'${HEX_KEY}'"`);
  });

  it('reports durable-plain (not encrypted) when the build is plain SQLite — verdict from the DB, not config', () => {
    mockSqlite.nextDriver = fakeDriver({ cipherVersion: undefined });
    const { durability } = openFieldDatabase({ encryptionKey: HEX_KEY });
    expect(durability).toBe('durable-plain');
  });

  it('surfaces a decrypt failure as a visible DatabaseKeyMismatchError, never deleting the database', () => {
    mockSqlite.nextDriver = fakeDriver({ cipherVersion: '4.5.0', firstThrowsOnMaster: true });

    let caught: unknown;
    try {
      openFieldDatabase({ encryptionKey: HEX_KEY });
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeInstanceOf(DatabaseKeyMismatchError);
    expect((caught as DatabaseKeyMismatchError).cause).toBeInstanceOf(Error);
    // the whole point: a lost/rotated key must NOT trigger an auto-wipe
    expect(mockSqlite.deleted).toEqual([]);
  });
});
