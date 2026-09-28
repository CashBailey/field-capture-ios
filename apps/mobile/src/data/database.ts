/**
 * Open (and migrate) the durable local database. This is the only module that talks to
 * the native SQLite adapter directly; everything else sees a `SqlDriver` plus an HONEST
 * durability verdict.
 *
 * Encryption: the key comes from the device keychain (encryptionKey.ts). `PRAGMA key` MUST be the
 * first statement after open. Whether SQLCipher is REALLY active is verified with
 * `PRAGMA cipher_version`; a build without SQLCipher silently ignores `PRAGMA key`, so the
 * durability verdict is taken from the database, never assumed from configuration.
 */
import type { StoreDurability } from '../domain';
import { migrate } from './migrations';
import { deleteQuickSqliteDatabase, openQuickSqliteDriver } from './quickSqliteDriver';
import type { SqlDriver } from './sqlDriver';

export const DEFAULT_DATABASE_NAME = 'fieldcapture.db';

/**
 * The database exists but cannot be decrypted with the available key (keychain entry lost or
 * rotated — e.g. biometrics reset invalidated it). The data is unreadable; the ONLY way forward
 * is an explicit, user-confirmed reset (`resetLocalDatabase`). Never auto-wipe.
 */
export class DatabaseKeyMismatchError extends Error {
  readonly cause?: unknown;

  constructor(message: string, options?: { cause?: unknown }) {
    super(message);
    this.name = 'DatabaseKeyMismatchError';
    this.cause = options?.cause;
  }
}

/**
 * Destroy the local database so the app can start fresh after a key loss. DESTRUCTIVE: any
 * unsynced evidence inside is gone — callers must put an explicit user confirmation in front.
 */
export function resetLocalDatabase(databaseName: string = DEFAULT_DATABASE_NAME): void {
  deleteQuickSqliteDatabase(databaseName);
}

export interface OpenedDatabase {
  db: SqlDriver;
  /** What this database actually guarantees — verified, not assumed. */
  durability: Exclude<StoreDurability, 'volatile-memory'>;
}

/** True when the underlying build is SQLCipher (plain SQLite returns no cipher_version row). */
function cipherActive(db: SqlDriver): boolean {
  const row = db.first<{ cipher_version?: string }>('PRAGMA cipher_version');
  return typeof row?.cipher_version === 'string' && row.cipher_version.length > 0;
}

export function openFieldDatabase(options: {
  encryptionKey: string;
  databaseName?: string;
}): OpenedDatabase {
  const name = options.databaseName ?? DEFAULT_DATABASE_NAME;
  const db = openQuickSqliteDriver(name);
  // Hex-quoted key form; the key itself is random hex from the keychain (never user input).
  if (!/^[0-9a-f]+$/i.test(options.encryptionKey)) {
    throw new Error('database encryption key must be hex (got a non-hex string)');
  }
  db.exec(`PRAGMA key = "x'${options.encryptionKey}'"`);
  const durability: OpenedDatabase['durability'] = cipherActive(db)
    ? 'durable-encrypted'
    : 'durable-plain';
  // First real read: with a wrong/lost key SQLCipher fails here ("file is not a database",
  // SQLITE_NOTADB). Classify it so the boot screen can offer an explicit reset instead of an
  // unrecoverable crash loop.
  try {
    db.first('SELECT count(*) AS n FROM sqlite_master');
  } catch (error) {
    throw new DatabaseKeyMismatchError(
      `local database "${name}" cannot be decrypted with the stored key — the keychain entry ` +
        'was lost or rotated. Local data is unreadable; an explicit reset is required.',
      { cause: error },
    );
  }
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA foreign_keys = ON');
  migrate(db);
  return { db, durability };
}
