/**
 * Typed runtime config for the Ops Hub connection (first real integration slice).
 *
 * The Hub URL is baked in at build time via the native iOS config bridge (APP_ENV +
 * OPS_HUB_URL_* into Info.plist/Xcode settings; see src/config/env.ts). The session token is
 * a runtime value from the driver's sign-in (an auth slice owns producing it; callers pass it here).
 *
 * Both are REQUIRED to talk to Hub. A missing value throws a typed `HubConfigError` — the app
 * must fail visibly and keep work local rather than guess a Hub or fake a sync
 * (cross-cutting invariant #2).
 */
import { hubUrl as buildTimeHubUrl } from './env';

export class HubConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'HubConfigError';
  }
}

export interface HubRuntimeConfig {
  /** Normalized base URL (no trailing slash), e.g. "https://hub.example.com". */
  baseUrl: string;
  /** The signed-in driver's bearer token. Hub derives the employee from it — never from the client. */
  sessionToken: string;
}

/** True for hosts iOS ATS permits over cleartext: localhost, loopback, .local mDNS, private LAN IPv4. */
function isLocalHost(host: string): boolean {
  return (
    host === 'localhost' ||
    host === '127.0.0.1' ||
    host === '::1' ||
    host.endsWith('.local') ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host)
  );
}

/** Pure resolver — validates raw values into a usable config or throws `HubConfigError`. */
export function resolveHubRuntimeConfig(input: {
  hubUrl: unknown;
  sessionToken: unknown;
}): HubRuntimeConfig {
  const { hubUrl, sessionToken } = input;
  if (typeof hubUrl !== 'string' || hubUrl.length === 0) {
    throw new HubConfigError(
      'Ops Hub URL is not configured for this build. Set OPS_HUB_URL_<DEV|STAGING|PROD> for ' +
        'the APP_ENV this build targets (see .env.example). Refusing to guess a Hub — work stays local.',
    );
  }
  // Plain string parse (no `new URL`): React Native's URL support is not relied on here.
  const parsed = /^(https?):\/\/([^/:?\s]+)/i.exec(hubUrl);
  if (parsed === null) {
    throw new HubConfigError(
      `Ops Hub URL must be http(s)://host[...] — got "${hubUrl}". Check OPS_HUB_URL_* / APP_ENV.`,
    );
  }
  // Block cleartext http:// to a non-local Hub: iOS ATS (NSAllowsLocalNetworking only) silently
  // drops it AND it ships field data in the clear. http is allowed ONLY for localhost / LAN dev.
  if (parsed[1].toLowerCase() === 'http' && !isLocalHost(parsed[2].toLowerCase())) {
    throw new HubConfigError(
      `Refusing cleartext http:// to a non-local Hub ("${parsed[2]}"): iOS App Transport Security ` +
        'blocks it and it would send field data unencrypted. Use https:// for staging/prod ' +
        '(http:// is permitted only for localhost or a private LAN address in dev).',
    );
  }
  if (typeof sessionToken !== 'string' || sessionToken.length === 0) {
    throw new HubConfigError(
      'Missing Hub session token — the driver is not signed in (or the token was lost). ' +
        'Sign in again; unsynced work is preserved locally meanwhile.',
    );
  }
  return { baseUrl: hubUrl.replace(/\/+$/, ''), sessionToken };
}

/** Resolve from this build's native config + the caller-supplied session token. */
export function getHubRuntimeConfig(input: { sessionToken: unknown }): HubRuntimeConfig {
  return resolveHubRuntimeConfig({ hubUrl: buildTimeHubUrl, sessionToken: input.sessionToken });
}
