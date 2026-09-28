/**
 * Domain seams for DVIR / JHA-JSA field forms. A form lives locally as an editable DRAFT, gets
 * COMPLETED (validated against the contracts rules), is ENQUEUED into the durable sync outbox
 * as an append-only evidence event, and ends ACCEPTED / NEEDS-REVIEW / REJECTED when Hub
 * answers. Once enqueued the payload is frozen — append-only evidence is never edited, and a
 * non-accepted outcome preserves the record (with Hub's reason) instead of deleting it.
 */
import type { fieldwork } from '@fieldcapture/contracts';

import type { StoreDurability } from './hubGateway';

export type FieldFormStatus =
  | 'draft'
  | 'completed'
  | 'enqueued'
  | 'accepted'
  | 'needs-review'
  | 'rejected';

export interface FieldFormRecord {
  form: fieldwork.FieldForm;
  status: FieldFormStatus;
  /** opId of the evidence operation in the sync outbox, once enqueued. */
  opId?: string;
  /** Hub's rejection code / review reason, preserved verbatim. */
  lastError?: string;
  createdAt: string;
  updatedAt: string;
}

export interface FieldFormStore {
  readonly durability: StoreDurability;
  save(record: FieldFormRecord): void;
  get(formId: string): FieldFormRecord | undefined;
  list(): FieldFormRecord[];
  listByStatus(status: FieldFormStatus): FieldFormRecord[];
}

/**
 * Field-form builders + signature helpers. The JHA/DVIR wizard screens are presentational, so the
 * durable record is assembled here. A form MUST carry at least one signature (the safety evidence
 * validateFormCompletion requires); the signature is the driver's captured artifact (blob) plus a
 * SignatureRecord of compliance metadata (ESIGN/UETA/FMCSA functional standard).
 */
export function signatureBytes(serialized: string): Uint8Array {
  // serializeSignature emits ASCII JSON; TextEncoder is available in Hermes (RN) and Node (jest).
  return new TextEncoder().encode(serialized);
}

export function buildSignatureRecord(p: {
  blobId: string;
  signerName: string;
  signerUserId?: string;
  signerRole?: string;
  signedAtUtc: string;
  certificationText: string;
  deviceInstanceId: string;
  appVersion: string;
}): fieldwork.SignatureRecord {
  return { ...p, consentToElectronicSignature: true };
}

export function jhaJsaForm(
  serviceRequestId: string,
  signatures: fieldwork.SignatureRecord | readonly fieldwork.SignatureRecord[],
): fieldwork.JhaForm {
  const records = Array.isArray(signatures) ? signatures : [signatures];
  return {
    formId: `jha-jsa-${serviceRequestId}`,
    kind: 'jha-jsa',
    serviceRequestId,
    hazards: [{ hazardId: 'h1', description: 'H2S exposure', mitigation: 'Monitor and ventilate' }],
    signatureBlobIds: records.map((signature) => signature.blobId),
    signatures: records,
  };
}

export function preTripDvirForm(
  serviceRequestId: string,
  vehicleRef: string,
  signature: fieldwork.SignatureRecord,
): fieldwork.DvirForm {
  return {
    formId: `pre-trip-dvir-${serviceRequestId}`,
    kind: 'pre-trip-dvir',
    vehicleRef,
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: [signature.blobId],
    signatures: [signature],
  };
}

export function postTripDvirForm(
  serviceRequestId: string,
  vehicleRef: string,
  signature: fieldwork.SignatureRecord,
): fieldwork.DvirForm {
  return {
    formId: `post-trip-dvir-${serviceRequestId}`,
    kind: 'post-trip-dvir',
    vehicleRef,
    items: [{ itemId: 'brakes', label: 'Brakes', result: 'ok' }],
    signatureBlobIds: [signature.blobId],
    signatures: [signature],
  };
}

/** In-memory form store. VOLATILE — TEST SEAM ONLY (production: SqliteFieldFormStore). */
export class VolatileFieldFormStore implements FieldFormStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private byId = new Map<string, FieldFormRecord>();

  save(record: FieldFormRecord): void {
    this.byId.set(record.form.formId, record);
  }

  get(formId: string): FieldFormRecord | undefined {
    return this.byId.get(formId);
  }

  list(): FieldFormRecord[] {
    return [...this.byId.values()];
  }

  listByStatus(status: FieldFormStatus): FieldFormRecord[] {
    return this.list().filter((r) => r.status === status);
  }
}
