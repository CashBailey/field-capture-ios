/**
 * Hub v1 auth routes (the sign-in slice the triad contract deferred):
 *
 *   POST /api/v1/auth/login    { username, password, device_id? } -> 200 { access_token, refresh_token, token_type }
 *   POST /api/v1/auth/refresh  { refresh_token, device_id? }      -> 200 (same shape)
 *   POST /api/v1/auth/logout   (Authorization: Bearer ...) -> 2xx (body ignored)
 *
 * `device_id` is this install's stable id. OpsHub scopes the refresh-token family by device_id
 * (auth_service.get_valid_refresh / revoke_device_family), so sending it isolates each install:
 * without it every mobile device + office browser collapse into the shared "web" family, where one
 * device's token-reuse or logout revokes the others. It is resolved lazily and defensively so it
 * can never break sign-in; omitting it falls back to the Hub's "web" default.
 *
 * The bearer token field is `access_token` — VERIFIED live against opshub (it returns
 * {access_token, refresh_token, token_type}, no expires_at; the JWT carries its own exp). We still
 * accept a legacy `session_token` so a Hub that renames it back keeps working. Reading the wrong
 * field would reject a perfectly good login as "malformed" and block sign-in on the device.
 *
 * Mapping discipline mirrors OpsHubV1Client:
 *  - every call is wall-clock-bounded — a black-holed login can never hang the sign-in screen;
 *  - a 2xx WITHOUT a bearer token string is `transient`, never "signed in";
 *  - 401/403 -> invalid-credentials; 429/5xx/network/malformed -> transient. As data, not throws.
 */
import type { AuthApi, AuthApiResult, AuthSession, UserProfile } from '../../domain';
import type { HubFetch, HubHttpResponse } from '../sync/OpsHubV1Client';

const ROUTES = {
  login: '/api/v1/auth/login',
  refresh: '/api/v1/auth/refresh',
  logout: '/api/v1/auth/logout',
  me: '/api/v1/me',
} as const;

const DEFAULT_TIMEOUT_MS = 15_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function pickString(value: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const parsed = optionalString(value[key]);
    if (parsed !== undefined) return parsed;
  }
  return undefined;
}

function pickBoolean(value: Record<string, unknown>, ...keys: string[]): boolean | undefined {
  for (const key of keys) {
    if (typeof value[key] === 'boolean') return value[key];
  }
  return undefined;
}

function optionalStringList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const strings = value.filter(
    (item): item is string => typeof item === 'string' && item.length > 0,
  );
  return strings.length > 0 ? strings : undefined;
}

function parseUserProfile(value: unknown): UserProfile | undefined {
  if (!isRecord(value)) return undefined;
  const id = pickString(value, 'id');
  const username = pickString(value, 'username');
  const email = pickString(value, 'email');
  const displayName = pickString(value, 'display_name', 'displayName');
  const title = pickString(value, 'title');
  const department = pickString(value, 'department');
  const isActive = pickBoolean(value, 'is_active', 'isActive');
  const employeeId = pickString(value, 'employee_id', 'employeeId');
  const phone = pickString(value, 'phone');
  const assignedYard = pickString(value, 'assigned_yard', 'assignedYard');
  const defaultTruck = pickString(value, 'default_truck', 'defaultTruck');
  const defaultTrailer = pickString(value, 'default_trailer', 'defaultTrailer');
  const accessProfile = pickString(value, 'access_profile', 'accessProfile');
  const roles = optionalStringList(value.roles);
  const language = pickString(value, 'language');
  const profile: UserProfile = {
    ...(id !== undefined ? { id } : {}),
    ...(username !== undefined ? { username } : {}),
    ...(email !== undefined ? { email } : {}),
    ...(displayName !== undefined ? { displayName } : {}),
    ...(title !== undefined ? { title } : {}),
    ...(department !== undefined ? { department } : {}),
    ...(isActive !== undefined ? { isActive } : {}),
    ...(employeeId !== undefined ? { employeeId } : {}),
    ...(phone !== undefined ? { phone } : {}),
    ...(assignedYard !== undefined ? { assignedYard } : {}),
    ...(defaultTruck !== undefined ? { defaultTruck } : {}),
    ...(defaultTrailer !== undefined ? { defaultTrailer } : {}),
    ...(accessProfile !== undefined ? { accessProfile } : {}),
    ...(roles !== undefined ? { roles } : {}),
    ...(language !== undefined ? { language } : {}),
  };
  return Object.keys(profile).length > 0 ? profile : undefined;
}

export class HubAuthApiV1 implements AuthApi {
  private readonly fetchFn: HubFetch;
  private readonly timeoutMs: number;
  private readonly deviceIdSource?: string | (() => string | undefined);

  constructor(
    private readonly baseUrl: string,
    fetchFn?: HubFetch,
    options?: { timeoutMs?: number; deviceId?: string | (() => string | undefined) },
  ) {
    this.fetchFn = fetchFn ?? (globalThis.fetch as unknown as HubFetch);
    this.timeoutMs = options?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.deviceIdSource = options?.deviceId;
  }

