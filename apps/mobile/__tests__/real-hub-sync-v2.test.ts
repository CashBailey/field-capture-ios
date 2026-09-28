/**
 * Real-Hub V2 sync-transport regression. The fixture in `fixtures/real-hub-sync-v2.json` holds
 * VERBATIM `POST /api/v1/sync/commands` and `GET /api/v1/sync/changes` responses captured from a
 * locally-running opshub Hub. Unlike assignments, the V2 transport had NO wire-breaks — this
 * pins that fact to reality so future Hub contract drift on the ADR-004 path fails loudly here.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { sync } from '@fieldcapture/contracts';

import { OpsHubSyncTransport } from '../src/adapters/sync';
import type { HubFetch, HubFetchInit, HubHttpResponse } from '../src/adapters/sync';

const FIXTURE = JSON.parse(
  readFileSync(join(__dirname, 'fixtures', 'real-hub-sync-v2.json'), 'utf8'),
) as {
  changesPage: unknown;
  commandsAccepted: unknown;
  commandsRejected: unknown;
};

const CONFIG = { baseUrl: 'http://hub.test', sessionToken: 'tok-123' };

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

function fakeFetch(response: HubHttpResponse): HubFetch {
  return async (_url: string, _init: HubFetchInit) => response;
}

const ENVELOPE: sync.OperationEnvelope = {
  opId: 'op-vtest-1',
  kind: 'event',
  type: 'field.note',
  idempotencyKey: 'gtr:devA:50:op-vtest-1',
  localSeq: 50,
  dependsOn: [],
  payload: { service_request_id: 'sr-x', note: 'hi' },
};

describe('real opshub V2 sync transport', () => {
  it('parses a verbatim accepted command result (op_id + {authority_epoch, commit_seq} token)', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, FIXTURE.commandsAccepted)),
    );
    await expect(transport.submitBatch([ENVELOPE])).resolves.toEqual([
      { outcome: 'accepted', opId: 'op-vtest-1', token: { authorityEpoch: 1, commitSeq: 1 } },
    ]);
  });

  it('parses a verbatim rejected command result (rejection_code + detail)', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, FIXTURE.commandsRejected)),
    );
    await expect(transport.submitBatch([ENVELOPE])).resolves.toEqual([
      {
        outcome: 'rejected',
        opId: 'op-vtest-2',
        rejectionCode: 'invalid_payload',
        detail: 'Mutable command payload must identify an entity.',
      },
    ]);
  });

  it('parses a verbatim changes page (token advances; change rows passed through opaquely)', async () => {
    const transport = new OpsHubSyncTransport(
      CONFIG,
      fakeFetch(jsonResponse(200, FIXTURE.changesPage)),
    );
    const page = await transport.pullChanges({ authorityEpoch: 0, commitSeq: 0 });
    expect(page.token).toEqual({ authorityEpoch: 1, commitSeq: 1 });
    expect(page.changes).toHaveLength(1);
    // applyChanges (Section 4e) will consume these; here we only assert the real row shape survives.
    expect(page.changes[0]).toMatchObject({
      authority_epoch: 1,
      commit_seq: 1,
      op_id: 'op-vtest-1',
      entity_type: 'sync_operation',
      change_type: 'field.note',
    });
  });
});
