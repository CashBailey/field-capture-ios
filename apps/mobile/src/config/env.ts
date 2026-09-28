export type AppEnv = 'dev' | 'staging' | 'prod';

import { nativeAppEnv, nativeHubUrl } from './nativeConfig';

/** Which Ops Hub environment this build targets (dev | staging | prod). */
export const appEnv: AppEnv = nativeAppEnv;

/**
 * Base URL of the Ops Hub (the source of truth) for this build, or null if unconfigured.
 * Resolved from native iOS build settings / Info.plist by `FieldNativeConfig`.
 */
export const hubUrl: string | null = nativeHubUrl;
