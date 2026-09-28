/**
 * Work-start runtime: records the immutable event that lets Hub derive the SR lock.
 *
 * Mobile only queues evidence; Hub still validates clock-in, actor authorization, assignment drift,
 * and whether this is the first accepted work-start event for the SR.
 */
import { fieldwork, sync, SYNC_OP_TYPES } from '@fieldcapture/contracts';

import { fieldWorkGateLockReason, type FieldWorkGate } from '../domain';
import type { WriteIdentity } from './uploadEngine';

type SyncOpType = (typeof SYNC_OP_TYPES)[number];
const WORK_START_OP: SyncOpType = 'work.start';

export type WorkStartResult =
  | { status: 'ok'; envelope: sync.OperationEnvelope<fieldwork.WorkStartEvent> }
  | { status: 'locked'; reason: string }
  | { status: 'invalid'; errors: string[] };

export interface WorkStartInput {
  serviceRequestId: string;
  actorRef: string;
  kind?: fieldwork.WorkStartKind;
}

export interface WorkStartServiceDeps {
  /** The controller's cached clock gate; Hub authoritatively re-validates on sync. */
  gateState: () => FieldWorkGate;
  /** Enqueue the immutable work-start event in the same durable outbox as DVIR/JHA evidence. */
  enqueueEvent: (envelope: sync.OperationEnvelope<fieldwork.WorkStartEvent>) => void;
  identity: WriteIdentity;
  now?: () => Date;
}

export class WorkStartService {
  private readonly now: () => Date;

  constructor(private readonly deps: WorkStartServiceDeps) {
    this.now = deps.now ?? (() => new Date());
  }

  startWork(input: WorkStartInput): WorkStartResult {
    const gate = this.deps.gateState();
    if (gate.state === 'locked') return { status: 'locked', reason: fieldWorkGateLockReason(gate) };

    const srId = input.serviceRequestId.trim();
    const actorRef = input.actorRef.trim();
    const errors: string[] = [];
    if (srId.length === 0) errors.push('service request is required');
    if (actorRef.length === 0) errors.push('actor is required');
    if (errors.length > 0) return { status: 'invalid', errors };

    const opId = this.deps.identity.generateUuid();
    const localSeq = this.deps.identity.allocateLocalSeq();
    const payload: fieldwork.WorkStartEvent = {
      eventId: opId,
      srId,
      kind: input.kind ?? 'work-event-submitted',
      actorRef,
      occurredAt: this.now().toISOString(),
    };
    const envelope: sync.OperationEnvelope<fieldwork.WorkStartEvent> = {
      opId,
      kind: 'event',
      type: WORK_START_OP,
      idempotencyKey: sync.buildIdempotencyKey(this.deps.identity.deviceInstanceId, localSeq, opId),
      localSeq,
      dependsOn: [],
      payload,
    };
    sync.assertEnvelopeConsistent(envelope);
    this.deps.enqueueEvent(envelope);
    return { status: 'ok', envelope };
  }
}
