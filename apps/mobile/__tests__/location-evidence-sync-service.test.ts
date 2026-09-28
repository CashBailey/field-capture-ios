import { sync } from '@fieldcapture/contracts';

import { LocationEvidenceSyncService } from '../src/runtime';

const EVIDENCE = {
  id: 'loc-1',
  serviceRequestId: 'sr-9',
  placeKind: 'well-site' as const,
  evidenceType: 'arrival',
  gps: { lat: 31.5, lon: -102.1, accuracyM: 6, timestampMs: 1_750_000_000_000 },
  state: 'verified' as const,
  createdAt: '2026-06-10T12:00:00.000Z',
};

function makeService() {
  const enqueued: sync.OperationEnvelope[] = [];
  let seq = 0;
  let uuid = 0;
  const service = new LocationEvidenceSyncService({
    enqueueEvent: (envelope) => enqueued.push(envelope),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `op-${uuid++}`,
    },
  });
  return { service, enqueued };
}

describe('LocationEvidenceSyncService', () => {
  it('queues saved location evidence as an immutable location.evidence event', () => {
    const { service, enqueued } = makeService();

    const result = service.enqueue(EVIDENCE);

    expect(result.status).toBe('ok');
    expect(enqueued).toHaveLength(1);
    expect(enqueued[0]).toMatchObject({
      opId: 'op-0',
      kind: 'event',
      type: 'location.evidence',
      localSeq: 0,
      dependsOn: [],
      payload: EVIDENCE,
    });
    expect(enqueued[0].precondition).toBeUndefined();
    sync.assertEnvelopeConsistent(enqueued[0]);
  });

  it('refuses ambiguous evidence instead of queuing an unrouteable event', () => {
    const { service, enqueued } = makeService();

    expect(
      service.enqueue({ ...EVIDENCE, id: ' ', serviceRequestId: '', evidenceType: '' }),
    ).toEqual({
      status: 'invalid',
      errors: [
        'location evidence id is required',
        'service request is required',
        'evidence type is required',
      ],
    });
    expect(enqueued).toHaveLength(0);
  });
});
