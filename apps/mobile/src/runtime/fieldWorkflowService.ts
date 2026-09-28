/**
 * DVIR / JHA-JSA field-workflow runtime — the screen-level state machine behind the safety-form
 * flow (field-day-workflow.md: pre-trip DVIR → per-SR JHA → tickets → post-trip DVIR).
 *
 * Invariants:
 *  - Field actions are LOCKED unless the Hub clock gate is unlocked (`gateState` is the
 *    controller's cached gate). Locked = non-actionable, with the reason surfaced; the gate is
 *    UX-level — Hub still authoritatively re-validates every submit.
 *  - Completed forms sync as APPEND-ONLY evidence events through the durable sync outbox
 *    (`SyncEngine.enqueue` — same idempotency/retry/backoff rules as everything else; nothing
 *    here is durable until Hub accepts).
 *  - Once enqueued, a form is FROZEN: append-only evidence is never edited. A needs-review or
 *    rejected outcome preserves the record and Hub's verbatim reason — never deleted, never
 *    silently retried.
 *  - Ticket submission is gated on Hub-configured required steps (`checkTicketSubmitAllowed`);
 *    a flagged (needs-review/rejected) safety form does NOT satisfy its step.
 */
import { fieldwork, sync, SYNC_OP_TYPES } from '@fieldcapture/contracts';

type SyncOpType = (typeof SYNC_OP_TYPES)[number];
const JHA_JSA_OP: SyncOpType = 'jhajsa.submit';
const DVIR_OP: SyncOpType = 'dvir.submit';

import {
  fieldWorkGateLockReason,
  type FieldFormRecord,
  type FieldFormStatus,
  type FieldFormStore,
  type FieldWorkGate,
} from '../domain';
import type { WriteIdentity } from './uploadEngine';

export type WorkflowActionResult<T> =
  | { status: 'ok'; value: T }
  | { status: 'locked'; reason: string }
  | { status: 'invalid'; errors: string[] }
  | { status: 'not-found'; formId: string }
  | { status: 'frozen'; formId: string; recordStatus: FieldFormStatus };

/** Statuses that satisfy a required workflow step. Flagged evidence never greenlights work. */
const STEP_SATISFYING: ReadonlySet<FieldFormStatus> = new Set([
  'completed',
  'enqueued',
  'accepted',
]);

/** Statuses whose payload is frozen append-only evidence. */
const FROZEN: ReadonlySet<FieldFormStatus> = new Set([
  'enqueued',
  'accepted',
  'needs-review',
  'rejected',
]);

export interface FieldWorkflowDeps {
  forms: FieldFormStore;
  /** The controller's cached clock gate — refreshed elsewhere; consulted on every action. */
  gateState: () => FieldWorkGate;
  /** Enqueue an evidence event into the durable sync outbox (SyncEngine.enqueue). */
  enqueueEvidence: (envelope: sync.OperationEnvelope) => void;
  /** Outbox row for a previously enqueued op (SyncOutboxStore.get). */
  outboxItem: (
    opId: string,
  ) => { state: sync.OutboxItemState; rejectionCode?: string; lastError?: string } | undefined;
  /** Hub-configured workflow requirements (parsed from session/assignment config). */
  requirements: () => fieldwork.WorkflowRequirements;
  identity: WriteIdentity;
  now?: () => Date;
}

export class FieldWorkflowService {
  private readonly now: () => Date;

  constructor(private readonly deps: FieldWorkflowDeps) {
    this.now = deps.now ?? (() => new Date());
  }

  private locked(): { status: 'locked'; reason: string } | undefined {
    const gate = this.deps.gateState();
    return gate.state === 'locked'
      ? { status: 'locked', reason: fieldWorkGateLockReason(gate) }
      : undefined;
  }

  /**
   * Create or update a form draft. Editable only while the record is still local (draft /
   * completed-not-yet-enqueued); a frozen record refuses with its status.
   */
  saveDraft(form: fieldwork.FieldForm): WorkflowActionResult<FieldFormRecord> {
    const lock = this.locked();
    if (lock) return lock;
    const existing = this.deps.forms.get(form.formId);
    if (existing !== undefined && FROZEN.has(existing.status)) {
      return { status: 'frozen', formId: form.formId, recordStatus: existing.status };
    }
    const at = this.now().toISOString();
    const record: FieldFormRecord = {
      form,
      status: 'draft',
      createdAt: existing?.createdAt ?? at,
      updatedAt: at,
    };
    this.deps.forms.save(record);
    return { status: 'ok', value: record };
  }

  /** Validate and mark a draft complete (contracts `validateFormCompletion`). */
  completeForm(formId: string): WorkflowActionResult<FieldFormRecord> {
    const lock = this.locked();
    if (lock) return lock;
    const existing = this.deps.forms.get(formId);
    if (existing === undefined) return { status: 'not-found', formId };
    if (FROZEN.has(existing.status)) {
      return { status: 'frozen', formId, recordStatus: existing.status };
    }
    const errors = fieldwork.validateFormCompletion(existing.form);
    if (errors.length > 0) return { status: 'invalid', errors };
    const record: FieldFormRecord = {
      ...existing,
      form: { ...existing.form, completedAt: this.now().toISOString() },
      status: 'completed',
      updatedAt: this.now().toISOString(),
    };
    this.deps.forms.save(record);
    return { status: 'ok', value: record };
  }

