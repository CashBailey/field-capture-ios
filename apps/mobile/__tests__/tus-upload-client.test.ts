/**
 * `TusUploadClient` wire behaviour: HEAD probes the durable offset, PATCH advances it, session
 * loss and protocol violations throw typed errors, and every call is bounded + abortable.
 */
import {
  TusHashMismatchError,
  TusOffsetConflictError,
  TusProtocolError,
  TusSessionGoneError,
  TusUploadClient,
  type TusFetch,
  type TusFetchInit,
  type TusHttpResponse,
} from '../src/adapters/sync';

const URL = 'http://hub.test/api/v1/sync/uploads/sess-1';

function response(status: number, headers: Record<string, string> = {}): TusHttpResponse {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { status, header: (name) => lower[name.toLowerCase()] };
}

function fakeTusFetch(...responses: TusHttpResponse[]): TusFetch & {
  calls: { url: string; init: TusFetchInit }[];
} {
  const calls: { url: string; init: TusFetchInit }[] = [];
  const fn = async (url: string, init: TusFetchInit) => {
    calls.push({ url, init });
    const next = responses.length > 1 ? responses.shift() : responses[0];
    if (!next) throw new Error('fakeTusFetch: no response queued');
    return next;
  };
  return Object.assign(fn, { calls });
}

function client(fetchFn: TusFetch): TusUploadClient {
  return new TusUploadClient({ sessionToken: 'tok-123', fetchFn, timeoutMs: 1_000 });
}

describe('probe (HEAD)', () => {
  it('returns the server offset, with bearer auth and tus version header', async () => {
    const f = fakeTusFetch(response(200, { 'Upload-Offset': '512' }));
    await expect(client(f).probe(URL)).resolves.toEqual({ offset: 512 });
    expect(f.calls[0].init.method).toBe('HEAD');
    expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-123');
    expect(f.calls[0].init.headers['Tus-Resumable']).toBe('1.0.0');
  });

  it('carries the server hash once the upload completed', async () => {
    const f = fakeTusFetch(response(200, { 'Upload-Offset': '1024', 'Upload-Sha256': 'abc' }));
    await expect(client(f).probe(URL)).resolves.toEqual({ offset: 1024, sha256: 'abc' });
  });

  it('404/410 throw TusSessionGoneError — restart from the local copy', async () => {
    await expect(client(fakeTusFetch(response(404))).probe(URL)).rejects.toThrow(
      TusSessionGoneError,
    );
    await expect(client(fakeTusFetch(response(410))).probe(URL)).rejects.toThrow(
      TusSessionGoneError,
    );
  });

  it('a 200 without Upload-Offset is a protocol violation', async () => {
    await expect(client(fakeTusFetch(response(200))).probe(URL)).rejects.toThrow(TusProtocolError);
  });
});

describe('uploadChunk (PATCH)', () => {
  it('sends the chunk at the offset and returns the advanced offset', async () => {
    const f = fakeTusFetch(response(204, { 'Upload-Offset': '768' }));
    const chunk = new Uint8Array([1, 2, 3]);
    await expect(client(f).uploadChunk(URL, 512, chunk)).resolves.toEqual({ offset: 768 });
    expect(f.calls[0].init.headers['Upload-Offset']).toBe('512');
    expect(f.calls[0].init.headers['Content-Type']).toBe('application/offset+octet-stream');
    expect(f.calls[0].init.body).toBe(chunk);
  });

  it('the final chunk carries the server-computed whole-file hash', async () => {
    const f = fakeTusFetch(response(204, { 'Upload-Offset': '1024', 'Upload-Sha256': 'beef' }));
    await expect(client(f).uploadChunk(URL, 768, new Uint8Array(256))).resolves.toEqual({
      offset: 1024,
      sha256: 'beef',
    });
  });

  it('a 409 offset conflict (no Upload-Sha256) throws a RESUMABLE TusOffsetConflictError with the server offset', async () => {
    // opshub sync/protocol.py: offset conflict carries Upload-Offset, never Upload-Sha256.
    const failure = await client(fakeTusFetch(response(409, { 'Upload-Offset': '512' })))
      .uploadChunk(URL, 0, new Uint8Array(1))
      .then(
        () => undefined,
        (e: TusOffsetConflictError) => e,
      );
    expect(failure).toBeInstanceOf(TusOffsetConflictError);
    expect(failure?.serverOffset).toBe(512);
  });

  it('a 409 hash mismatch (Upload-Sha256 present) throws a FATAL TusHashMismatchError', async () => {
    // opshub sync/protocol.py: hash mismatch returns 409 with Upload-Sha256 = server digest.
    const failure = await client(
      fakeTusFetch(response(409, { 'Upload-Offset': '1024', 'Upload-Sha256': 'deadbeef' })),
    )
      .uploadChunk(URL, 1024, new Uint8Array(1))
      .then(
        () => undefined,
        (e: TusHashMismatchError) => e,
      );
    expect(failure).toBeInstanceOf(TusHashMismatchError);
    expect(failure?.serverSha256).toBe('deadbeef');
  });

  it('keeps throwing TusProtocolError for other unexpected statuses', async () => {
    await expect(
      client(fakeTusFetch(response(418))).uploadChunk(URL, 0, new Uint8Array(1)),
    ).rejects.toBeInstanceOf(TusProtocolError);
  });

  it('session loss mid-upload throws TusSessionGoneError', async () => {
    await expect(
      client(fakeTusFetch(response(410))).uploadChunk(URL, 0, new Uint8Array(1)),
    ).rejects.toThrow(TusSessionGoneError);
  });

  it('a timeout aborts the underlying request', async () => {
    const seen: (AbortSignal | undefined)[] = [];
    const hung: TusFetch = (_url, init) => {
      seen.push(init.signal);
      return new Promise((_, reject) => {
        init.signal?.addEventListener('abort', () => reject(new Error('aborted')));
      });
    };
    const c = new TusUploadClient({ sessionToken: 't', fetchFn: hung, timeoutMs: 10 });
    await expect(c.probe(URL)).rejects.toThrow();
    expect(seen[0]?.aborted).toBe(true);
  });
});
