import {
  HubConfigError,
  getHubRuntimeConfig,
  resolveHubRuntimeConfig,
} from '../src/config/hubConfig';

describe('Hub runtime config (OpsHub integration slice)', () => {
  describe('resolveHubRuntimeConfig', () => {
    it('resolves a valid URL + session token', () => {
      const cfg = resolveHubRuntimeConfig({
        hubUrl: 'http://localhost:8000',
        sessionToken: 'tok-1',
      });
      expect(cfg).toEqual({ baseUrl: 'http://localhost:8000', sessionToken: 'tok-1' });
    });

    it('strips a trailing slash so route joining is deterministic', () => {
      const cfg = resolveHubRuntimeConfig({
        hubUrl: 'https://hub.example.test/',
        sessionToken: 't',
      });
      expect(cfg.baseUrl).toBe('https://hub.example.test');
    });

    it.each([undefined, null, '', 42, {}])(
      'fails loud on a missing/non-string Hub URL (%p) instead of faking a Hub',
      (bad) => {
        expect(() => resolveHubRuntimeConfig({ hubUrl: bad, sessionToken: 't' })).toThrow(
          HubConfigError,
        );
      },
    );

    it('names the build-time env vars in the missing-URL error so the fix is obvious', () => {
      expect(() => resolveHubRuntimeConfig({ hubUrl: undefined, sessionToken: 't' })).toThrow(
        /OPS_HUB_URL|APP_ENV/,
      );
    });

    it('rejects a non-http(s) URL', () => {
      expect(() =>
        resolveHubRuntimeConfig({ hubUrl: 'ftp://hub.example.test', sessionToken: 't' }),
      ).toThrow(HubConfigError);
    });

    it('rejects cleartext http:// to a non-local Hub (iOS ATS blocks it; data would be unencrypted)', () => {
      for (const bad of ['http://hub.example.test', 'http://203.0.113.5:8000', 'http://hub.prod']) {
        expect(() => resolveHubRuntimeConfig({ hubUrl: bad, sessionToken: 't' })).toThrow(
          /cleartext|https/i,
        );
      }
    });

    it('allows http:// for localhost / LAN / .local dev hosts (ATS NSAllowsLocalNetworking)', () => {
      for (const ok of [
        'http://localhost:8000',
        'http://127.0.0.1:8000',
        'http://192.168.1.149:8000',
        'http://10.0.0.4:8000',
        'http://172.16.5.5:8000',
        'http://field-hub.local:8000',
      ]) {
        expect(resolveHubRuntimeConfig({ hubUrl: ok, sessionToken: 't' }).baseUrl).toBe(ok);
      }
    });

    it('allows https:// to any host (the prod/staging norm)', () => {
      expect(
        resolveHubRuntimeConfig({ hubUrl: 'https://hub.example.test', sessionToken: 't' }).baseUrl,
      ).toBe('https://hub.example.test');
    });

    it.each([undefined, null, '', 42])(
      'fails loud on a missing/non-string session token (%p)',
      (bad) => {
        expect(() =>
          resolveHubRuntimeConfig({ hubUrl: 'http://localhost:8000', sessionToken: bad }),
        ).toThrow(HubConfigError);
        expect(() =>
          resolveHubRuntimeConfig({ hubUrl: 'http://localhost:8000', sessionToken: bad }),
        ).toThrow(/session token/i);
      },
    );

    it('is a typed, catchable error (name survives transpilation)', () => {
      try {
        resolveHubRuntimeConfig({ hubUrl: undefined, sessionToken: 't' });
        throw new Error('expected HubConfigError');
      } catch (e) {
        expect(e).toBeInstanceOf(HubConfigError);
        expect((e as Error).name).toBe('HubConfigError');
      }
    });
  });

  describe('getHubRuntimeConfig (reads native config via src/config/env)', () => {
    it('throws HubConfigError in an unconfigured environment rather than inventing a URL', () => {
      // The native test config provides no `hubUrl`, so this build is unconfigured — the helper must
      // fail visibly (cross-cutting invariant #2: never pretend a Hub exists).
      expect(() => getHubRuntimeConfig({ sessionToken: 'tok' })).toThrow(HubConfigError);
    });
  });
});
