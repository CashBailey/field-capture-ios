/**
 * Upload engine behaviour (ADR 004 two-phase attachments): capture → resumable upload → link
 * command → purge, with the hard invariant that local bytes survive until Hub confirms BOTH the
 * upload and the link commit. Hardware-free: volatile stores, scripted transport/tus fakes.
 */
import { sync } from '@fieldcapture/contracts';

import {
  VolatileBlobBytesSource,
  VolatileBlobUploadStore,
  type BlobUploadRecord,
} from '../src/domain';
import { TusHashMismatchError, TusSessionGoneError } from '../src/adapters/sync';
import { UploadEngine, type RegisterBlobInput, type UploadEngineDeps } from '../src/runtime';

const BYTES = new Uint8Array(Array.from({ length: 10 }, (_, i) => i));
const SHA = 'aa11';

function registerInput(overrides?: Partial<RegisterBlobInput>): RegisterBlobInput {
  return {
    blobId: 'blob-1',
    sha256: SHA,
    byteLength: BYTES.length,
    mimeType: 'image/jpeg',
    localUri: 'file:///photos/blob-1.jpg',
    attachmentId: 'att-1',
    parentType: 'field-ticket',
    parentId: 'ft-1',
    attachmentKind: 'field-ticket-photo',
    ...overrides,
  };
}

/** Scripted Hub upload server: in-memory session with configurable failures. */
class FakeUploadServer {
  opened: sync.UploadSessionRequest[] = [];
  alreadyPresent = false;
  openFailure: Error | undefined;
  /** Bytes durably received per session URL. */
  received = new Map<string, number>();
  /** Hash the server reports on completion (default: echo the client's). */
  reportSha: string | undefined;
  /** Throw after N successful chunks (simulated interruption). */
  failAfterChunks: number | undefined;
  /** Reject the FINAL PATCH with a fatal tus hash-mismatch 409 (Upload-Sha256 present). */
  hashMismatchOnFinal = false;
  private chunksSeen = 0;
  sessionGone = false;

  transport: Pick<sync.SyncTransport, 'openUploadSession'> = {
    openUploadSession: async (request) => {
      this.opened.push(request);
      if (this.openFailure) throw this.openFailure;
      if (this.alreadyPresent) return { result: 'already-present', blobId: request.blobId };
      const url = `http://hub.test/uploads/${request.blobId}`;
      if (!this.received.has(url)) this.received.set(url, 0);
      return { result: 'new-session', uploadSessionId: `sess-${request.blobId}`, uploadUrl: url };
    },
  };

  tus = {
    probe: async (url: string) => {
      if (this.sessionGone) throw new TusSessionGoneError('gone');
      const offset = this.received.get(url) ?? 0;
      return { offset };
    },
    uploadChunk: async (url: string, offset: number, chunk: Uint8Array) => {
      if (this.sessionGone) throw new TusSessionGoneError('gone');
      if (this.failAfterChunks !== undefined && this.chunksSeen >= this.failAfterChunks) {
        throw new Error('connection reset');
      }
      this.chunksSeen += 1;
      const current = this.received.get(url) ?? 0;
      if (offset !== current) throw new Error(`offset conflict: ${offset} != ${current}`);
      const next = current + chunk.length;
      if (this.hashMismatchOnFinal && next === BYTES.length) {
        throw new TusHashMismatchError('server hash mismatch', 'server-digest');
      }
      this.received.set(url, next);
      return {
        offset: next,
        ...(next === BYTES.length ? { sha256: this.reportSha ?? SHA } : {}),
      };
    },
  };
}

function makeEngine(overrides?: Partial<UploadEngineDeps>) {
  const blobs = new VolatileBlobUploadStore();
  const bytes = new VolatileBlobBytesSource();
  bytes.put('file:///photos/blob-1.jpg', BYTES);
  const server = new FakeUploadServer();
  const enqueued: sync.OperationEnvelope<sync.AttachBlobCommand>[] = [];
  const linkStates = new Map<string, sync.OutboxItemState>();
  let seq = 0;
  let uuid = 0;
  const engine = new UploadEngine({
    blobs,
    bytes,
    transport: server.transport,
    tus: server.tus,
    enqueueLink: (envelope) => enqueued.push(envelope),
    linkState: (opId) => linkStates.get(opId),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    chunkSizeBytes: 4, // 10 bytes → chunks of 4 + 4 + 2
    now: () => new Date('2026-06-10T12:00:00Z'),
    ...overrides,
  });
  return { engine, blobs, bytes, server, enqueued, linkStates };
}

