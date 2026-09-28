/**
 * DVIR / JHA-JSA workflow runtime: drafts durable, completion validated, completed forms synced
 * as append-only evidence through the durable outbox, Hub-required steps gate ticket
 * submission, the clock gate locks every field action, and needs-review outcomes are preserved
 * frozen with Hub's verbatim reason.
 */
import { fieldwork, sync } from '@fieldcapture/contracts';

import { migrate, SqliteFieldFormStore } from '../src/data';
import { VolatileFieldFormStore, type FieldWorkGate } from '../src/domain';
import { FieldWorkflowService, type FieldWorkflowDeps } from '../src/runtime';
import { betterSqliteDriver, type TestSqlDriver } from '../test-utils/betterSqliteDriver';

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
};
const LOCKED: FieldWorkGate = { state: 'locked', reason: 'not-clocked-in' };

const ALL_REQUIRED: fieldwork.WorkflowRequirements = {
  clockInRequired: true,
  requiredSteps: ['pre_trip_dvir', 'jha', 'post_trip_dvir'],
};

function dvir(overrides?: Partial<fieldwork.DvirForm>): fieldwork.DvirForm {
  return {
    formId: 'dvir-1',
    kind: 'pre-trip-dvir',
    vehicleRef: 'truck-7',
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: ['sig-1'],
    ...overrides,
  };
}

function jha(overrides?: Partial<fieldwork.JhaForm>): fieldwork.JhaForm {
  return {
    formId: 'jha-1',
    kind: 'jha-jsa',
    serviceRequestId: 'sr-9',
    hazards: [{ hazardId: 'h1', description: 'H2S', mitigation: 'monitor' }],
    signatureBlobIds: ['sig-2'],
    ...overrides,
  };
}

