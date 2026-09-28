import { sync } from '@fieldcapture/contracts';

import { WorkStartService } from '../src/runtime';
import type { FieldWorkGate } from '../src/domain';

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
  employeeId: 'emp-1',
};
const LOCKED: FieldWorkGate = { state: 'locked', reason: 'not-clocked-in' };

function makeService(gate: FieldWorkGate = UNLOCKED) {
  const enqueued: sync.OperationEnvelope[] = [];
  let seq = 0;
  let uuid = 0;
  const service = new WorkStartService({
    gateState: () => gate,
    enqueueEvent: (envelope) => enqueued.push(envelope),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `op-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { service, enqueued };
}

describe('WorkStartService', () => {
  it('queues an immutable work.start event with coherent write identity', () => {
    const { service, enqueued } = makeService();

    const result = service.startWork({ serviceRequestId: 'sr-9', actorRef: 'emp-1' });

    expect(result.status).toBe('ok');
    expect(enqueued).toHaveLength(1);
    expect(enqueued[0]).toMatchObject({
      opId: 'op-0',
      kind: 'event',
      type: 'work.start',
      localSeq: 0,
      dependsOn: [],
      payload: {
        eventId: 'op-0',
        srId: 'sr-9',
        kind: 'work-event-submitted',
        actorRef: 'emp-1',
        occurredAt: '2026-06-10T12:00:00.000Z',
      },
    });
    expect(enqueued[0].precondition).toBeUndefined();
    sync.assertEnvelopeConsistent(enqueued[0]);
  });

  it('keeps work-start non-actionable while the clock gate is locked', () => {
    const { service, enqueued } = makeService(LOCKED);

    expect(service.startWork({ serviceRequestId: 'sr-9', actorRef: 'emp-1' })).toEqual({
      status: 'locked',
      reason: 'not-clocked-in',
    });
    expect(enqueued).toHaveLength(0);
  });

  it('refuses empty ids instead of queuing ambiguous evidence', () => {
    const { service, enqueued } = makeService();

    expect(service.startWork({ serviceRequestId: ' ', actorRef: '' })).toEqual({
      status: 'invalid',
      errors: ['service request is required', 'actor is required'],
    });
    expect(enqueued).toHaveLength(0);
  });
});
