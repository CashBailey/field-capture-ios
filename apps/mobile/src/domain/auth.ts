/**
 * Session auth slice: login, secure token storage, expiry/refresh handling, logout.
 *
 * Hub derives the employee from the bearer token — Mobile only carries the token (contract
 * boundary). The rules here:
 *  - Every auth operation resolves to a typed STATE, never an unhandled throw and never a hang
 *    (the API adapter is time-bounded).
 *  - An expired/expiring token is refreshed when a refresh token exists; otherwise the caller
 *    gets `auth-required` and must re-login. Nothing ever "probably authenticated".
 *  - Logout clears the token ONLY. Unsynced evidence is preserved — signing out must never
 *    destroy field work (the durable store keeps it for the next sign-in).
 */
import { toByteArray } from 'base64-js';

import type { StoreDurability } from './hubGateway';

export interface AuthSession {
  sessionToken: string;
  /** ISO 8601 expiry as Hub reported it; absent = Hub did not say (treated as non-expiring). */
  expiresAt?: string;
  refreshToken?: string;
  userProfile?: UserProfile;
}

/** Hub-authenticated user profile returned by `GET /api/v1/me`. */
export interface UserProfile {
  id?: string;
  username?: string;
  email?: string;
  displayName?: string;
  title?: string;
  department?: string;
  isActive?: boolean;
  employeeId?: string;
  phone?: string;
  assignedYard?: string;
  defaultTruck?: string;
  defaultTrailer?: string;
  accessProfile?: string;
  roles?: string[];
  language?: string;
}

/** Where the session lives between launches. The real one is the device keychain. */
export interface TokenStore {
  readonly durability: StoreDurability;
  load(): Promise<AuthSession | null>;
  save(session: AuthSession): Promise<void>;
  clear(): Promise<void>;
}

/** Every expected Hub answer as data; only `authenticated` yields a usable session. */
export type AuthApiResult =
  | { outcome: 'authenticated'; session: AuthSession }
  | { outcome: 'invalid-credentials'; httpStatus: number; detail?: string }
  | { outcome: 'transient'; reason: 'network' | 'server' | 'malformed-response'; detail?: string };

export interface AuthApi {
  login(credentials: { username: string; password: string }): Promise<AuthApiResult>;
  refresh(refreshToken: string): Promise<AuthApiResult>;
  /**
   * Best-effort server-side invalidation. The Hub revokes the refresh-token family keyed on the
   * refresh token (not the access token), so it is passed through when present; the local clear
   * happens regardless of the outcome.
   */
  logout(sessionToken: string, refreshToken?: string): Promise<void>;
}

export interface AuthDeps {
  api: AuthApi;
  tokenStore: TokenStore;
  now?: () => Date;
}

export type LoginResult =
  | { status: 'signed-in' }
  | { status: 'invalid-credentials'; detail?: string }
  | { status: 'unavailable'; reason: string };

export async function login(
  deps: AuthDeps,
  credentials: { username: string; password: string },
): Promise<LoginResult> {
  const result = await deps.api.login(credentials);
  switch (result.outcome) {
    case 'authenticated':
      await deps.tokenStore.save(result.session);
      return { status: 'signed-in' };
    case 'invalid-credentials':
      return {
        status: 'invalid-credentials',
        ...(result.detail !== undefined ? { detail: result.detail } : {}),
      };
    case 'transient':
      return { status: 'unavailable', reason: result.detail ?? result.reason };
    default: {
      const _exhaustive: never = result;
      void _exhaustive;
      throw new Error('unknown auth outcome');
    }
  }
}

/** Clear the local session. Unsynced evidence is NOT touched — work survives a sign-out. */
export async function logout(deps: AuthDeps): Promise<void> {
  const session = await deps.tokenStore.load();
  await deps.tokenStore.clear();
  if (session !== null) {
    try {
      await deps.api.logout(session.sessionToken, session.refreshToken);
    } catch {
      // Server-side invalidation is best-effort; the local session is already gone and the
      // token expires server-side anyway. Never block a sign-out on the network.
    }
  }
}

