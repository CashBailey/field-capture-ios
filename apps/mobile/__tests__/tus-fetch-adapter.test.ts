/**
 * The fetch→TusFetch adapter (Section 4e item 2). Verified standalone AND by driving a real
 * TusUploadClient through it, so the on-device go-live wiring is a one-liner over tested code.
 */
import { createTusFetch, TusUploadClient, type FetchLike } from '../src/adapters/sync';

function fakeFetch(
  status: number,
  headers: Record<string, string>,
): FetchLike & { calls: { url: string; init: Parameters<FetchLike>[1] }[] } {
  const calls: { url: string; init: Parameters<FetchLike>[1] }[] = [];
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  const fn: FetchLike = async (url, init) => {
    calls.push({ url, init });
    return {
      status,
      headers: { get: (name: string) => lower[name.toLowerCase()] ?? null },
    };
  };
  return Object.assign(fn, { calls });
}

describe('createTusFetch', () => {
  it('maps status and case-insensitive headers (null → undefined)', async () => {
    const tusFetch = createTusFetch(fakeFetch(200, { 'Upload-Offset': '512' }));
    const res = await tusFetch('http://h/u', { method: 'HEAD', headers: {} });
    expect(res.status).toBe(200);
    expect(res.header('upload-offset')).toBe('512'); // case-insensitive
    expect(res.header('Missing')).toBeUndefined(); // null → undefined
  });

  it('threads the method, headers, body and abort signal through to fetch', async () => {
    const f = fakeFetch(204, { 'Upload-Offset': '4' });
    const tusFetch = createTusFetch(f);
    const controller = new AbortController();
    const body = new Uint8Array([1, 2, 3, 4]);
    await tusFetch('http://h/u', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/offset+octet-stream' },
      body,
      signal: controller.signal,
    });
    expect(f.calls[0]!.init).toMatchObject({
      method: 'PATCH',
      headers: { 'Content-Type': 'application/offset+octet-stream' },
      body,
      signal: controller.signal,
    });
  });

  it('drives a real TusUploadClient probe end-to-end', async () => {
    const client = new TusUploadClient({
      sessionToken: 'tok',
      fetchFn: createTusFetch(fakeFetch(200, { 'Upload-Offset': '1024', 'Upload-Sha256': 'abc' })),
    });
    await expect(client.probe('http://h/u')).resolves.toEqual({ offset: 1024, sha256: 'abc' });
  });
});
