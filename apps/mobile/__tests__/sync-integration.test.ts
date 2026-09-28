/**
 * Section 4e item 7 — integration test composing the REAL components against a fake Hub (the unit
 * tests each mock their neighbour; this proves the pieces actually fit together before the
 * owner-gated on-device go-live flip):
 *   OpsHubSyncTransport (+ per-call tokenProvider) → SyncEngine → idempotent applyChanges ledger,
 *   and createTusFetch → TusUploadClient through a full multi-chunk resumable upload.
 */
import { sync } from '@fieldcapture/contracts';

import {
  createTusFetch,
  OpsHubSyncTransport,
  TusUploadClient,
  type FetchLike,
  type FetchLikeResponse,
  type HubFetch,
  type HubFetchInit,
  type HubHttpResponse,
} from '../src/adapters/sync';
import {
  recordChanges,
  VolatileSyncChangeLedger,
  VolatileSyncFrontierStore,
  VolatileSyncOutboxStore,
} from '../src/domain';
import { SyncEngine } from '../src/runtime';

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

const ENVELOPE: sync.OperationEnvelope = {
  opId: 'op-1',
  kind: 'event',
  type: 'jhajsa.submit',
  idempotencyKey: 'gtr:devA:1:op-1',
  localSeq: 1,
  dependsOn: [],
  payload: { serviceRequestId: 'sr-1' },
};

const CHANGE = {
  authority_epoch: 1,
  commit_seq: 1,
  op_id: 'op-1',
  entity_type: 'jha',
  entity_id: 'jha-1',
  change_type: 'jhajsa.submit',
  payload: { jha_id: 'jha-1' },
  created_at: '2026-06-15T03:00:00Z',
};

describe('real transport + engine + applyChanges ledger, against a fake Hub', () => {
  it('pushes via the real transport (fresh token per request) and records pulled changes idempotently', async () => {
    let token = 'tok-1';
    const authSeen: string[] = [];
    let pulls = 0;
    const hubFetch: HubFetch = async (url: string, init: HubFetchInit) => {
      authSeen.push(init.headers.Authorization as string);
      if (url.includes('/sync/commands')) {
        const body = JSON.parse(init.body as string) as { operations: { op_id: string }[] };
        return jsonResponse(200, {
          results: body.operations.map((op, i) => ({
            op_id: op.op_id,
            outcome: 'accepted',
            token: { authority_epoch: 1, commit_seq: i + 1 },
          })),
        });
      }
      if (url.includes('/sync/changes')) {
        pulls += 1;
        // Both pulls return the SAME change (a crash-replay / re-delivery).
        return jsonResponse(200, {
          token: { authority_epoch: 1, commit_seq: 1 },
          changes: [CHANGE],
        });
      }
      throw new Error(`unexpected url ${url}`);
    };

    const transport = new OpsHubSyncTransport(
      { baseUrl: 'http://hub.test', sessionToken: 'unused-static' },
      hubFetch,
      { tokenProvider: () => token },
    );
    const ledger = new VolatileSyncChangeLedger();
    const engine = new SyncEngine({
      outbox: new VolatileSyncOutboxStore(),
      frontier: new VolatileSyncFrontierStore(),
      transport,
      applyChanges: (changes) => {
        recordChanges(ledger, changes);
      },
      now: () => new Date(1_000_000),
      random: () => 0.5,
    });

    // Push: the real transport carries the op and folds the accepted token.
    engine.enqueue(ENVELOPE);
    const push = await engine.pushOnce();
    expect(push).toMatchObject({ submitted: 1, accepted: 1 });
    expect(authSeen[0]).toBe('Bearer tok-1'); // per-call token provider supplied the bearer

    // Pull: the change is recorded in the ledger.
    await engine.pullOnce();
    expect(ledger.count()).toBe(1);
    expect(ledger.has(1, 1)).toBe(true);

    // A refresh happens, then the same change is re-delivered: idempotent (no double-record), and
    // the fresh token is used on the new request.
    token = 'tok-2';
    await engine.pullOnce();
    expect(pulls).toBe(2);
    expect(ledger.count()).toBe(1); // idempotent
    expect(authSeen.at(-1)).toBe('Bearer tok-2');
  });
});

describe('createTusFetch + TusUploadClient, full multi-chunk resumable upload', () => {
  it('probes, PATCHes every chunk, and surfaces the server hash on the final chunk', async () => {
    const total = 10;
    const finalSha = 'a'.repeat(64);
    let serverOffset = 0;
    const tusServer: FetchLike = async (_url, init): Promise<FetchLikeResponse> => {
      const headers: Record<string, string> = {};
      if (init.method === 'PATCH') {
        serverOffset += init.body ? init.body.length : 0;
        headers['Upload-Offset'] = String(serverOffset);
        if (serverOffset >= total) headers['Upload-Sha256'] = finalSha;
      } else {
        headers['Upload-Offset'] = String(serverOffset); // HEAD probe
      }
      return {
        status: init.method === 'PATCH' ? 204 : 200,
        headers: { get: (n) => headers[n] ?? null },
      };
    };

    const client = new TusUploadClient({ sessionToken: 'tok', fetchFn: createTusFetch(tusServer) });
    const url = 'http://hub.test/api/v1/sync/uploads/sess-1';

    expect(await client.probe(url)).toEqual({ offset: 0 });
    const first = await client.uploadChunk(url, 0, new Uint8Array(4));
    expect(first).toEqual({ offset: 4 });
    const second = await client.uploadChunk(url, 4, new Uint8Array(4));
    expect(second).toEqual({ offset: 8 });
    const last = await client.uploadChunk(url, 8, new Uint8Array(2));
    expect(last).toEqual({ offset: 10, sha256: finalSha }); // server hash on the final chunk
  });
});
