import { toByteArray } from 'base64-js';
import * as RNFS from 'react-native-fs';
import {
  launchCamera,
  launchImageLibrary,
  type CameraOptions,
  type ImageLibraryOptions,
  type ImagePickerResponse,
} from 'react-native-image-picker';

import type { CaptureSource } from '../../runtime';

export type EvidenceImageSource = Extract<CaptureSource, 'camera' | 'import'>;

export interface CapturedEvidenceImage {
  bytes: Uint8Array;
  mimeType: string;
  source: EvidenceImageSource;
  localUri: string;
}

interface ImagePickerLike {
  launchCamera(options: CameraOptions): Promise<ImagePickerResponse>;
  launchImageLibrary(options: ImageLibraryOptions): Promise<ImagePickerResponse>;
}

export interface EvidenceImageCaptureDeps {
  imagePicker?: ImagePickerLike;
  readBytes?: (uri: string) => Promise<Uint8Array>;
}

const IMAGE_PICKER_OPTIONS: CameraOptions & ImageLibraryOptions = {
  mediaType: 'photo',
  quality: 0.8,
  includeBase64: false,
};

async function readFileBytes(uri: string): Promise<Uint8Array> {
  const path = uri.startsWith('file://') ? uri.slice('file://'.length) : uri;
  return toByteArray(await RNFS.readFile(path, 'base64'));
}

function mimeFromUri(uri: string): string {
  const clean = uri.split('?')[0]?.toLowerCase() ?? uri.toLowerCase();
  if (clean.endsWith('.png')) return 'image/png';
  if (clean.endsWith('.webp')) return 'image/webp';
  if (clean.endsWith('.gif')) return 'image/gif';
  if (clean.endsWith('.heic')) return 'image/heic';
  if (clean.endsWith('.heif')) return 'image/heif';
  return 'image/jpeg';
}

/**
 * Capture/import one still image for field evidence. The native picker returns a local file URI;
 * we read the bytes immediately and hand them to CaptureFlow, which hashes and persists them under
 * the app's protected capture directory. Cancel/permission-denied returns null: no fake evidence.
 */
export async function captureEvidenceImage(
  source: EvidenceImageSource,
  deps: EvidenceImageCaptureDeps = {},
): Promise<CapturedEvidenceImage | null> {
  const picker = deps.imagePicker ?? { launchCamera, launchImageLibrary };
  const result =
    source === 'camera'
      ? await picker.launchCamera(IMAGE_PICKER_OPTIONS)
      : await picker.launchImageLibrary({ ...IMAGE_PICKER_OPTIONS, selectionLimit: 1 });

  if (result.didCancel === true || result.errorCode === 'permission') return null;

  const asset = result.assets?.[0];
  if (asset?.uri === undefined) return null;
  if (asset.type !== undefined && !asset.type.startsWith('image/')) return null;

  const bytes = await (deps.readBytes ?? readFileBytes)(asset.uri);
  return {
    bytes,
    mimeType: asset.type ?? mimeFromUri(asset.uri),
    source,
    localUri: asset.uri,
  };
}
