/**
 * Location-evidence sync runtime. The LocationValidationScreen owns capture/classification and the
 * durable store owns preservation; this service only queues the immutable Hub event owed for a
 * saved evidence row.
 */
import { fieldwork, sync, SYNC_OP_TYPES } from '@fieldcapture/contracts';

import type { WriteIdentity } from './uploadEngine';

type SyncOpType = (typeof SYNC_OP_TYPES)[number];
const LOCATION_EVIDENCE_OP: SyncOpType = 'location.evidence';

export type LocationEvidenceSyncResult =
  | { status: 'ok'; envelope: sync.OperationEnvelope<fieldwork.LocationEvidence> }
  | { status: 'invalid'; errors: string[] };

export interface LocationEvidenceSyncDeps {
  enqueueEvent: (envelope: sync.OperationEnvelope<fieldwork.LocationEvidence>) => void;
  identity: WriteIdentity;
}

export class LocationEvidenceSyncService {
  constructor(private readonly deps: LocationEvidenceSyncDeps) {}

  enqueue(evidence: fieldwork.LocationEvidence): LocationEvidenceSyncResult {
    const errors: string[] = [];
    if (evidence.id.trim().length === 0) errors.push('location evidence id is required');
    if (evidence.serviceRequestId.trim().length === 0) {
      errors.push('service request is required');
    }
    if (evidence.evidenceType.trim().length === 0) errors.push('evidence type is required');
    if (errors.length > 0) return { status: 'invalid', errors };

    const opId = this.deps.identity.generateUuid();
    const localSeq = this.deps.identity.allocateLocalSeq();
    const envelope: sync.OperationEnvelope<fieldwork.LocationEvidence> = {
      opId,
      kind: 'event',
      type: LOCATION_EVIDENCE_OP,
      idempotencyKey: sync.buildIdempotencyKey(this.deps.identity.deviceInstanceId, localSeq, opId),
      localSeq,
      dependsOn: [],
      payload: evidence,
    };
    sync.assertEnvelopeConsistent(envelope);
    this.deps.enqueueEvent(envelope);
    return { status: 'ok', envelope };
  }
}