export type SessionState =
  | { status: 'valid'; session: AuthSession }
  | { status: 'auth-required'; reason: 'no-session' | 'expired' | 'refresh-rejected' }
  /** A session exists but could not be refreshed right now (offline/5xx); not signed out. */
  | { status: 'unavailable'; reason: string };

/** Refresh when the token expires within this margin — a token that dies mid-submit is a 401. */
const EXPIRY_MARGIN_MS = 60_000;

/**
 * Decode the `exp` claim (epoch ms) from a JWT access token, or undefined if it is not a JWT / has
 * no numeric `exp`. The Hub does not return an explicit `expires_at`, so this is how a session
 * learns its own expiry and can refresh PROACTIVELY instead of only after a 401. Bytes are decoded
 * latin1 then JSON-parsed: `exp` is ASCII digits and JSON punctuation is single-byte, so any
 * multibyte claim values are harmlessly garbled without affecting `exp` extraction.
 */
function decodeJwtExpMs(token: string): number | undefined {
  const parts = token.split('.');
  if (parts.length !== 3) return undefined;
  try {
    let b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const pad = b64.length % 4;
    if (pad !== 0) b64 += '='.repeat(4 - pad);
    const bytes = toByteArray(b64);
    let payload = '';
    for (let i = 0; i < bytes.length; i += 1) payload += String.fromCharCode(bytes[i]);
    const claims = JSON.parse(payload) as { exp?: unknown };
    if (typeof claims.exp === 'number' && Number.isFinite(claims.exp)) return claims.exp * 1000;
  } catch {
    return undefined;
  }
  return undefined;
}

/** Effective expiry (epoch ms): Hub's explicit `expiresAt` if present, else the JWT `exp` claim. */
function sessionExpiryMs(session: AuthSession): number | undefined {
  if (session.expiresAt !== undefined) return Date.parse(session.expiresAt);
  return decodeJwtExpMs(session.sessionToken);
}

function isExpiring(session: AuthSession, nowMs: number): boolean {
  const expiresMs = sessionExpiryMs(session);
  // No expiry information at all (no expiresAt, not a JWT) → treated as non-expiring, as before.
  if (expiresMs === undefined) return false;
  // An unparseable explicit expiry is treated as expiring NOW: refresh or re-login, never guess.
  if (Number.isNaN(expiresMs)) return true;
  return expiresMs - nowMs <= EXPIRY_MARGIN_MS;
}

/**
 * The session to use for Hub calls right now: stored & fresh → valid; expiring with a refresh
 * token → refreshed (and re-stored); otherwise auth-required. Offline during refresh keeps the
 * old session out of use ('unavailable') rather than guessing.
 */
export async function getValidSession(deps: AuthDeps): Promise<SessionState> {
  const nowMs = (deps.now ?? (() => new Date()))().getTime();
  const session = await deps.tokenStore.load();
  if (session === null) {
    return { status: 'auth-required', reason: 'no-session' };
  }
  if (!isExpiring(session, nowMs)) {
    return { status: 'valid', session };
  }
  if (session.refreshToken === undefined) {
    await deps.tokenStore.clear();
    return { status: 'auth-required', reason: 'expired' };
  }
  const result = await deps.api.refresh(session.refreshToken);
  switch (result.outcome) {
    case 'authenticated':
      await deps.tokenStore.save(result.session);
      return { status: 'valid', session: result.session };
    case 'invalid-credentials': {
      // The refresh token itself was rejected — that session is dead. Clear it ONLY if it is
      // still the stored one: a login/refresh that landed while this call was in flight must
      // not have its fresh session wiped by a stale rejection.
      const current = await deps.tokenStore.load();
      if (current !== null && current.sessionToken === session.sessionToken) {
        await deps.tokenStore.clear();
      }
      return { status: 'auth-required', reason: 'refresh-rejected' };
    }
    case 'transient':
      return { status: 'unavailable', reason: result.detail ?? result.reason };
    default: {
      const _exhaustive: never = result;
      void _exhaustive;
      throw new Error('unknown auth outcome');
    }
  }
}
