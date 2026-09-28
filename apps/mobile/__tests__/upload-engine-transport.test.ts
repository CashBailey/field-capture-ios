/**
 * ADR-004 TUS slice (integration): a captured blob uploads END TO END through the REAL transports
 * — OpsHubSyncTransport.openUploadSession over a scripted Hub `fetch`, then the real
 * TusUploadClient HEAD/PATCH over a scripted tus `fetch` — not the throwing stubs. Proves the wire
 * path (POST /sync/uploads, chunked PATCH, hash-verified completion), that the attachment.link is
 * enqueued, that an accepted link advances the blob to `linked`/purgeable, and that the
 * tokenProvider supplies a fresh bearer per request.
 */
import { sync } from '@fieldcapture/contracts';

import {
  createTusFetch,
  OpsHubSyncTransport,
  TusUploadClient,
  type FetchLike,
  type HubFetch,
  type HubFetchInit,
  type HubHttpResponse,
} from '../src/adapters/sync';
import {
  VolatileBlobBytesSource,
  VolatileBlobUploadStore,
  type BlobUploadRecord,
} from '../src/domain';
import { UploadEngine, type RegisterBlobInput } from '../src/runtime';

const BYTES = new Uint8Array(Array.from({ length: 10 }, (_, i) => i));
const SHA = 'aa11';
const LOCAL_URI = 'file:///photos/blob-1.jpg';
const BASE_URL = 'http://hub.test';
const UPLOAD_URL = `${BASE_URL}/api/v1/sync/uploads/sess-blob-1`;

function registerInput(): RegisterBlobInput {
  return {
    blobId: 'blob-1',
    sha256: SHA,
    byteLength: BYTES.length,
    mimeType: 'image/jpeg',
    localUri: LOCAL_URI,
    attachmentId: 'att-1',
    parentType: 'field-ticket',
    parentId: 'ft-1',
    attachmentKind: 'field-ticket-photo',
  };
}

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

/** A scripted Hub at the HTTP layer: JSON /sync/uploads (hubFetch) + tus HEAD/PATCH (tusFetch). */
function makeHttpHub(token: () => string) {
  const authSeen: string[] = [];
  const uploadsRequests: Record<string, unknown>[] = [];
  let received = 0;
  const patched: number[] = [];

  const hubFetch: HubFetch = async (url: string, init: HubFetchInit): Promise<HubHttpResponse> => {
    authSeen.push(init.headers.Authorization);
    if (url === `${BASE_URL}/api/v1/sync/uploads` && init.method === 'POST') {
      uploadsRequests.push(JSON.parse(init.body as string) as Record<string, unknown>);
      return jsonResponse(200, {
        result: 'new-session',
        upload_session_id: 'sess-blob-1',
        upload_url: UPLOAD_URL,
      });
    }
    throw new Error(`unexpected hub request ${init.method} ${url}`);
  };

  const tusFetch: FetchLike = async (url, init) => {
    authSeen.push(init.headers.Authorization);
    if (url !== UPLOAD_URL) throw new Error(`unexpected tus url ${url}`);
    const headers: Record<string, string> = {};
    if (init.method === 'PATCH') {
      const body = init.body ?? new Uint8Array();
      patched.push(...Array.from(body));
      received += body.length;
      headers['Upload-Offset'] = String(received);
      if (received === BYTES.length) headers['Upload-Sha256'] = SHA; // whole-file hash verified
    } else {
      headers['Upload-Offset'] = String(received); // HEAD probe
    }
    return {
      status: init.method === 'PATCH' ? 204 : 200,
      headers: { get: (n) => headers[n] ?? null },
    };
  };

  const transport = new OpsHubSyncTransport(
    { baseUrl: BASE_URL, sessionToken: 'unused' },
    hubFetch,
    { tokenProvider: token },
  );
  const tus = new TusUploadClient({ tokenProvider: token, fetchFn: createTusFetch(tusFetch) });
  return {
    transport,
    tus,
    authSeen,
    uploadsRequests,
    patchedBytes: () => Uint8Array.from(patched),
  };
}

