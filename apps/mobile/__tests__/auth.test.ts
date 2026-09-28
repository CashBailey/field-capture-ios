/**
 * Session auth slice (spec req 8): login flow, token storage, refresh/expiry, logout —
 * every path resolves to a typed state, and signing out never destroys unsynced work.
 */
import {
  VolatileTicketEvidenceStore,
  getValidSession,
  login,
  logout,
  type AuthApi,
  type AuthApiResult,
  type AuthSession,
  type StoreDurability,
  type TokenStore,
} from '../src/domain';
import { HubAuthApiV1 } from '../src/adapters/auth';
import type { HubHttpResponse } from '../src/adapters/sync/OpsHubV1Client';

class FakeTokenStore implements TokenStore {
  readonly durability: StoreDurability = 'volatile-memory';
  session: AuthSession | null = null;
  async load() {
    return this.session;
  }
  async save(session: AuthSession) {
    this.session = session;
  }
  async clear() {
    this.session = null;
  }
}

function api(overrides: Partial<AuthApi> = {}): AuthApi & { logoutCalls: string[] } {
  const logoutCalls: string[] = [];
  return {
    logoutCalls,
    login: async () => ({ outcome: 'transient', reason: 'network' }) as AuthApiResult,
    refresh: async () => ({ outcome: 'transient', reason: 'network' }) as AuthApiResult,
    logout: async (token: string) => {
      logoutCalls.push(token);
    },
    ...overrides,
  };
}

const SESSION: AuthSession = { sessionToken: 'tok-1' };
const NOW = () => new Date('2026-06-10T19:00:00.000Z');

describe('login', () => {
  it('stores the session only when Hub explicitly authenticates', async () => {
    const tokenStore = new FakeTokenStore();
    const result = await login(
      {
        api: api({ login: async () => ({ outcome: 'authenticated', session: SESSION }) }),
        tokenStore,
      },
      { username: 'driver', password: 'pw' },
    );
    expect(result).toEqual({ status: 'signed-in' });
    expect(tokenStore.session).toEqual(SESSION);
  });

  it('maps invalid credentials and transient failures to states — no throw, no token stored', async () => {
    const tokenStore = new FakeTokenStore();
    const bad = await login(
      {
        api: api({
          login: async () => ({ outcome: 'invalid-credentials', httpStatus: 401, detail: 'nope' }),
        }),
        tokenStore,
      },
      { username: 'driver', password: 'wrong' },
    );
    expect(bad).toEqual({ status: 'invalid-credentials', detail: 'nope' });
    const offline = await login({ api: api(), tokenStore }, { username: 'driver', password: 'pw' });
    expect(offline).toMatchObject({ status: 'unavailable' });
    expect(tokenStore.session).toBeNull();
  });
});

