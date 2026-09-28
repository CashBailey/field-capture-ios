/**
 * File-backed blob bytes source for captured photos/signatures. SQLite stores the blob metadata
 * and lifecycle; this adapter stores the actual bytes under the app's private documents area so
 * they survive restart and are deleted only through UploadEngine.purgeOnce().
 */
import { fromByteArray, toByteArray } from 'base64-js';
import * as RNFS from 'react-native-fs';

import type { BlobBytesSource } from '../domain';

export interface BlobFileDriver {
  readonly rootUri: string;
  ensureRoot(): Promise<void>;
  write(name: string, bytes: Uint8Array): Promise<string>;
  read(uri: string): Promise<Uint8Array>;
  delete(uri: string): Promise<void>;
}

function blobFilename(blobId: string): string {
  const safe = blobId
    .trim()
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return `${safe.length > 0 ? safe : 'blob'}.bin`;
}

function fileUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}

function pathFromUri(uri: string): string {
  return uri.startsWith('file://') ? uri.slice('file://'.length) : uri;
}

export class FileBlobBytesSource implements BlobBytesSource {
  constructor(private readonly driver: BlobFileDriver) {}

  async persist(blobId: string, bytes: Uint8Array): Promise<string> {
    await this.driver.ensureRoot();
    return this.driver.write(blobFilename(blobId), bytes);
  }

  async read(localUri: string, offset: number, length: number): Promise<Uint8Array> {
    if (!Number.isInteger(offset) || offset < 0) {
      throw new Error(`invalid blob read offset ${offset}`);
    }
    if (!Number.isInteger(length) || length < 0) {
      throw new Error(`invalid blob read length ${length}`);
    }
    const bytes = await this.driver.read(localUri);
    return bytes.slice(offset, offset + length);
  }

  async delete(localUri: string): Promise<void> {
    await this.driver.delete(localUri);
  }
}

export function createNativeBlobFileDriver(
  rootPath: string = `${RNFS.DocumentDirectoryPath}/captures`,
): BlobFileDriver {
  return {
    rootUri: fileUri(rootPath),
    async ensureRoot() {
      await RNFS.mkdir(rootPath, {
        NSURLIsExcludedFromBackupKey: true,
        NSFileProtectionKey: 'NSFileProtectionCompleteUntilFirstUserAuthentication',
      });
    },
    async write(name, bytes) {
      await this.ensureRoot();
      const path = `${rootPath}/${name}`;
      await RNFS.writeFile(path, fromByteArray(bytes), 'base64');
      return fileUri(path);
    },
    async read(uri) {
      const path = pathFromUri(uri);
      if (!(await RNFS.exists(path))) throw new Error(`blob bytes file is missing: ${uri}`);
      return toByteArray(await RNFS.readFile(path, 'base64'));
    },
    async delete(uri) {
      const path = pathFromUri(uri);
      if (!(await RNFS.exists(path))) throw new Error(`blob bytes file is missing: ${uri}`);
      await RNFS.unlink(path);
    },
  };
}
