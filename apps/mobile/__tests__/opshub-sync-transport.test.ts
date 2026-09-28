/**
 * Wire-contract tests for `OpsHubSyncTransport` (POST /sync/commands, GET /sync/changes,
 * POST /sync/uploads). Discipline under test: snake_case wire mapping is exact, per-operation
 * outcomes come back as data, transport/protocol failures throw typed errors, and a malformed
 * response never becomes a guessed outcome.
 */
import { sync } from '@fieldcapture/contracts';

import { OpsHubSyncTransport } from '../src/adapters/sync';
import type { HubFetch, HubFetchInit, HubHttpResponse } from '../src/adapters/sync';
import { HubAuthError, HubNetworkError, HubResponseError } from '../src/domain';

const CONFIG = { baseUrl: 'http://hub.test', sessionToken: 'tok-123' };

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

function fakeFetch(...responses: HubHttpResponse[]): HubFetch & {
  calls: { url: string; init: HubFetchInit }[];
} {
  const calls: { url: string; init: HubFetchInit }[] = [];
  const fn = async (url: string, init: HubFetchInit) => {
    calls.push({ url, init });
    const next = responses.length > 1 ? responses.shift() : responses[0];
    if (!next) throw new Error('fakeFetch: no response queued');
    return next;
  };
  return Object.assign(fn, { calls });
}

const ENVELOPE: sync.OperationEnvelope = {
  opId: 'op-1',
  kind: 'command',
  type: 'ticket.submit',
  idempotencyKey: 'gtr:devA:7:op-1',
  localSeq: 7,
  dependsOn: ['op-0'],
  precondition: { baseVersion: 3 },
  payload: { hello: 'hub' },
};

describe('per-call token provider (Section 4e item 1)', () => {
  it('sends a FRESH token per request, not the one bound at construction', async () => {
    let token = 'tok-old';
    const f = fakeFetch(
      jsonResponse(200, { token: { authority_epoch: 1, commit_seq: 0 }, changes: [] }),
      jsonResponse(200, { token: { authority_epoch: 1, commit_seq: 0 }, changes: [] }),
    );
    const transport = new OpsHubSyncTransport(CONFIG, f, {
      tokenProvider: () => token,
    });
    await transport.pullChanges({ authorityEpoch: 1, commitSeq: 0 });
    expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-old');
    token = 'tok-refreshed'; // a refresh happened between requests
    await transport.pullChanges({ authorityEpoch: 1, commitSeq: 0 });
    expect(f.calls[1].init.headers.Authorization).toBe('Bearer tok-refreshed');
  });

  it('awaits an async token provider', async () => {
    const f = fakeFetch(
      jsonResponse(200, { token: { authority_epoch: 1, commit_seq: 0 }, changes: [] }),
    );
    const transport = new OpsHubSyncTransport(CONFIG, f, {
      tokenProvider: async () => 'tok-async',
    });
    await transport.pullChanges({ authorityEpoch: 1, commitSeq: 0 });
    expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-async');
  });

  it('falls back to the static config token when no provider is given', async () => {
    const f = fakeFetch(
      jsonResponse(200, { token: { authority_epoch: 1, commit_seq: 0 }, changes: [] }),
    );
    await new OpsHubSyncTransport(CONFIG, f).pullChanges({ authorityEpoch: 1, commitSeq: 0 });
    expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-123');
  });
});

describe('submitBatch', () => {
  it('POSTs the exact wire shape with bearer auth', async () => {
    const f = fakeFetch(
      jsonResponse(200, {
        results: [
          { op_id: 'op-1', outcome: 'accepted', token: { authority_epoch: 1, commit_seq: 42 } },
        ],
      }),
    );
    const transport = new OpsHubSyncTransport(CONFIG, f);
    await transport.submitBatch([ENVELOPE]);

    expect(f.calls[0].url).toBe('http://hub.test/api/v1/sync/commands');
    expect(f.calls[0].init.method).toBe('POST');
    expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-123');
    expect(JSON.parse(f.calls[0].init.body as string)).toEqual({
      operations: [
        {
          op_id: 'op-1',
          kind: 'command',
          type: 'ticket.submit',
          idempotency_key: 'gtr:devA:7:op-1',
          local_seq: 7,
          depends_on: ['op-0'],
          precondition: { base_version: 3 },
          payload: { hello: 'hub' },
        },
      ],
    });
  });

  it('omits the precondition key for append-only events', async () => {
    const f = fakeFetch(jsonResponse(200, { results: [] }));
    const transport = new OpsHubSyncTransport(CONFIG, f);
    const event: sync.OperationEnvelope = {
      ...ENVELOPE,
      kind: 'event',
      dependsOn: [],
    };
    delete (event as { precondition?: unknown }).precondition;
    await transport.submitBatch([event]);
    const wire = JSON.parse(f.calls[0].init.body as string).operations[0];
    expect('precondition' in wire).toBe(false);
  });

  it('maps all three outcomes, preserving reasons verbatim', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(
        jsonResponse(200, {
          results: [
            { op_id: 'a', outcome: 'accepted', token: { authority_epoch: 2, commit_seq: 9 } },
            {
              op_id: 'b',
              outcome: 'rejected',
              rejection_code: 'stale_version',
              detail: 'SR changed',
              latest: { version: 4 },
            },
            { op_id: 'c', outcome: 'needs-review', review_reason: 'assignment_changed' },
          ],
        }),
      ),
    );
    await expect(transport.submitBatch([ENVELOPE])).resolves.toEqual([
      { outcome: 'accepted', opId: 'a', token: { authorityEpoch: 2, commitSeq: 9 } },
      {
        outcome: 'rejected',
        opId: 'b',
        rejectionCode: 'stale_version',
        detail: 'SR changed',
        latest: { version: 4 },
      },
      { outcome: 'needs-review', opId: 'c', reviewReason: 'assignment_changed' },
    ]);
  });

  it('an empty batch never touches the network', async () => {
    const f = fakeFetch(jsonResponse(200, { results: [] }));
    const transport = new OpsHubSyncTransport(CONFIG, f);
    await expect(transport.submitBatch([])).resolves.toEqual([]);
    expect(f.calls).toHaveLength(0);
  });

  it.each([
    ['unknown outcome', { results: [{ op_id: 'a', outcome: 'maybe' }] }],
    ['accepted without token', { results: [{ op_id: 'a', outcome: 'accepted' }] }],
    ['rejected without code', { results: [{ op_id: 'a', outcome: 'rejected' }] }],
    ['no results list', { ok: true }],
  ])(
    'a malformed response (%s) throws HubResponseError — batch stays retryable',
    async (_what, body) => {
      const transport = new OpsHubSyncTransport(CONFIG, fakeFetch(jsonResponse(200, body)));
      await expect(transport.submitBatch([ENVELOPE])).rejects.toThrow(HubResponseError);
    },
  );

  it('throws typed errors: network / 401 auth / 5xx response', async () => {
    const offline: HubFetch = async () => {
      throw new TypeError('Network request failed');
    };
    await expect(
      new OpsHubSyncTransport(CONFIG, offline).submitBatch([ENVELOPE]),
    ).rejects.toThrow(HubNetworkError);
    await expect(
      new OpsHubSyncTransport(CONFIG, fakeFetch(jsonResponse(401, {}))).submitBatch([ENVELOPE]),
    ).rejects.toThrow(HubAuthError);
    await expect(
      new OpsHubSyncTransport(CONFIG, fakeFetch(jsonResponse(503, {}))).submitBatch([ENVELOPE]),
    ).rejects.toThrow(HubResponseError);
  });
});

