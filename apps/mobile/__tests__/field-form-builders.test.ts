import { fieldwork } from '@fieldcapture/contracts';

import {
  jhaJsaForm,
  preTripDvirForm,
  postTripDvirForm,
  buildSignatureRecord,
  signatureBytes,
} from '../src/domain/fieldForms';

function record(blobId: string, signerRole = 'Driver'): fieldwork.SignatureRecord {
  return buildSignatureRecord({
    blobId,
    signerName: 'Alex Rivera',
    signerUserId: 'arivera',
    signerRole,
    signedAtUtc: '2026-06-21T12:00:00.000Z',
    certificationText: fieldwork.JHA_CERTIFICATION_TEXT,
    deviceInstanceId: 'device-1',
    appVersion: '1.0.0',
  });
}

describe('field-form builders carry the real signature', () => {
  it('buildSignatureRecord stamps consent=true and keeps fields', () => {
    const r = record('blob-1');
    expect(r).toMatchObject({
      blobId: 'blob-1',
      signerRole: 'Driver',
      consentToElectronicSignature: true,
    });
  });

  it('signatureBytes encodes the serialized vector to bytes round-trippably', () => {
    const s = '{"v":1,"strokes":[[[1,2],[3,4]]]}';
    const bytes = signatureBytes(s);
    expect(bytes).toBeInstanceOf(Uint8Array);
    expect(Buffer.from(bytes).toString('utf8')).toBe(s);
  });

  it('jhaJsaForm carries all blob ids + signature records and is completable', () => {
    const form = jhaJsaForm('sr-1', [record('sig-driver'), record('sig-owner', 'Owner')]);
    expect(form.signatureBlobIds).toEqual(['sig-driver', 'sig-owner']);
    expect(form.signatures).toEqual([
      expect.objectContaining({ blobId: 'sig-driver', signerRole: 'Driver' }),
      expect.objectContaining({ blobId: 'sig-owner', signerRole: 'Owner' }),
    ]);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });

  it('preTripDvirForm carries the blob id + record and is completable', () => {
    const form = preTripDvirForm('sr-1', 'truck-7', record('sig-pre'));
    expect(form.signatureBlobIds).toEqual(['sig-pre']);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });

  it('postTripDvirForm carries the blob id + record and is completable', () => {
    const form = postTripDvirForm('sr-1', 'truck-7', record('sig-post'));
    expect(form.signatureBlobIds).toEqual(['sig-post']);
    expect(fieldwork.validateFormCompletion(form)).toEqual([]);
  });
});