describe('getValidSession (expiry + refresh discipline)', () => {
  it('returns the stored session while it is fresh', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = { sessionToken: 'tok', expiresAt: '2026-06-10T20:00:00.000Z' };
    const state = await getValidSession({ api: api(), tokenStore, now: NOW });
    expect(state).toEqual({ status: 'valid', session: tokenStore.session });
  });

  it('requires re-auth when there is no session', async () => {
    const state = await getValidSession({ api: api(), tokenStore: new FakeTokenStore(), now: NOW });
    expect(state).toEqual({ status: 'auth-required', reason: 'no-session' });
  });

  it('refreshes an expiring session and stores the new one', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T19:00:30.000Z', // inside the 60s margin
      refreshToken: 'refresh-1',
    };
    const fresh: AuthSession = { sessionToken: 'new', expiresAt: '2026-06-10T23:00:00.000Z' };
    const refresh = jest.fn(
      async (): Promise<AuthApiResult> => ({ outcome: 'authenticated', session: fresh }),
    );
    const state = await getValidSession({ api: api({ refresh }), tokenStore, now: NOW });
    expect(refresh).toHaveBeenCalledWith('refresh-1');
    expect(state).toEqual({ status: 'valid', session: fresh });
    expect(tokenStore.session).toEqual(fresh);
  });

  it('expired without a refresh token → auth-required, session cleared (never "probably valid")', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = { sessionToken: 'old', expiresAt: '2026-06-10T18:00:00.000Z' };
    const state = await getValidSession({ api: api(), tokenStore, now: NOW });
    expect(state).toEqual({ status: 'auth-required', reason: 'expired' });
    expect(tokenStore.session).toBeNull();
  });

  it('rejected refresh → auth-required; offline refresh → unavailable (NOT signed out)', async () => {
    const tokenStore = new FakeTokenStore();
    const expiring: AuthSession = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T19:00:30.000Z',
      refreshToken: 'r',
    };
    tokenStore.session = expiring;
    const rejected = await getValidSession({
      api: api({ refresh: async () => ({ outcome: 'invalid-credentials', httpStatus: 401 }) }),
      tokenStore,
      now: NOW,
    });
    expect(rejected).toEqual({ status: 'auth-required', reason: 'refresh-rejected' });
    expect(tokenStore.session).toBeNull();

    tokenStore.session = expiring;
    const offline = await getValidSession({ api: api(), tokenStore, now: NOW });
    expect(offline).toMatchObject({ status: 'unavailable' });
    expect(tokenStore.session).toEqual(expiring); // kept — retry refresh later
  });

  it('a stale refresh rejection never clears a session that was replaced mid-flight', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = {
      sessionToken: 'old',
      expiresAt: '2026-06-10T19:00:30.000Z',
      refreshToken: 'r',
    };
    const fresh: AuthSession = { sessionToken: 'fresh-from-login' };
    const state = await getValidSession({
      api: api({
        refresh: async () => {
          // a login lands while this refresh is in flight…
          tokenStore.session = fresh;
          // …then the (now-irrelevant) refresh comes back rejected
          return { outcome: 'invalid-credentials', httpStatus: 401 };
        },
      }),
      tokenStore,
      now: NOW,
    });
    expect(state).toEqual({ status: 'auth-required', reason: 'refresh-rejected' });
    expect(tokenStore.session).toEqual(fresh); // the fresh session was NOT wiped
  });

  it('treats an unparseable expiry as expiring now — refresh, never guess', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = { sessionToken: 'old', expiresAt: 'garbage', refreshToken: 'r' };
    const fresh: AuthSession = { sessionToken: 'new' };
    const state = await getValidSession({
      api: api({ refresh: async () => ({ outcome: 'authenticated', session: fresh }) }),
      tokenStore,
      now: NOW,
    });
    expect(state).toEqual({ status: 'valid', session: fresh });
  });
});

describe('getValidSession (proactive refresh from JWT exp when Hub omits expiresAt)', () => {
  const nowMs = NOW().getTime();
  // The live Hub returns no expires_at; the access_token is a JWT whose `exp` claim is the only
  // source of expiry. Build a real JWT (header.payload.sig) so decodeJwtExpMs is exercised.
  const jwtWithExp = (expSeconds: number): string => {
    const b64url = (obj: unknown): string =>
      Buffer.from(JSON.stringify(obj))
        .toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
    return `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url({ exp: expSeconds })}.sig`;
  };

  it('refreshes proactively when the JWT exp is inside the margin (no expiresAt field present)', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = {
      sessionToken: jwtWithExp(Math.floor(nowMs / 1000) + 30), // 30s out → inside the 60s margin
      refreshToken: 'r',
    };
    const fresh: AuthSession = { sessionToken: 'new' };
    const refresh = jest.fn(
      async (): Promise<AuthApiResult> => ({ outcome: 'authenticated', session: fresh }),
    );
    const state = await getValidSession({ api: api({ refresh }), tokenStore, now: NOW });
    expect(refresh).toHaveBeenCalledWith('r');
    expect(state).toEqual({ status: 'valid', session: fresh });
  });

  it('treats a JWT with a far-future exp as fresh — no refresh', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = {
      sessionToken: jwtWithExp(Math.floor(nowMs / 1000) + 3600),
      refreshToken: 'r',
    };
    const refresh = jest.fn();
    const state = await getValidSession({ api: api({ refresh }), tokenStore, now: NOW });
    expect(refresh).not.toHaveBeenCalled();
    expect(state).toEqual({ status: 'valid', session: tokenStore.session });
  });

  it('an opaque (non-JWT) token with no expiresAt stays non-expiring — unchanged legacy behavior', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = { sessionToken: 'opaque-not-a-jwt', refreshToken: 'r' };
    const refresh = jest.fn();
    const state = await getValidSession({ api: api({ refresh }), tokenStore, now: NOW });
    expect(refresh).not.toHaveBeenCalled();
    expect(state).toEqual({ status: 'valid', session: tokenStore.session });
  });
});