describe('pullChanges', () => {
  it('GETs after the given frontier and maps the page', async () => {
    const f = fakeFetch(
      jsonResponse(200, {
        token: { authority_epoch: 1, commit_seq: 58 },
        changes: [{ entity: 'assignment', id: 'sr-1' }],
      }),
    );
    const transport = new OpsHubSyncTransport(CONFIG, f);
    const page = await transport.pullChanges({ authorityEpoch: 1, commitSeq: 57 });

    expect(f.calls[0].url).toBe('http://hub.test/api/v1/sync/changes?after_epoch=1&after_seq=57');
    expect(page).toEqual({
      token: { authorityEpoch: 1, commitSeq: 58 },
      changes: [{ entity: 'assignment', id: 'sr-1' }],
    });
  });

  it('410 throws StaleChangeTokenError carrying Hub`s reset frontier', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(
        jsonResponse(410, {
          error: 'stale_change_token',
          reset_to: { authority_epoch: 2, commit_seq: 0 },
        }),
      ),
    );
    const pending = transport.pullChanges({ authorityEpoch: 1, commitSeq: 5 });
    await expect(pending).rejects.toThrow(sync.StaleChangeTokenError);
    await pending.catch((e: sync.StaleChangeTokenError) => {
      expect(e.resetTo).toEqual({ authorityEpoch: 2, commitSeq: 0 });
    });
  });

  it('410 without reset_to still throws StaleChangeTokenError (resetTo absent)', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(410, { error: 'stale_change_token' })),
    );
    const failure = await transport.pullChanges(sync.ZERO_CHANGE_TOKEN).then(
      () => undefined,
      (e: sync.StaleChangeTokenError) => e,
    );
    expect(failure?.name).toBe('StaleChangeTokenError');
    expect(failure?.resetTo).toBeUndefined();
  });

  it('a malformed token in the page throws HubResponseError — frontier never poisoned', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, { token: { authority_epoch: 'x' }, changes: [] })),
    );
    await expect(transport.pullChanges(sync.ZERO_CHANGE_TOKEN)).rejects.toThrow(HubResponseError);
  });
});

describe('openUploadSession', () => {
  const REQUEST: sync.UploadSessionRequest = {
    blobId: 'blob-1',
    sha256: 'abc123',
    byteLength: 1024,
    mimeType: 'image/jpeg',
    idempotencyKey: 'gtr:devA:8:up-1',
  };

  it('POSTs the wire shape and maps a new session', async () => {
    const f = fakeFetch(
      jsonResponse(201, {
        result: 'new-session',
        upload_session_id: 'sess-1',
        upload_url: 'http://hub.test/api/v1/sync/uploads/sess-1',
      }),
    );
    const transport = new OpsHubSyncTransport(CONFIG, f);
    const session = await transport.openUploadSession(REQUEST);

    expect(JSON.parse(f.calls[0].init.body as string)).toEqual({
      blob_id: 'blob-1',
      sha256: 'abc123',
      byte_length: 1024,
      mime_type: 'image/jpeg',
      idempotency_key: 'gtr:devA:8:up-1',
    });
    expect(session).toEqual({
      result: 'new-session',
      uploadSessionId: 'sess-1',
      uploadUrl: 'http://hub.test/api/v1/sync/uploads/sess-1',
    });
  });

  it('maps the content-hash dedupe arm', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, { result: 'already-present', blob_id: 'blob-1' })),
    );
    await expect(transport.openUploadSession(REQUEST)).resolves.toEqual({
      result: 'already-present',
      blobId: 'blob-1',
    });
  });

  it('an unknown result shape throws HubResponseError', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, { result: 'fine' })),
    );
    await expect(transport.openUploadSession(REQUEST)).rejects.toThrow(HubResponseError);
  });
});
