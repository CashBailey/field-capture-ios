/**
 * File-backed blob bytes source: production capture bytes live outside SQLite, but with the
 * same never-silently-lose behavior as the upload engine. This test uses a fake file driver so
 * CI stays hardware-free and does not touch native modules.
 */
import { FileBlobBytesSource, type BlobFileDriver } from '../src/data';

class FakeBlobFileDriver implements BlobFileDriver {
  readonly rootUri = 'file:///private/captures';
  private files = new Map<string, Uint8Array>();

  async ensureRoot(): Promise<void> {
    // no-op: the fake root always exists
  }

  async write(name: string, bytes: Uint8Array): Promise<string> {
    const uri = `${this.rootUri}/${name}`;
    this.files.set(uri, bytes.slice());
    return uri;
  }

  async read(uri: string): Promise<Uint8Array> {
    const bytes = this.files.get(uri);
    if (bytes === undefined) throw new Error(`missing fake file ${uri}`);
    return bytes.slice();
  }

  async delete(uri: string): Promise<void> {
    if (!this.files.delete(uri)) throw new Error(`missing fake file ${uri}`);
  }

  has(uri: string): boolean {
    return this.files.has(uri);
  }
}

describe('FileBlobBytesSource', () => {
  it('persists capture bytes under a stable blob filename and reads tus chunks', async () => {
    const driver = new FakeBlobFileDriver();
    const source = new FileBlobBytesSource(driver);

    const uri = await source.persist('blob/with spaces', new Uint8Array([1, 2, 3, 4, 5]));

    expect(uri).toBe('file:///private/captures/blob-with-spaces.bin');
    expect(driver.has(uri)).toBe(true);
    await expect(source.read(uri, 1, 3)).resolves.toEqual(new Uint8Array([2, 3, 4]));
  });

  it('overwrites the same blob id idempotently and fails loud on double delete', async () => {
    const driver = new FakeBlobFileDriver();
    const source = new FileBlobBytesSource(driver);

    const first = await source.persist('blob-1', new Uint8Array([1, 2, 3]));
    const second = await source.persist('blob-1', new Uint8Array([9]));

    expect(second).toBe(first);
    await expect(source.read(first, 0, 10)).resolves.toEqual(new Uint8Array([9]));
    await source.delete(first);
    expect(driver.has(first)).toBe(false);
    await expect(source.delete(first)).rejects.toThrow(/missing fake file/);
  });
});