describe('logout', () => {
  it('clears the local session, best-effort invalidates server-side, and PRESERVES evidence', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = SESSION;
    const evidenceStore = new VolatileTicketEvidenceStore();
    evidenceStore.save({
      envelope: {
        opId: 'op-1',
        kind: 'command',
        type: 'ticket.submit',
        idempotencyKey: 'gtr:dev:0:op-1',
        localSeq: 0,
        dependsOn: [],
        payload: {
          idempotencyKey: 'gtr:dev:0:op-1',
          serviceRequestId: 'sr-1',
          snapshotHash: 'h1',
          ticketNo: 'T-1',
          quantityBbl: 5,
          disposalTicketNo: 'D-1',
        },
      },
      state: 'pending',
      attempts: 1,
      createdAt: '2026-06-10T18:00:00.000Z',
      updatedAt: '2026-06-10T18:00:00.000Z',
    });

    const theApi = api();
    await logout({ api: theApi, tokenStore });
    expect(tokenStore.session).toBeNull();
    expect(theApi.logoutCalls).toEqual(['tok-1']);
    expect(evidenceStore.list()).toHaveLength(1); // unsynced work survives sign-out

    // a failing server-side logout never blocks the local sign-out
    tokenStore.session = SESSION;
    await expect(
      logout({
        api: api({
          logout: async () => {
            throw new Error('offline');
          },
        }),
        tokenStore,
      }),
    ).resolves.toBeUndefined();
    expect(tokenStore.session).toBeNull();
  });

  it('passes the refresh token through so the Hub can revoke this device family', async () => {
    const tokenStore = new FakeTokenStore();
    tokenStore.session = { sessionToken: 'tok-1', refreshToken: 'refresh-9' };
    const logoutFn = jest.fn(async () => undefined);
    await logout({ api: api({ logout: logoutFn }), tokenStore });
    expect(logoutFn).toHaveBeenCalledWith('tok-1', 'refresh-9');
    expect(tokenStore.session).toBeNull();
  });
});

