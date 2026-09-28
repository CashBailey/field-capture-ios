import { fieldwork } from '@fieldcapture/contracts';

const unlockedSr = (over: Partial<fieldwork.ServiceRequest> = {}): fieldwork.ServiceRequest => ({
  srId: 'sr-1',
  version: 1,
  ownerRef: 'emp-1',
  assistantRefs: [],
  lockState: 'unlocked',
  workStartedAt: null,
  lockedByEventId: null,
  ...over,
});

const arrived = (actorRef: string): fieldwork.WorkStartEvent => ({
  eventId: 'ev-1',
  srId: 'sr-1',
  kind: 'arrived',
  actorRef,
  occurredAt: 't1',
});

describe('fieldwork domain rules (Slice 4)', () => {
  it('resolves the contracts fieldwork module at runtime (value import)', () => {
    expect(typeof fieldwork.resolveWorkStart).toBe('function');
    expect(typeof fieldwork.amendTicket).toBe('function');
  });

  it('locks an SR on the first authorized work-start', () => {
    const out = fieldwork.resolveWorkStart(unlockedSr(), arrived('emp-1'), new Set(['emp-1']));
    expect(out.decision).toBe('locked');
  });

  it('preserves an offline work-start from a reassigned actor as needs-review (work is never lost)', () => {
    const out = fieldwork.resolveWorkStart(
      unlockedSr({ ownerRef: 'newOwner', version: 2 }),
      arrived('oldOwner'),
      new Set(['newOwner']),
    );
    expect(out.decision).toBe('needs-review');
  });
});