  /**
   * Hand a completed form to the sync outbox as an append-only evidence event. The enqueue is
   * LOCAL (works offline); durability comes only from Hub's later accept. Idempotent: an
   * already-enqueued form returns frozen rather than minting a second operation.
   */
  submitForm(formId: string): WorkflowActionResult<FieldFormRecord> {
    const lock = this.locked();
    if (lock) return lock;
    const existing = this.deps.forms.get(formId);
    if (existing === undefined) return { status: 'not-found', formId };
    if (FROZEN.has(existing.status)) {
      return { status: 'frozen', formId, recordStatus: existing.status };
    }
    if (existing.status !== 'completed') {
      return {
        status: 'invalid',
        errors: [`form ${formId} is not completed (${existing.status})`],
      };
    }
    const opId = this.deps.identity.generateUuid();
    const localSeq = this.deps.identity.allocateLocalSeq();
    const envelope: sync.OperationEnvelope = {
      opId,
      kind: 'event', // append-only safety evidence — never carries a version precondition
      type: existing.form.kind === 'jha-jsa' ? JHA_JSA_OP : DVIR_OP,
      idempotencyKey: sync.buildIdempotencyKey(this.deps.identity.deviceInstanceId, localSeq, opId),
      localSeq,
      dependsOn: [],
      payload: existing.form,
    };
    this.deps.enqueueEvidence(envelope);
    const record: FieldFormRecord = {
      ...existing,
      status: 'enqueued',
      opId,
      updatedAt: this.now().toISOString(),
    };
    this.deps.forms.save(record);
    return { status: 'ok', value: record };
  }

  /**
   * Fold Hub outcomes from the sync outbox back onto form records. Accepted = durable;
   * needs-review / rejected = preserved + frozen with Hub's verbatim reason.
   */
  reconcileOutcomes(): { accepted: string[]; needsReview: string[]; rejected: string[] } {
    const result = {
      accepted: [] as string[],
      needsReview: [] as string[],
      rejected: [] as string[],
    };
    for (const record of this.deps.forms.listByStatus('enqueued')) {
      if (record.opId === undefined) continue;
      const op = this.deps.outboxItem(record.opId);
      if (op === undefined) continue;
      const at = this.now().toISOString();
      if (op.state === 'accepted') {
        this.deps.forms.save({ ...record, status: 'accepted', updatedAt: at });
        result.accepted.push(record.form.formId);
      } else if (op.state === 'needs-review') {
        this.deps.forms.save({
          ...record,
          status: 'needs-review',
          updatedAt: at,
          ...(op.lastError !== undefined ? { lastError: op.lastError } : {}),
        });
        result.needsReview.push(record.form.formId);
      } else if (op.state === 'rejected') {
        this.deps.forms.save({
          ...record,
          status: 'rejected',
          updatedAt: at,
          lastError: op.rejectionCode ?? op.lastError ?? 'rejected',
        });
        result.rejected.push(record.form.formId);
      }
      // pending / in-flight: still owed to Hub — leave enqueued.
    }
    return result;
  }

  /** The completed steps the ticket gate consults (flagged evidence does not count). */
  completedSteps(): fieldwork.CompletedWorkflowSteps {
    let preTripDvirFormId: string | undefined;
    let preTripVehicleUnsafe = false;
    const jhaFormIdByServiceRequest: Record<string, string> = {};
    for (const record of this.deps.forms.list()) {
      if (!STEP_SATISFYING.has(record.status)) continue;
      if (record.form.kind === 'pre-trip-dvir') {
        preTripDvirFormId = record.form.formId;
        if (fieldwork.dvirCertifiesUnsafe(record.form)) preTripVehicleUnsafe = true;
      }
      if (record.form.kind === 'jha-jsa') {
        jhaFormIdByServiceRequest[record.form.serviceRequestId] = record.form.formId;
      }
    }
    return {
      ...(preTripDvirFormId !== undefined ? { preTripDvirFormId } : {}),
      ...(preTripVehicleUnsafe ? { preTripVehicleUnsafe: true } : {}),
      jhaFormIdByServiceRequest,
    };
  }

  /** May a field ticket for this SR be submitted right now? Clock gate, unsafe-vehicle rule, then
   *  the Hub-configured required workflow steps. */
  guardTicketSubmit(serviceRequestId: string):
    | { status: 'allowed' }
    | { status: 'locked'; reason: string }
    | { status: 'vehicle-unsafe'; reviewRequired: true }
    | {
        status: 'blocked';
        missing: fieldwork.FieldFormKind[];
      } {
    const lock = this.locked();
    if (lock) return { status: 'locked', reason: lock.reason };
    const completed = this.completedSteps();
    // Hard safety gate: a pre-trip DVIR that certified the vehicle unsafe blocks field work for the
    // day and escalates to Hub review — independent of, and ahead of, the Hub-step gate.
    const safety = fieldwork.checkVehicleSafeToOperate(completed);
    if (!safety.safe) return { status: 'vehicle-unsafe', reviewRequired: true };
    const gate = fieldwork.checkTicketSubmitAllowed(
      this.deps.requirements(),
      completed,
      serviceRequestId,
    );
    return gate.allowed ? { status: 'allowed' } : { status: 'blocked', missing: gate.missing };
  }

  /**
   * Submit handoff: enforce the workflow gate, then delegate to the existing ticket submit path
   * (AppController.submitNewTicket / submitFieldTicket — idempotency and retry rules untouched).
   */
  async submitTicketWithWorkflow<T>(
    serviceRequestId: string,
    submit: () => Promise<T>,
  ): Promise<
    | { status: 'submitted'; result: T }
    | { status: 'locked'; reason: string }
    | { status: 'vehicle-unsafe'; reviewRequired: true }
    | { status: 'blocked'; missing: fieldwork.FieldFormKind[] }
  > {
    const guard = this.guardTicketSubmit(serviceRequestId);
    if (guard.status !== 'allowed') return guard;
    return { status: 'submitted', result: await submit() };
  }
}
