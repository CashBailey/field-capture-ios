/**
 * Boot-failure classification (Phase 2) — the never-auto-wipe guarantee. Only a DB KEY mismatch
 * may offer a destructive reset; a missing Hub URL or any other error keeps local data untouched.
 */
import { HubConfigError } from '../src/config/hubConfig';
import { DatabaseKeyMismatchError } from '../src/data';
import { classifyBootFailure } from '../src/runtime';

describe('classifyBootFailure', () => {
  it('a DB key mismatch is the ONLY failure that may offer a local reset', () => {
    const f = classifyBootFailure(new DatabaseKeyMismatchError('cipher key no longer opens db'));
    expect(f.reason).toBe('db-key-mismatch');
    expect(f.canReset).toBe(true);
    expect(f.detail).toContain('cipher key');
  });

  it('a missing Hub URL is a config error — data untouched, no reset', () => {
    const f = classifyBootFailure(new HubConfigError('OPS_HUB_URL_DEV is not set'));
    expect(f.reason).toBe('hub-config');
    expect(f.canReset).toBe(false);
    expect(f.message.toLowerCase()).toContain('hub');
  });

  it('any other error is unknown — NEVER auto-wipe, local data preserved', () => {
    const f = classifyBootFailure(new Error('disk full'));
    expect(f.reason).toBe('unknown');
    expect(f.canReset).toBe(false);
    expect(f.message.toLowerCase()).toContain('preserved');
    expect(f.detail).toBe('disk full');
  });

  it('tolerates a non-Error throw', () => {
    const f = classifyBootFailure('boom');
    expect(f.reason).toBe('unknown');
    expect(f.canReset).toBe(false);
    expect(f.detail).toBe('boom');
  });

  it('only the key-mismatch branch is ever resettable (the invariant)', () => {
    const resettable = [
      new DatabaseKeyMismatchError('x'),
      new HubConfigError('y'),
      new Error('z'),
      'w',
    ].filter((e) => classifyBootFailure(e).canReset);
    expect(resettable).toHaveLength(1);
  });
});
