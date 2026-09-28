/**
 * Photo/signature capture flow: SHA-256 anchored at capture, bytes preserved locally until
 * upload + link both commit, parent linking correct for every attachment kind, duplicate
 * attachment ids refused, and the clock gate locks capture.
 */
import { sync } from '@fieldcapture/contracts';

import {
  VolatileBlobBytesSource,
  VolatileBlobUploadStore,
  type FieldWorkGate,
} from '../src/domain';
import { CaptureFlow, UploadEngine } from '../src/runtime';

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
};
const PHOTO = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

function makeFlow(overrides?: { gate?: FieldWorkGate; failSessionOpens?: number }) {
  const blobs = new VolatileBlobUploadStore();
  const bytes = new VolatileBlobBytesSource();
  const enqueued: sync.OperationEnvelope<sync.AttachBlobCommand>[] = [];
  const linkStates = new Map<string, sync.OutboxItemState>();
  let seq = 0;
  let uuid = 0;
  let remainingOpenFailures = overrides?.failSessionOpens ?? 0;
  const uploads = new UploadEngine({
    blobs,
    bytes,
    transport: {
      openUploadSession: async (request) => {
        if (remainingOpenFailures > 0) {
          remainingOpenFailures -= 1;
          throw new Error('Hub unreachable');
        }
        return { result: 'already-present', blobId: request.blobId }; // dedupe: upload confirmed
      },
    },
    tus: {
      probe: async () => ({ offset: 0 }),
      uploadChunk: async () => ({ offset: 0 }),
    },
    enqueueLink: (envelope) => enqueued.push(envelope),
    linkState: (opId) => linkStates.get(opId),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  const flow = new CaptureFlow({
    uploads,
    persistBytes: async (blobId, data) => {
      const uri = `file:///captures/${blobId}`;
      bytes.put(uri, data);
      return uri;
    },
    gateState: () => overrides?.gate ?? UNLOCKED,
    identity: { generateUuid: () => `cap-${uuid++}` },
  });
  return { flow, uploads, blobs, bytes, enqueued, linkStates };
}

describe('capture', () => {
  it('anchors the SHA-256 at capture and stores the blob durably, locally preserved', async () => {
    const { flow, blobs, bytes } = makeFlow();
    const result = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'camera',
      attachmentKind: 'field-ticket-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
    });

    expect(result.status).toBe('captured');
    if (result.status !== 'captured') return;
    expect(result.sha256).toBe(sync.sha256Hex(PHOTO)); // real digest, not a stub
    const record = blobs.get(result.record.blobId);
    expect(record).toMatchObject({
      state: 'local-only',
      sha256: result.sha256,
      byteLength: 10,
      parentType: 'field-ticket',
      parentId: 'ft-1',
      attachmentKind: 'field-ticket-photo',
    });
    expect(bytes.has(record?.localUri as string)).toBe(true);
  });

  it('locked clock gate refuses capture — no bytes persisted, nothing registered', async () => {
    const { flow, blobs } = makeFlow({ gate: { state: 'locked', reason: 'hub-unreachable' } });
    const result = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'camera',
      attachmentKind: 'receipt-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
    });
    expect(result).toEqual({ status: 'locked', reason: 'hub-unreachable' });
    expect(blobs.list()).toHaveLength(0);
  });

  it('parent-link correctness: each kind links to its own parent and the link op carries it', async () => {
    const { flow, uploads, enqueued } = makeFlow();
    await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'camera',
      attachmentKind: 'disposal-photo',
      parentType: 'sr',
      parentId: 'sr-9',
      parentOpId: 'op-parent',
    });
    await flow.captureSignature({ bytes: PHOTO, parentType: 'jhajsa', parentId: 'jha-1' });

    await uploads.processOnce(); // dedupe-confirms uploads, enqueues links
    expect(enqueued).toHaveLength(2);
    const disposal = enqueued.find((e) => e.payload.attachmentKind === 'disposal-photo');
    const signature = enqueued.find((e) => e.payload.attachmentKind === 'signature');
    expect(disposal?.payload).toMatchObject({ parentType: 'sr', parentId: 'sr-9' });
    expect(disposal?.dependsOn).toEqual(['op-parent']); // link waits for its parent's commit
    expect(signature?.payload).toMatchObject({ parentType: 'jhajsa', parentId: 'jha-1' });
    expect(signature?.payload.idempotencyKey).not.toBe(disposal?.payload.idempotencyKey);
  });

  it('duplicate attachment ids: same blob is idempotent; a different blob refuses', async () => {
    const { flow, bytes } = makeFlow();
    const first = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'import',
      attachmentKind: 'receipt-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
      blobId: 'blob-1',
      attachmentId: 'att-1',
    });
    expect(first.status).toBe('captured');

    // Same blobId again → same record, no fork.
    const replay = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'import',
      attachmentKind: 'receipt-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
      blobId: 'blob-1',
      attachmentId: 'att-1',
    });
    expect(replay.status).toBe('captured');
    if (replay.status === 'captured') expect(replay.record.blobId).toBe('blob-1');

    // Same attachmentId bound to DIFFERENT bytes → loud refusal.
    await expect(
      flow.capture({
        bytes: new Uint8Array([9, 9, 9]),
        mimeType: 'image/jpeg',
        source: 'import',
        attachmentKind: 'receipt-photo',
        parentType: 'field-ticket',
        parentId: 'ft-1',
        blobId: 'blob-2',
        attachmentId: 'att-1',
      }),
    ).rejects.toThrow(/att-1 is already bound/);
    expect(bytes.has('file:///captures/blob-2')).toBe(false); // refused before writing bytes
  });

  it('a replay with the same blobId but different bytes is refused before local bytes change', async () => {
    const { flow, bytes } = makeFlow();
    const first = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'import',
      attachmentKind: 'field-ticket-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
      blobId: 'blob-1',
      attachmentId: 'att-1',
    });
    if (first.status !== 'captured') throw new Error('expected capture');

    await expect(
      flow.capture({
        bytes: new Uint8Array([9, 9, 9]),
        mimeType: 'image/jpeg',
        source: 'import',
        attachmentKind: 'field-ticket-photo',
        parentType: 'field-ticket',
        parentId: 'ft-1',
        blobId: 'blob-1',
        attachmentId: 'att-1',
      }),
    ).rejects.toThrow(/blobId blob-1 is already bound to different bytes/);
    await expect(bytes.read(first.record.localUri, 0, PHOTO.length)).resolves.toEqual(PHOTO);
  });

  it('retry: a transient session-open failure defers and a later sweep succeeds — bytes intact', async () => {
    const { flow, uploads, blobs, bytes } = makeFlow({ failSessionOpens: 1 });
    const result = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'camera',
      attachmentKind: 'field-ticket-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
    });
    if (result.status !== 'captured') throw new Error('expected capture');

    const first = await uploads.processOnce();
    expect(first.deferred).toBe(1);
    expect(blobs.get(result.record.blobId)?.state).toBe('local-only');
    expect(bytes.has(result.record.localUri)).toBe(true); // preserved across the failure

    const second = await uploads.processOnce();
    expect(second.dedupedAlreadyPresent).toBe(1);
    expect(blobs.get(result.record.blobId)?.state).toBe('uploaded');
  });

  it('purge gating + needs-review preservation: bytes survive until upload AND link commit', async () => {
    const { flow, uploads, blobs, bytes, linkStates } = makeFlow();
    const result = await flow.capture({
      bytes: PHOTO,
      mimeType: 'image/jpeg',
      source: 'camera',
      attachmentKind: 'field-ticket-photo',
      parentType: 'field-ticket',
      parentId: 'ft-1',
    });
    if (result.status !== 'captured') throw new Error('expected capture');
    await uploads.processOnce(); // uploaded + link enqueued
    const record = blobs.get(result.record.blobId);
    const linkOpId = record?.linkOpId as string;

    // Uploaded but link not committed → NOT purgeable.
    await uploads.purgeOnce();
    expect(bytes.has(result.record.localUri)).toBe(true);

    // Hub flags the link needs-review → blob preserved on-device, still not purgeable.
    linkStates.set(linkOpId, 'needs-review');
    await uploads.processOnce();
    await uploads.purgeOnce();
    expect(blobs.get(result.record.blobId)?.state).toBe('uploaded');
    expect(bytes.has(result.record.localUri)).toBe(true);

    // Only an ACCEPTED link makes it purgeable.
    linkStates.set(linkOpId, 'accepted');
    await uploads.processOnce();
    const purged = await uploads.purgeOnce();
    expect(purged).toEqual([result.record.blobId]);
    expect(bytes.has(result.record.localUri)).toBe(false);
  });
});