function makeService(overrides?: {
  gate?: () => FieldWorkGate;
  forms?: FieldWorkflowDeps['forms'];
  requirements?: fieldwork.WorkflowRequirements;
}) {
  const forms = overrides?.forms ?? new VolatileFieldFormStore();
  const enqueued: sync.OperationEnvelope[] = [];
  const outcomes = new Map<
    string,
    { state: sync.OutboxItemState; rejectionCode?: string; lastError?: string }
  >();
  let seq = 0;
  let uuid = 0;
  const service = new FieldWorkflowService({
    forms,
    gateState: overrides?.gate ?? (() => UNLOCKED),
    enqueueEvidence: (envelope) => enqueued.push(envelope),
    outboxItem: (opId) => outcomes.get(opId),
    requirements: () => overrides?.requirements ?? ALL_REQUIRED,
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `uuid-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { service, forms, enqueued, outcomes };
}

describe('draft save', () => {
  it('persists a draft durably (real SQLite) and round-trips it', () => {
    const db: TestSqlDriver = betterSqliteDriver();
    migrate(db);
    const forms = new SqliteFieldFormStore(db, 'durable-plain');
    const { service } = makeService({ forms });

    const result = service.saveDraft(dvir({ items: [{ itemId: 'brakes', label: 'Brakes' }] }));
    expect(result.status).toBe('ok');
    expect(forms.get('dvir-1')).toMatchObject({ status: 'draft' });
    expect(forms.get('dvir-1')?.form).toMatchObject({
      kind: 'pre-trip-dvir',
      vehicleRef: 'truck-7',
    });
    db.close();
  });

  it('a locked clock gate makes every field action non-actionable, with the reason surfaced', () => {
    const { service } = makeService({ gate: () => LOCKED });
    expect(service.saveDraft(dvir())).toEqual({ status: 'locked', reason: 'not-clocked-in' });
    expect(service.completeForm('dvir-1')).toEqual({ status: 'locked', reason: 'not-clocked-in' });
    expect(service.submitForm('dvir-1')).toEqual({ status: 'locked', reason: 'not-clocked-in' });
    expect(service.guardTicketSubmit('sr-9')).toEqual({
      status: 'locked',
      reason: 'not-clocked-in',
    });
  });
});

describe('required step completion', () => {
  it('an incomplete form refuses completion with the exact reasons', () => {
    const { service } = makeService();
    service.saveDraft(
      dvir({ items: [{ itemId: 'brakes', label: 'Brakes' }], signatureBlobIds: [] }),
    );
    const result = service.completeForm('dvir-1');
    expect(result).toEqual({
      status: 'invalid',
      errors: expect.arrayContaining([
        'inspection item brakes is unanswered',
        "DVIR needs the driver's signature",
      ]),
    });
  });

  it('a JHA without a signature never completes — the signature IS the safety evidence', () => {
    const { service } = makeService();
    service.saveDraft(jha({ signatureBlobIds: [] }));
    expect(service.completeForm('jha-1')).toMatchObject({ status: 'invalid' });
  });

  it('a valid form completes and is stamped', () => {
    const { service, forms } = makeService();
    service.saveDraft(dvir());
    expect(service.completeForm('dvir-1').status).toBe('ok');
    expect(forms.get('dvir-1')).toMatchObject({ status: 'completed' });
    expect((forms.get('dvir-1')?.form as fieldwork.DvirForm).completedAt).toBeDefined();
  });
});

describe('offline capture → append-only evidence', () => {
  it('submitForm enqueues an append-only event with real write identity; record freezes', () => {
    const { service, forms, enqueued } = makeService();
    service.saveDraft(jha());
    service.completeForm('jha-1');
    const result = service.submitForm('jha-1');

    expect(result.status).toBe('ok');
    expect(enqueued).toHaveLength(1);
    expect(enqueued[0]).toMatchObject({
      kind: 'event',
      type: 'jhajsa.submit',
      dependsOn: [],
    });
    expect(enqueued[0].precondition).toBeUndefined(); // append-only events carry none
    sync.assertEnvelopeConsistent(enqueued[0]);
    expect(forms.get('jha-1')).toMatchObject({ status: 'enqueued', opId: enqueued[0].opId });

    // Frozen: append-only evidence is never edited or re-submitted.
    expect(service.saveDraft(jha())).toMatchObject({ status: 'frozen' });
    expect(service.submitForm('jha-1')).toMatchObject({ status: 'frozen' });
    expect(enqueued).toHaveLength(1);
  });

  it('the enqueue is local — it works with the transport offline (nothing marked durable)', () => {
    // No outbox outcome ever arrives; the record stays enqueued, never accepted.
    const { service, forms } = makeService();
    service.saveDraft(dvir());
    service.completeForm('dvir-1');
    service.submitForm('dvir-1');
    service.reconcileOutcomes();
    expect(forms.get('dvir-1')?.status).toBe('enqueued'); // owed to Hub, preserved
  });

  it('a draft cannot be submitted before completion', () => {
    const { service } = makeService();
    service.saveDraft(dvir());
    expect(service.submitForm('dvir-1')).toMatchObject({ status: 'invalid' });
  });
});

describe('outcome reconciliation', () => {
  function enqueuedForm(s: ReturnType<typeof makeService>) {
    s.service.saveDraft(jha());
    s.service.completeForm('jha-1');
    s.service.submitForm('jha-1');
    return s.forms.get('jha-1')?.opId as string;
  }

  it('accepted → durable', () => {
    const s = makeService();
    const opId = enqueuedForm(s);
    s.outcomes.set(opId, { state: 'accepted' });
    expect(s.service.reconcileOutcomes().accepted).toEqual(['jha-1']);
    expect(s.forms.get('jha-1')?.status).toBe('accepted');
  });

  it('needs-review → preserved frozen with Hub`s reason; step no longer satisfied', () => {
    const s = makeService();
    const opId = enqueuedForm(s);
    s.outcomes.set(opId, { state: 'needs-review', lastError: 'assignment_changed' });
    expect(s.service.reconcileOutcomes().needsReview).toEqual(['jha-1']);
    const record = s.forms.get('jha-1');
    expect(record).toMatchObject({ status: 'needs-review', lastError: 'assignment_changed' });
    expect(record?.form).toMatchObject({ formId: 'jha-1' }); // payload preserved, never wiped
    // Flagged safety evidence does NOT greenlight more work on that SR.
    expect(s.service.completedSteps().jhaFormIdByServiceRequest['sr-9']).toBeUndefined();
    // And it stays frozen against edits.
    expect(s.service.saveDraft(jha())).toMatchObject({ status: 'frozen' });
  });

  it('rejected → preserved frozen with the rejection code verbatim', () => {
    const s = makeService();
    const opId = enqueuedForm(s);
    s.outcomes.set(opId, { state: 'rejected', rejectionCode: 'locked_sr' });
    expect(s.service.reconcileOutcomes().rejected).toEqual(['jha-1']);
    expect(s.forms.get('jha-1')).toMatchObject({ status: 'rejected', lastError: 'locked_sr' });
  });
});

