import { describe, it, expect } from 'vitest';
import {
  validateFormCompletion,
  DVIR_PRETRIP_CERTIFICATION_TEXT,
  DVIR_POSTTRIP_CERTIFICATION_TEXT,
  JHA_CERTIFICATION_TEXT,
  type JhaForm,
  type SignatureRecord,
} from './forms';

const record: SignatureRecord = {
  blobId: 'blob-1',
  signerName: 'Alex Rivera',
  signerUserId: 'arivera',
  signerRole: 'Driver',
  signedAtUtc: '2026-06-21T12:00:00.000Z',
  certificationText: JHA_CERTIFICATION_TEXT,
  consentToElectronicSignature: true,
  deviceInstanceId: 'device-1',
  appVersion: '1.0.0',
};

describe('signature contract', () => {
  it('certification text constants are non-empty', () => {
    expect(DVIR_PRETRIP_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
    expect(DVIR_POSTTRIP_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
    expect(JHA_CERTIFICATION_TEXT.length).toBeGreaterThan(0);
  });

  it('a JHA carrying a signature record + blob id is completable', () => {
    const form: JhaForm = {
      formId: 'jha-jsa-sr-1',
      kind: 'jha-jsa',
      serviceRequestId: 'sr-1',
      hazards: [{ hazardId: 'h1', description: 'H2S', mitigation: 'monitor' }],
      signatureBlobIds: [record.blobId],
      signatures: [record],
    };
    expect(validateFormCompletion(form)).toEqual([]);
    expect(form.signatures).toEqual([expect.objectContaining({ signerRole: 'Driver' })]);
  });
});
