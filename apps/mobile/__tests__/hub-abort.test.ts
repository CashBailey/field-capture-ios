/**
 * Request abort/cancellation (deferred item: "HubFetch gains an abort surface").
 *
 * What must hold:
 *  - a timeout ABORTS the underlying network work (the fetch sees signal.aborted), not just a
 *    local race that leaves the socket draining battery;
 *  - a caller-provided AbortSignal cancels an in-flight request promptly;
 *  - an aborted submit never strands its evidence in-flight — the row returns to `pending` and
 *    a later retry with the SAME idempotency key succeeds;
 *  - a fetch implementation that ignores the signal is still time-bounded (race backstop).
 */
import { OpsHubV1Client } from '../src/adapters/sync';
import type { HubFetch, HubFetchInit, HubHttpResponse } from '../src/adapters/sync';
import {
  HubNetworkError,
  submitFieldTicket,
  VolatileTicketEvidenceStore,
  type FieldTicketInput,
} from '../src/domain';

const CONFIG = { baseUrl: 'http://hub.test', sessionToken: 'tok-123' };

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

/** A fetch that never resolves on its own but rejects when its signal aborts (like real fetch). */
function signalAwareHungFetch(): HubFetch & { seenSignals: (AbortSignal | undefined)[] } {
  const seenSignals: (AbortSignal | undefined)[] = [];
  const fn = (_url: string, init: HubFetchInit) => {
    seenSignals.push(init.signal);
    return new Promise<HubHttpResponse>((_, reject) => {
      if (init.signal?.aborted) {
        reject(new Error('aborted before dispatch'));
        return;
      }
      init.signal?.addEventListener('abort', () => reject(new Error('request aborted')));
    });
  };
  return Object.assign(fn, { seenSignals });
}

const INPUT: FieldTicketInput = {
  serviceRequestId: 'sr-9',
  snapshotHash: 'hash-abc',
  ticketNo: '12345',
  quantityBbl: 120,
  disposalTicketNo: 'D-123',
  deviceInstanceId: 'devA',
  localSeq: 1,
  opUuid: 'op-1',
};

describe('timeout aborts real network work', () => {
  it('GET: the fetch sees an aborted signal and the caller gets HubNetworkError', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 10 });
    await expect(client.getSessionStatus()).rejects.toThrow(HubNetworkError);
    expect(f.seenSignals).toHaveLength(1);
    expect(f.seenSignals[0]?.aborted).toBe(true);
  });

  it('submit: maps to a transient outcome and the signal is aborted', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 10 });
    const outcome = await client.submitFieldTicket({
      idempotencyKey: 'gtr:devA:1:op-1',
      serviceRequestId: 'sr-9',
      snapshotHash: 'hash-abc',
      ticketNo: '12345',
      quantityBbl: 120,
      disposalTicketNo: 'D-123',
    });
    expect(outcome).toMatchObject({ outcome: 'transient', reason: 'network' });
    expect(f.seenSignals[0]?.aborted).toBe(true);
  });

  it('a fetch that ignores its signal is still time-bounded (race backstop)', async () => {
    const ignoresSignal: HubFetch = () => new Promise<HubHttpResponse>(() => {});
    const client = new OpsHubV1Client(CONFIG, ignoresSignal, { timeoutMs: 10 });
    await expect(client.getAssignments()).rejects.toThrow(HubNetworkError);
  });
});

describe('caller cancellation', () => {
  it('an external signal aborts an in-flight GET promptly', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 60_000 });
    const controller = new AbortController();
    const pending = client.getSessionStatus({ signal: controller.signal });
    controller.abort();
    await expect(pending).rejects.toThrow(HubNetworkError);
    expect(f.seenSignals[0]?.aborted).toBe(true);
  });

  it('an already-aborted signal never dispatches network work', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 60_000 });
    const controller = new AbortController();
    controller.abort();
    await expect(client.getAssignments({ signal: controller.signal })).rejects.toThrow(
      HubNetworkError,
    );
    expect(f.seenSignals).toHaveLength(0);
  });

  it('an external signal cancels an in-flight submit as a transient outcome', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 60_000 });
    const controller = new AbortController();
    const pending = client.submitFieldTicket(
      {
        idempotencyKey: 'gtr:devA:1:op-1',
        serviceRequestId: 'sr-9',
        snapshotHash: 'hash-abc',
        ticketNo: '12345',
        quantityBbl: 120,
        disposalTicketNo: 'D-123',
      },
      { signal: controller.signal },
    );
    controller.abort();
    await expect(pending).resolves.toMatchObject({ outcome: 'transient', reason: 'network' });
  });
});

describe('abort never leaks in-flight submit state', () => {
  it('after a timeout-aborted submit the evidence is pending, not stuck in-flight', async () => {
    const f = signalAwareHungFetch();
    const client = new OpsHubV1Client(CONFIG, f, { timeoutMs: 10 });
    const store = new VolatileTicketEvidenceStore();

    const result = await submitFieldTicket({ submitter: client, evidenceStore: store }, INPUT);
    expect(result.status).toBe('pending-retry');

    const evidence = store.get('gtr:devA:1:op-1');
    expect(evidence?.state).toBe('pending'); // NOT 'in-flight'
    expect(evidence?.attempts).toBe(1);
  });

  it('a retry after an aborted attempt reuses the same key and can succeed', async () => {
    const store = new VolatileTicketEvidenceStore();
    const hung = signalAwareHungFetch();
    const failing = new OpsHubV1Client(CONFIG, hung, { timeoutMs: 10 });
    await submitFieldTicket({ submitter: failing, evidenceStore: store }, INPUT);

    const keys: string[] = [];
    const ok: HubFetch = async (_url, init) => {
      keys.push(init.headers['Idempotency-Key']);
      return jsonResponse(200, { accepted: true, ticket_id: 'ft-1' });
    };
    const succeeding = new OpsHubV1Client(CONFIG, ok, { timeoutMs: 60_000 });
    const retry = await submitFieldTicket({ submitter: succeeding, evidenceStore: store }, INPUT);

    expect(retry.status).toBe('accepted');
    expect(keys).toEqual(['gtr:devA:1:op-1']); // same idempotency key — Hub can never double-create
    expect(store.get('gtr:devA:1:op-1')?.state).toBe('accepted');
  });
});
