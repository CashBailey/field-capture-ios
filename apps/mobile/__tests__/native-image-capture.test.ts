import type { ImagePickerResponse } from 'react-native-image-picker';

import { captureEvidenceImage, type EvidenceImageSource } from '../src/adapters/device';

function asset(uri: string, mimeType?: string): ImagePickerResponse {
  return {
    assets: [
      {
        uri,
        width: 100,
        height: 100,
        ...(mimeType !== undefined ? { type: mimeType } : {}),
      },
    ],
  };
}

function picker(result: ImagePickerResponse) {
  return {
    launchCamera: jest.fn().mockResolvedValue(result),
    launchImageLibrary: jest.fn().mockResolvedValue(result),
  };
}

function readBytes(bytes = new Uint8Array([1, 2, 3])) {
  return jest.fn(async () => bytes);
}

describe('captureEvidenceImage', () => {
  it('captures camera image bytes through the native camera picker', async () => {
    const p = picker(asset('file:///camera/photo.jpg', 'image/jpeg'));
    const read = readBytes(new Uint8Array([9, 8, 7]));

    await expect(
      captureEvidenceImage('camera', { imagePicker: p, readBytes: read }),
    ).resolves.toEqual({
      bytes: new Uint8Array([9, 8, 7]),
      mimeType: 'image/jpeg',
      source: 'camera',
      localUri: 'file:///camera/photo.jpg',
    });
    expect(p.launchCamera).toHaveBeenCalledWith(
      expect.objectContaining({ mediaType: 'photo', quality: 0.8 }),
    );
    expect(read).toHaveBeenCalledWith('file:///camera/photo.jpg');
  });

  it('imports library image bytes and infers MIME type from the URI when needed', async () => {
    const p = picker(asset('file:///library/receipt.png'));

    await expect(
      captureEvidenceImage('import', { imagePicker: p, readBytes: readBytes() }),
    ).resolves.toMatchObject({
      mimeType: 'image/png',
      source: 'import' satisfies EvidenceImageSource,
      localUri: 'file:///library/receipt.png',
    });
    expect(p.launchImageLibrary).toHaveBeenCalledWith(
      expect.objectContaining({ mediaType: 'photo', selectionLimit: 1 }),
    );
  });

  it('returns null when the native picker reports permission denial', async () => {
    const p = picker({ errorCode: 'permission', errorMessage: 'denied' });

    await expect(
      captureEvidenceImage('camera', { imagePicker: p, readBytes: readBytes() }),
    ).resolves.toBeNull();
  });

  it('returns null when the user cancels the native picker', async () => {
    const p = picker({ didCancel: true });

    await expect(
      captureEvidenceImage('import', { imagePicker: p, readBytes: readBytes() }),
    ).resolves.toBeNull();
  });
});