describe('register (capture/import abstraction)', () => {
  it('stores a durable local-only record with SHA-256 and parent identity', () => {
    const { engine, blobs } = makeEngine();
    engine.register(registerInput());
    expect(blobs.get('blob-1')).toMatchObject({
      state: 'local-only',
      sha256: SHA,
      parentType: 'field-ticket',
      parentId: 'ft-1',
      attachmentKind: 'field-ticket-photo',
      uploadConfirmed: false,
      linkConfirmed: false,
    });
  });

  it('is idempotent on blobId; a duplicate attachmentId on a DIFFERENT blob throws', () => {
    const { engine } = makeEngine();
    engine.register(registerInput());
    expect(engine.register(registerInput()).blobId).toBe('blob-1');
    expect(() => engine.register(registerInput({ blobId: 'blob-2' }))).toThrow(
      /att-1 is already bound/,
    );
  });
});

describe('upload happy path + duplicate upload', () => {
  it('opens a session, chunks the bytes, verifies the hash, and enqueues the link', async () => {
    const { engine, blobs, server, enqueued } = makeEngine();
    engine.register(registerInput({ parentOpId: 'op-parent' }));

    const report = await engine.processOnce();

    expect(report).toMatchObject({ uploaded: 1, linksEnqueued: 1 });
    expect(server.received.get('http://hub.test/uploads/blob-1')).toBe(10);
    const record = blobs.get('blob-1');
    expect(record).toMatchObject({ state: 'uploaded', uploadConfirmed: true, bytesAcked: 10 });
    expect(enqueued).toHaveLength(1);
    expect(enqueued[0]).toMatchObject({
      type: 'attachment.link',
      kind: 'command',
      dependsOn: ['op-parent'],
      payload: { blobId: 'blob-1', attachmentId: 'att-1', parentId: 'ft-1' },
    });
    sync.assertEnvelopeConsistent(enqueued[0]); // real write identity, not a stub
  });

  it('duplicate upload: a content-hash dedupe hit confirms without sending a byte', async () => {
    const { engine, blobs, server } = makeEngine();
    server.alreadyPresent = true;
    engine.register(registerInput());

    const report = await engine.processOnce();

    expect(report.dedupedAlreadyPresent).toBe(1);
    expect(blobs.get('blob-1')).toMatchObject({ state: 'uploaded', uploadConfirmed: true });
    expect(server.received.size).toBe(0);
  });

  it('re-registering and re-processing never double-enqueues the link', async () => {
    const { engine, enqueued } = makeEngine();
    engine.register(registerInput());
    await engine.processOnce();
    await engine.processOnce();
    expect(enqueued).toHaveLength(1);
  });
});

describe('interruption and resume', () => {
  it('an interrupted upload keeps its durable progress and resumes from the server offset', async () => {
    const { engine, blobs, server } = makeEngine();
    engine.register(registerInput());
    server.failAfterChunks = 1; // first chunk lands, second dies

    const first = await engine.processOnce();
    expect(first.deferred).toBe(1);
    expect(blobs.get('blob-1')).toMatchObject({ state: 'uploading', bytesAcked: 4 });

    server.failAfterChunks = undefined;
    const second = await engine.processOnce();
    expect(second.uploaded).toBe(1);
    expect(server.received.get('http://hub.test/uploads/blob-1')).toBe(10);
    expect(blobs.get('blob-1')).toMatchObject({ state: 'uploaded', uploadConfirmed: true });
  });

  it('resume adopts the SERVER offset when local bookkeeping is behind', async () => {
    const { engine, blobs, server } = makeEngine();
    engine.register(registerInput());
    server.failAfterChunks = 2;
    await engine.processOnce(); // 8 bytes durable on server
    // Local row lost a write (crash before save): claims 4, server has 8.
    const record = blobs.get('blob-1') as BlobUploadRecord;
    blobs.save({ ...record, bytesAcked: 4 });

    server.failAfterChunks = undefined;
    await engine.processOnce();

    expect(server.received.get('http://hub.test/uploads/blob-1')).toBe(10);
    expect(blobs.get('blob-1')?.state).toBe('uploaded');
  });

  it('a dead session expires the blob: bytes kept, restart from scratch works', async () => {
    const { engine, blobs, bytes, server } = makeEngine();
    engine.register(registerInput());
    server.failAfterChunks = 1;
    await engine.processOnce();
    server.sessionGone = true;

    const report = await engine.processOnce();
    expect(report.expired).toBe(1);
    expect(blobs.get('blob-1')).toMatchObject({ state: 'upload-expired', bytesAcked: 0 });
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true); // never purged

    server.sessionGone = false;
    server.failAfterChunks = undefined;
    server.received.clear();
    const retry = await engine.processOnce();
    expect(retry.uploaded).toBe(1);
  });

  it('expiring a session rotates the session idempotency key (HIGH#3: never reuse a dead session key)', async () => {
    const { engine, blobs, server } = makeEngine();
    engine.register(registerInput());
    const before = blobs.get('blob-1')!.sessionIdempotencyKey;
    server.failAfterChunks = 1;
    await engine.processOnce();
    server.sessionGone = true;

    await engine.processOnce(); // session-gone → expire
    const after = blobs.get('blob-1')!.sessionIdempotencyKey;
    expect(blobs.get('blob-1')).toMatchObject({ state: 'upload-expired' });
    expect(after).not.toBe(before); // a fresh session, not the dead one's key
    expect(after.length).toBeGreaterThan(0);
  });

  it('a transient open-session failure defers; the blob stays local-only and retryable', async () => {
    const { engine, blobs, server } = makeEngine();
    engine.register(registerInput());
    server.openFailure = new Error('Hub unreachable');

    const report = await engine.processOnce();
    expect(report.deferred).toBe(1);
    expect(blobs.get('blob-1')?.state).toBe('local-only');

    server.openFailure = undefined;
    const retry = await engine.processOnce();
    expect(retry.uploaded).toBe(1);
  });
});