function makeEngine(token: () => string) {
  const hub = makeHttpHub(token);
  const blobs = new VolatileBlobUploadStore();
  const bytes = new VolatileBlobBytesSource();
  bytes.put(LOCAL_URI, BYTES);
  const enqueued: sync.OperationEnvelope<sync.AttachBlobCommand>[] = [];
  const linkStates = new Map<string, sync.OutboxItemState>();
  let seq = 0;
  let uuid = 0;
  const engine = new UploadEngine({
    blobs,
    bytes,
    transport: hub.transport,
    tus: hub.tus,
    enqueueLink: (envelope) => enqueued.push(envelope),
    linkState: (opId) => linkStates.get(opId),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    chunkSizeBytes: 4, // 10 bytes -> 4 + 4 + 2
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { engine, blobs, bytes, enqueued, linkStates, hub };
}

describe('blob upload end-to-end through the real transport + tus client', () => {
  it('opens a real session, PATCHes the bytes, verifies the hash, enqueues attachment.link, then links', async () => {
    const { engine, blobs, enqueued, linkStates, hub } = makeEngine(() => 'tok-1');
    engine.register(registerInput());

    const report = await engine.processOnce();
    expect(report).toMatchObject({ uploaded: 1, linksEnqueued: 1 });

    // POST /sync/uploads carried the canonical body.
    expect(hub.uploadsRequests).toHaveLength(1);
    expect(hub.uploadsRequests[0]).toMatchObject({
      blob_id: 'blob-1',
      sha256: SHA,
      byte_length: BYTES.length,
      mime_type: 'image/jpeg',
    });
    expect(hub.uploadsRequests[0]).toHaveProperty('idempotency_key');

    // Every captured byte was PATCHed, in order; blob confirmed.
    expect(hub.patchedBytes()).toEqual(BYTES);
    expect(blobs.get('blob-1')).toMatchObject({
      state: 'uploaded',
      uploadConfirmed: true,
      bytesAcked: BYTES.length,
    });

    // attachment.link is ENQUEUED (its push via SyncEngine/SyncRunner -> /sync/commands is the
    // already-tested composition in sync-runner.test.ts; this test scopes the HTTP upload path).
    expect(enqueued).toHaveLength(1);
    expect(enqueued[0]).toMatchObject({
      type: 'attachment.link',
      kind: 'command',
      payload: { blobId: 'blob-1', attachmentId: 'att-1', parentId: 'ft-1' },
    });
    sync.assertEnvelopeConsistent(enqueued[0]);

    // Every request (open + HEAD/PATCH) carried the tokenProvider's bearer.
    expect(hub.authSeen.every((a) => a === 'Bearer tok-1')).toBe(true);

    // An accepted link advances to linked + purgeable on the next pass.
    const linkOpId = blobs.get('blob-1')?.linkOpId as string;
    linkStates.set(linkOpId, 'accepted');
    const second = await engine.processOnce();
    expect(second.linked).toBe(1);
    const record = blobs.get('blob-1') as BlobUploadRecord;
    expect(record).toMatchObject({ state: 'linked', linkConfirmed: true });
    expect(sync.isBlobPurgeable(record)).toBe(true);
  });

  it('the tus client resolves a FRESH bearer per request (a long upload outliving a token)', async () => {
    let token = 'tok-1';
    const seen: string[] = [];
    const fetchLike: FetchLike = async (_url, init) => {
      seen.push(init.headers.Authorization);
      return { status: 200, headers: { get: (n) => (n === 'Upload-Offset' ? '0' : null) } };
    };
    const client = new TusUploadClient({
      tokenProvider: () => token,
      fetchFn: createTusFetch(fetchLike),
    });
    await client.probe(UPLOAD_URL);
    token = 'tok-2'; // a refresh happened mid-upload
    await client.probe(UPLOAD_URL);
    expect(seen).toEqual(['Bearer tok-1', 'Bearer tok-2']);
  });

  it('a server 401 on the tus PATCH surfaces authRequired (UploadRunner pauses, never hammers)', async () => {
    const blobs = new VolatileBlobUploadStore();
    const bytes = new VolatileBlobBytesSource();
    bytes.put(LOCAL_URI, BYTES);
    // Session opens fine, but the PATCH is rejected 401 (token accepted at open, rejected mid-upload).
    const hubFetch: HubFetch = async (url, init) => {
      if (url === `${BASE_URL}/api/v1/sync/uploads` && init.method === 'POST') {
        return jsonResponse(200, {
          result: 'new-session',
          upload_session_id: 'sess-blob-1',
          upload_url: UPLOAD_URL,
        });
      }
      throw new Error(`unexpected hub url ${url}`);
    };
    const tusFetch: FetchLike = async (_url, init) => {
      if (init.method === 'HEAD') {
        return { status: 200, headers: { get: (n) => (n === 'Upload-Offset' ? '0' : null) } };
      }
      return { status: 401, headers: { get: () => null } }; // PATCH auth-rejected
    };
    const transport = new OpsHubSyncTransport(
      { baseUrl: BASE_URL, sessionToken: 'unused' },
      hubFetch,
      { tokenProvider: () => 'tok-1' },
    );
    const tus = new TusUploadClient({
      tokenProvider: () => 'tok-1',
      fetchFn: createTusFetch(tusFetch),
    });
    let seq = 0;
    let uuid = 0;
    const engine = new UploadEngine({
      blobs,
      bytes,
      transport,
      tus,
      enqueueLink: () => undefined,
      linkState: () => undefined,
      identity: {
        deviceInstanceId: 'devA',
        allocateLocalSeq: () => seq++,
        generateUuid: () => `uuid-${uuid++}`,
      },
      chunkSizeBytes: 4,
      now: () => new Date('2026-06-10T12:00:00Z'),
    });
    engine.register(registerInput());

    const report = await engine.processOnce();
    expect(report.authRequired).toBe(true); // the fix: 401 -> HubAuthError -> authRequired
    expect(report.uploaded).toBe(0);
    expect(bytes.has(LOCAL_URI)).toBe(true); // deferred, bytes kept (due on re-auth), never abandoned
  });
});