describe('ticket submit gating (missing-step block + handoff)', () => {
  it('blocks ticket submission listing the exact missing Hub-required steps', () => {
    const { service } = makeService();
    expect(service.guardTicketSubmit('sr-9')).toEqual({
      status: 'blocked',
      missing: ['pre-trip-dvir', 'jha-jsa'],
    });
  });

  it('submit handoff delegates ONLY once the workflow allows', async () => {
    const { service } = makeService();
    const submit = jest.fn().mockResolvedValue({ status: 'accepted' });

    const blocked = await service.submitTicketWithWorkflow('sr-9', submit);
    expect(blocked).toMatchObject({ status: 'blocked' });
    expect(submit).not.toHaveBeenCalled();

    // Complete the required steps.
    service.saveDraft(dvir());
    service.completeForm('dvir-1');
    service.saveDraft(jha());
    service.completeForm('jha-1');

    const handed = await service.submitTicketWithWorkflow('sr-9', submit);
    expect(handed).toEqual({ status: 'submitted', result: { status: 'accepted' } });
    expect(submit).toHaveBeenCalledTimes(1); // existing submit path untouched (same idempotency)
  });

  it('a JHA for another SR does not unblock this SR', () => {
    const { service } = makeService();
    service.saveDraft(dvir());
    service.completeForm('dvir-1');
    service.saveDraft(jha({ formId: 'jha-x', serviceRequestId: 'sr-other' }));
    service.completeForm('jha-x');
    expect(service.guardTicketSubmit('sr-9')).toEqual({ status: 'blocked', missing: ['jha-jsa'] });
  });

  it('when Hub requires nothing, the gate is open (Hub still re-validates on submit)', () => {
    const { service } = makeService({
      requirements: {
        clockInRequired: true,
        requiredSteps: [],
      },
    });
    expect(service.guardTicketSubmit('sr-9')).toEqual({ status: 'allowed' });
  });
});

describe('unsafe-vehicle rule (defectsCertifiedSafe=false blocks field work)', () => {
  function completeUnsafePreTrip(service: ReturnType<typeof makeService>['service']) {
    service.saveDraft(
      dvir({
        items: [{ itemId: 'brakes', label: 'Brakes', result: 'defect', note: 'soft pedal' }],
        defectsCertifiedSafe: false,
      }),
    );
    expect(service.completeForm('dvir-1').status).toBe('ok');
  }

  it('guardTicketSubmit returns vehicle-unsafe (review required), ahead of the step gate', () => {
    const { service } = makeService({ requirements: { clockInRequired: true, requiredSteps: [] } });
    completeUnsafePreTrip(service);
    expect(service.guardTicketSubmit('sr-9')).toEqual({
      status: 'vehicle-unsafe',
      reviewRequired: true,
    });
  });

  it('submitTicketWithWorkflow refuses to run submit while the vehicle is unsafe', async () => {
    const { service } = makeService({ requirements: { clockInRequired: true, requiredSteps: [] } });
    completeUnsafePreTrip(service);
    let ran = false;
    const result = await service.submitTicketWithWorkflow('sr-9', async () => {
      ran = true;
      return 'submitted';
    });
    expect(result).toEqual({ status: 'vehicle-unsafe', reviewRequired: true });
    expect(ran).toBe(false);
  });

  it('a safe pre-trip DVIR (defect cleared) does not trip the rule', () => {
    const { service } = makeService({ requirements: { clockInRequired: true, requiredSteps: [] } });
    service.saveDraft(
      dvir({
        items: [{ itemId: 'brakes', label: 'Brakes', result: 'defect', note: 'adjusted' }],
        defectsCertifiedSafe: true,
      }),
    );
    expect(service.completeForm('dvir-1').status).toBe('ok');
    expect(service.guardTicketSubmit('sr-9')).toEqual({ status: 'allowed' });
  });
});