describe('hash verification', () => {
  it('a server hash mismatch NEVER confirms: session abandoned, bytes kept', async () => {
    const { engine, blobs, bytes, server } = makeEngine();
    engine.register(registerInput());
    server.reportSha = 'bb22'; // server holds different bytes than we captured

    const report = await engine.processOnce();

    expect(report.uploaded).toBe(0);
    expect(report.expired).toBe(1);
    const record = blobs.get('blob-1');
    expect(record).toMatchObject({ state: 'upload-expired', uploadConfirmed: false });
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true);
  });

  it('a fatal PATCH hash-mismatch 409 EXPIRES (not defers): restart clean, bytes kept', async () => {
    const { engine, blobs, bytes, server } = makeEngine();
    engine.register(registerInput());
    server.hashMismatchOnFinal = true; // Hub rejects the final chunk: bytes != declared hash

    const report = await engine.processOnce();

    expect(report.uploaded).toBe(0);
    expect(report.deferred).toBe(0); // NOT a transient retry — re-sending can't fix corruption
    expect(report.expired).toBe(1);
    expect(blobs.get('blob-1')).toMatchObject({ state: 'upload-expired', bytesAcked: 0 });
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true); // never silently lose the work
  });
});

describe('link commit and purge gating', () => {
  async function uploadedWithLink() {
    const fixture = makeEngine();
    fixture.engine.register(registerInput());
    await fixture.engine.processOnce();
    const linkOpId = fixture.blobs.get('blob-1')?.linkOpId as string;
    return { ...fixture, linkOpId };
  }

  it('the blob is NOT purgeable after upload alone — link commit is required', async () => {
    const { engine, blobs, bytes } = await uploadedWithLink();
    expect(sync.isBlobPurgeable(blobs.get('blob-1') as BlobUploadRecord)).toBe(false);
    await engine.purgeOnce();
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true);
  });

  it('an accepted link advances to linked; purge then deletes the bytes once', async () => {
    const { engine, blobs, bytes, linkStates, linkOpId } = await uploadedWithLink();
    linkStates.set(linkOpId, 'accepted');

    const report = await engine.processOnce();
    expect(report.linked).toBe(1);
    const record = blobs.get('blob-1') as BlobUploadRecord;
    expect(record).toMatchObject({ state: 'linked', uploadConfirmed: true, linkConfirmed: true });
    expect(sync.isBlobPurgeable(record)).toBe(true);

    const purged = await engine.purgeOnce();
    expect(purged).toEqual(['blob-1']);
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(false);
    expect(blobs.get('blob-1')?.purgedAt).toBeDefined(); // record survives as proof
    await expect(engine.purgeOnce()).resolves.toEqual([]); // idempotent
  });

  it('a needs-review link preserves the blob on-device, never purgeable', async () => {
    const { engine, blobs, bytes, linkStates, linkOpId } = await uploadedWithLink();
    linkStates.set(linkOpId, 'needs-review');

    await engine.processOnce();
    await engine.purgeOnce();

    expect(blobs.get('blob-1')).toMatchObject({ state: 'uploaded', linkConfirmed: false });
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true);
  });

  it('a rejected link likewise preserves the blob for review', async () => {
    const { engine, blobs, bytes, linkStates, linkOpId } = await uploadedWithLink();
    linkStates.set(linkOpId, 'rejected');
    await engine.processOnce();
    await engine.purgeOnce();
    expect(blobs.get('blob-1')?.state).toBe('uploaded');
    expect(bytes.has('file:///photos/blob-1.jpg')).toBe(true);
  });
});