describe('HubAuthApiV1 (wire mapping, fake fetch)', () => {
  const respond = (status: number, body?: unknown): HubHttpResponse => ({
    ok: status >= 200 && status < 300,
    status,
    json: async () => {
      if (body === undefined) throw new Error('no body');
      return body;
    },
  });

  it('authenticates on the live opshub access_token (no expires_at; JWT carries exp)', async () => {
    // The exact shape verified live against opshub POST /api/v1/auth/login.
    const calls: string[] = [];
    const liveApi = new HubAuthApiV1('https://hub.test', async (url, init) => {
      calls.push(`${init?.method ?? 'GET'} ${url}`);
      if (url.endsWith('/api/v1/me')) {
        return respond(200, {
          id: 'user-1',
          username: 'driver.user',
          email: 'driver.user@example.test',
          display_name: 'Driver User',
          title: 'Driver',
          department: 'Operations',
          is_active: true,
          employee_id: 'emp-1',
          phone: '(432) 555-0101',
          assigned_yard: 'Midland Yard',
          default_truck: 'Truck 7',
          default_trailer: 'Vacuum Trailer 19',
          roles: ['driver', 'end_user'],
          access_profile: 'driver',
          language: 'en',
        });
      }
      return respond(200, {
        access_token: 'jwt-access',
        refresh_token: 'r',
        token_type: 'bearer',
      });
    });
    await expect(liveApi.login({ username: 'u', password: 'p' })).resolves.toEqual({
      outcome: 'authenticated',
      session: {
        sessionToken: 'jwt-access',
        refreshToken: 'r',
        userProfile: {
          id: 'user-1',
          username: 'driver.user',
          email: 'driver.user@example.test',
          displayName: 'Driver User',
          title: 'Driver',
          department: 'Operations',
          isActive: true,
          employeeId: 'emp-1',
          phone: '(432) 555-0101',
          assignedYard: 'Midland Yard',
          defaultTruck: 'Truck 7',
          defaultTrailer: 'Vacuum Trailer 19',
          roles: ['driver', 'end_user'],
          accessProfile: 'driver',
          language: 'en',
        },
      },
    });
    expect(calls).toEqual([
      'POST https://hub.test/api/v1/auth/login',
      'GET https://hub.test/api/v1/me',
    ]);
  });

  it('omits null optional profile fields instead of turning them into display values', async () => {
    const apiV1 = new HubAuthApiV1('https://hub.test', async (url) => {
      if (url.endsWith('/api/v1/me')) {
        return respond(200, {
          display_name: 'Driver User',
          employee_id: 'emp-1',
          assigned_yard: null,
          default_truck: null,
          default_trailer: null,
        });
      }
      return respond(200, {
        access_token: 'jwt-access',
        refresh_token: 'r',
        token_type: 'bearer',
      });
    });
    await expect(apiV1.login({ username: 'u', password: 'p' })).resolves.toEqual({
      outcome: 'authenticated',
      session: {
        sessionToken: 'jwt-access',
        refreshToken: 'r',
        userProfile: {
          displayName: 'Driver User',
          employeeId: 'emp-1',
        },
      },
    });
  });

  it('keeps auth successful when the signed-in profile endpoint is unavailable', async () => {
    const apiV1 = new HubAuthApiV1('https://hub.test', async (url) => {
      if (url.endsWith('/api/v1/me')) return respond(503);
      return respond(200, {
        access_token: 'jwt-access',
        refresh_token: 'r',
        token_type: 'bearer',
      });
    });
    await expect(apiV1.login({ username: 'u', password: 'p' })).resolves.toEqual({
      outcome: 'authenticated',
      session: { sessionToken: 'jwt-access', refreshToken: 'r' },
    });
  });

  it('still accepts a legacy session_token; bare 2xx (no token) is transient', async () => {
    const legacyApi = new HubAuthApiV1('https://hub.test', async () =>
      respond(200, {
        session_token: 'tok',
        expires_at: '2026-06-11T00:00:00Z',
        refresh_token: 'r',
      }),
    );
    await expect(legacyApi.login({ username: 'u', password: 'p' })).resolves.toEqual({
      outcome: 'authenticated',
      session: { sessionToken: 'tok', expiresAt: '2026-06-11T00:00:00Z', refreshToken: 'r' },
    });

    const portalApi = new HubAuthApiV1('https://hub.test', async () =>
      respond(200, { welcome: 'to the coffee shop wifi' }),
    );
    await expect(portalApi.login({ username: 'u', password: 'p' })).resolves.toMatchObject({
      outcome: 'transient',
      reason: 'malformed-response',
    });
  });

  it('maps 401 → invalid-credentials, 503 → transient/server, network throw → transient/network', async () => {
    const denied = new HubAuthApiV1('https://hub.test', async () =>
      respond(401, { detail: 'bad password' }),
    );
    await expect(denied.login({ username: 'u', password: 'x' })).resolves.toEqual({
      outcome: 'invalid-credentials',
      httpStatus: 401,
      detail: 'bad password',
    });

    const down = new HubAuthApiV1('https://hub.test', async () => respond(503));
    await expect(down.refresh('r')).resolves.toMatchObject({
      outcome: 'transient',
      reason: 'server',
    });

    const offline = new HubAuthApiV1('https://hub.test', async () => {
      throw new Error('ECONNREFUSED');
    });
    await expect(offline.login({ username: 'u', password: 'p' })).resolves.toMatchObject({
      outcome: 'transient',
      reason: 'network',
    });
  });

  it('never hangs: a black-holed login resolves transient at the timeout', async () => {
    const blackHole = new HubAuthApiV1(
      'https://hub.test',
      () => new Promise<never>(() => undefined),
      { timeoutMs: 20 },
    );
    await expect(blackHole.login({ username: 'u', password: 'p' })).resolves.toMatchObject({
      outcome: 'transient',
      reason: 'network',
    });
  });

  it('logout never throws, even offline', async () => {
    const offline = new HubAuthApiV1('https://hub.test', async () => {
      throw new Error('offline');
    });
    // A refresh token is present, so the round-trip is attempted (and fails) — sign-out still resolves.
    await expect(offline.logout('tok', 'refresh-1')).resolves.toBeUndefined();
  });

  it('logout posts the refresh token + device_id so the Hub revokes this install family', async () => {
    const calls: Array<{ url: string; body: Record<string, unknown> }> = [];
    const capture = async (url: string, init: { body?: string }): Promise<HubHttpResponse> => {
      calls.push({ url, body: init.body !== undefined ? JSON.parse(init.body) : {} });
      return respond(200, { status: 'ok' });
    };
    const apiV1 = new HubAuthApiV1('https://hub.test', capture, { deviceId: 'install-123' });
    await apiV1.logout('access-tok', 'refresh-9');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe('https://hub.test/api/v1/auth/logout');
    expect(calls[0]!.body).toEqual({ refresh_token: 'refresh-9', device_id: 'install-123' });
  });

  it('logout with no refresh token makes no network call (nothing for the Hub to revoke)', async () => {
    let called = false;
    const capture = async (): Promise<HubHttpResponse> => {
      called = true;
      return respond(200, { status: 'ok' });
    };
    const apiV1 = new HubAuthApiV1('https://hub.test', capture, { deviceId: 'install-123' });
    await apiV1.logout('access-tok');
    expect(called).toBe(false);
  });

  it('sends device_id on login and refresh so the Hub scopes the refresh family to this install', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const capture = async (
      _url: string,
      init: { body?: string; method?: string },
    ): Promise<HubHttpResponse> => {
      if (init.method === 'POST') {
        bodies.push(init.body !== undefined ? JSON.parse(init.body) : {});
      }
      return respond(200, { access_token: 'a', refresh_token: 'r', token_type: 'bearer' });
    };
    const withDevice = new HubAuthApiV1('https://hub.test', capture, { deviceId: 'install-123' });
    await withDevice.login({ username: 'u', password: 'p' });
    await withDevice.refresh('r');
    expect(bodies[0]).toMatchObject({ username: 'u', password: 'p', device_id: 'install-123' });
    expect(bodies[1]).toMatchObject({ refresh_token: 'r', device_id: 'install-123' });
  });

  it('resolves device_id lazily and never lets a missing/throwing id break sign-in', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const capture = async (
      _url: string,
      init: { body?: string; method?: string },
    ): Promise<HubHttpResponse> => {
      if (init.method === 'POST') {
        bodies.push(init.body !== undefined ? JSON.parse(init.body) : {});
      }
      return respond(200, { access_token: 'a', token_type: 'bearer' });
    };
    // A throwing resolver must fall back to omitting device_id (Hub default "web"), never throw.
    const thrower = new HubAuthApiV1('https://hub.test', capture, {
      deviceId: () => {
        throw new Error('identity store not ready');
      },
    });
    await expect(thrower.login({ username: 'u', password: 'p' })).resolves.toMatchObject({
      outcome: 'authenticated',
    });
    expect(bodies[0]).not.toHaveProperty('device_id');

    // No deviceId configured → omitted entirely (backward compatible with the office-web default).
    bodies.length = 0;
    const none = new HubAuthApiV1('https://hub.test', capture);
    await none.login({ username: 'u', password: 'p' });
    expect(bodies[0]).not.toHaveProperty('device_id');
  });
});