  /**
   * Resolve this install's `device_id`. Lazy (so the device-identity store needn't be ready at
   * construction) and defensive: a missing/blank value or a throwing resolver yields undefined,
   * which omits the field and lets the Hub apply its "web" default — device-id wiring must NEVER
   * break sign-in.
   */
  private resolveDeviceId(): string | undefined {
    try {
      const value =
        typeof this.deviceIdSource === 'function' ? this.deviceIdSource() : this.deviceIdSource;
      return typeof value === 'string' && value.length > 0 ? value : undefined;
    } catch {
      return undefined;
    }
  }

  private deviceIdField(): Record<string, string> {
    const deviceId = this.resolveDeviceId();
    return deviceId !== undefined ? { device_id: deviceId } : {};
  }

  private async boundedPost(
    path: string,
    body: Record<string, unknown>,
    headers: Record<string, string> = {},
  ): Promise<HubHttpResponse> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        this.fetchFn(`${this.baseUrl}${path}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...headers },
          body: JSON.stringify(body),
        }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`request timed out after ${this.timeoutMs}ms`)),
            this.timeoutMs,
          );
        }),
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }

  private async boundedGet(
    path: string,
    headers: Record<string, string> = {},
  ): Promise<HubHttpResponse> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        this.fetchFn(`${this.baseUrl}${path}`, {
          method: 'GET',
          headers: { Accept: 'application/json', ...headers },
        }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`request timed out after ${this.timeoutMs}ms`)),
            this.timeoutMs,
          );
        }),
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }

  private async fetchUserProfile(sessionToken: string): Promise<UserProfile | undefined> {
    try {
      const response = await this.boundedGet(ROUTES.me, {
        Authorization: `Bearer ${sessionToken}`,
      });
      if (!response.ok) return undefined;
      return parseUserProfile(await response.json().catch(() => undefined));
    } catch {
      // Profile display must not block auth. The app can still use the token and show an honest
      // "not provided" fallback until Hub/profile is reachable.
      return undefined;
    }
  }

  private async sessionCall(path: string, body: Record<string, unknown>): Promise<AuthApiResult> {
    let response: HubHttpResponse;
    try {
      response = await this.boundedPost(path, body);
    } catch (error) {
      return { outcome: 'transient', reason: 'network', detail: String(error) };
    }
    const parsed = await response.json().then(
      (b) => b,
      () => undefined,
    );
    const rec = isRecord(parsed) ? parsed : {};
    const detail = optionalString(rec.detail);

    if (response.ok) {
      // Live opshub returns `access_token`; a legacy Hub may use `session_token`. Accept either.
      const sessionToken = optionalString(rec.access_token) ?? optionalString(rec.session_token);
      if (sessionToken === undefined) {
        // 2xx without a bearer token: captive portal / proxy garbage. Never "signed in".
        return {
          outcome: 'transient',
          reason: 'malformed-response',
          detail: '2xx response without an access_token',
        };
      }
      const expiresAt = optionalString(rec.expires_at);
      const refreshToken = optionalString(rec.refresh_token);
      const session: AuthSession = {
        sessionToken,
        ...(expiresAt !== undefined ? { expiresAt } : {}),
        ...(refreshToken !== undefined ? { refreshToken } : {}),
      };
      const userProfile = await this.fetchUserProfile(sessionToken);
      if (userProfile !== undefined) {
        session.userProfile = userProfile;
      }
      return { outcome: 'authenticated', session };
    }
    if (response.status === 401 || response.status === 403) {
      return {
        outcome: 'invalid-credentials',
        httpStatus: response.status,
        ...(detail !== undefined ? { detail } : {}),
      };
    }
    return {
      outcome: 'transient',
      reason: response.status === 429 || response.status >= 500 ? 'server' : 'malformed-response',
      ...(detail !== undefined ? { detail } : {}),
    };
  }

  login(credentials: { username: string; password: string }): Promise<AuthApiResult> {
    return this.sessionCall(ROUTES.login, {
      username: credentials.username,
      password: credentials.password,
      ...this.deviceIdField(),
    });
  }

  refresh(refreshToken: string): Promise<AuthApiResult> {
    return this.sessionCall(ROUTES.refresh, {
      refresh_token: refreshToken,
      ...this.deviceIdField(),
    });
  }

  async logout(sessionToken: string, refreshToken?: string): Promise<void> {
    // Best-effort: the caller already cleared the local session; failures are irrelevant. The Hub
    // revokes this install's refresh-token family by (refresh_token, device_id) and ignores the
    // bearer — without a refresh token there is nothing to revoke, so skip the round-trip rather
    // than POST a guaranteed-422 empty body.
    if (refreshToken === undefined || refreshToken.length === 0) return;
    try {
      await this.boundedPost(
        ROUTES.logout,
        { refresh_token: refreshToken, ...this.deviceIdField() },
        { Authorization: `Bearer ${sessionToken}` },
      );
    } catch {
      // Offline sign-out is still a sign-out.
    }
  }
}
