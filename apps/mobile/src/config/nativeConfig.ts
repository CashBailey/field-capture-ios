import { NativeModules } from 'react-native';

import type { AppEnv } from './env';

interface FieldNativeConfigModule {
  appEnv?: unknown;
  hubUrl?: unknown;
  appVersion?: unknown;
}

const nativeConfig = NativeModules.FieldNativeConfig as FieldNativeConfigModule | undefined;

function appEnvFrom(value: unknown): AppEnv {
  return value === 'staging' || value === 'prod' ? value : 'dev';
}

function optionalString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
}

export const nativeAppEnv: AppEnv = appEnvFrom(nativeConfig?.appEnv);
export const nativeHubUrl: string | null = optionalString(nativeConfig?.hubUrl);
export const nativeAppVersion: string | null = optionalString(nativeConfig?.appVersion);
