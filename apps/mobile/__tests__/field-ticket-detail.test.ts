/**
 * Full paper-ticket detail (gauges/times/rig/line-items) rides the field-ticket submit additively:
 *  - OpsHubV1Client serializes it to snake_case `field_ticket_detail` on POST /sync/submit,
 *  - submitFieldTicket carries it verbatim in the durable evidence envelope payload,
 *  - inputFromEvidence rebuilds it for the manual-retry path (same idempotency key, no data loss).
 * The minimal contract scalars (ticket_no/quantity_bbl/disposal_ticket_no) are unchanged.
 */
import { OpsHubV1Client } from '../src/adapters/sync';
import type { HubFetchInit, HubHttpResponse } from '../src/adapters/sync';
import {
  VolatileTicketEvidenceStore,
  submitFieldTicket,
  type FieldTicketDetail,
  type FieldTicketInput,
} from '../src/domain';
import { inputFromEvidence } from '../src/runtime';

const DETAIL: FieldTicketDetail = {
  rigNo: 'R-9',
  times: { yardArrival: '06:10', timeIn: '07:25', timeOut: '09:40' },
  tanks: [
    {
      label: 'Truck',
      locationTime: '08:05',
      beginning: { total: { ft: 12, inches: 4 }, water: { ft: 2, inches: 1 } },
      ending: { total: { ft: 3, inches: 6 } },
      waterPulled: { ft: 9, inches: 2 },
      barrelsPulled: 62,
    },
    { label: 'Trailer', barrelsPulled: 38 },
  ],
  lineItems: [{ description: 'Vacuum truck — saltwater haul (SW)', qty: 100 }],
};

const INPUT: FieldTicketInput = {
  serviceRequestId: 'sr-9',
  snapshotHash: 'hash-abc',
  ticketNo: '2026-000004',
  quantityBbl: 100,
  disposalTicketNo: 'D-UI-0004',
  deviceInstanceId: 'devA',
  localSeq: 1,
  opUuid: 'op-uuid-1',
  detail: DETAIL,
};

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

describe('field-ticket full detail on the submit path', () => {
  it('OpsHubV1Client serializes detail to snake_case field_ticket_detail', async () => {
    let sentBody: Record<string, unknown> | undefined;
    const client = new OpsHubV1Client(
      { baseUrl: 'http://hub.test', sessionToken: 'tok' },
      async (url: string, init: HubFetchInit) => {
        expect(url).toBe('http://hub.test/api/v1/sync/submit');
        sentBody = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse(201, { accepted: true, ticket_id: 'ft-1', duplicate: false });
      },
    );

    const outcome = await client.submitFieldTicket({
      idempotencyKey: 'gtr:devA:1:op-uuid-1',
      serviceRequestId: 'sr-9',
      snapshotHash: 'hash-abc',
      ticketNo: '2026-000004',
      quantityBbl: 100,
      disposalTicketNo: 'D-UI-0004',
      detail: DETAIL,
    });
    expect(outcome.outcome).toBe('accepted');

    // contract scalars untouched
    expect(sentBody).toMatchObject({
      ticket_no: '2026-000004',
      quantity_bbl: 100,
      disposal_ticket_no: 'D-UI-0004',
    });
    // rich detail, snake_cased
    expect(sentBody!.field_ticket_detail).toEqual({
      rig_no: 'R-9',
      times: { yard_arrival: '06:10', time_in: '07:25', time_out: '09:40' },
      tanks: [
        {
          label: 'Truck',
          location_time: '08:05',
          beginning: { total: { ft: 12, inches: 4 }, water: { ft: 2, inches: 1 } },
          ending: { total: { ft: 3, inches: 6 } },
          water_pulled: { ft: 9, inches: 2 },
          barrels_pulled: 62,
        },
        { label: 'Trailer', barrels_pulled: 38 },
      ],
      line_items: [{ description: 'Vacuum truck — saltwater haul (SW)', qty: 100 }],
    });
  });

  it('omits field_ticket_detail entirely when no detail is present (lean V1 wire preserved)', async () => {
    let sentBody: Record<string, unknown> | undefined;
    const client = new OpsHubV1Client(
      { baseUrl: 'http://hub.test', sessionToken: 'tok' },
      async (_url: string, init: HubFetchInit) => {
        sentBody = JSON.parse(init.body as string) as Record<string, unknown>;
        return jsonResponse(201, { accepted: true, duplicate: false });
      },
    );
    await client.submitFieldTicket({
      idempotencyKey: 'gtr:devA:2:op-2',
      serviceRequestId: 'sr-9',
      snapshotHash: 'hash-abc',
      ticketNo: '2026-000004',
      quantityBbl: 100,
      disposalTicketNo: 'D-1',
    });
    expect('field_ticket_detail' in sentBody!).toBe(false);
  });

  it('submitFieldTicket stores detail in the durable evidence envelope, and inputFromEvidence rebuilds it', async () => {
    const store = new VolatileTicketEvidenceStore();
    const result = await submitFieldTicket(
      {
        submitter: { submitFieldTicket: async () => ({ outcome: 'accepted', duplicate: false }) },
        evidenceStore: store,
      },
      INPUT,
    );
    expect(result.status).toBe('accepted');

    const evidence = store.get('gtr:devA:1:op-uuid-1');
    expect(evidence?.envelope.payload.detail).toEqual(DETAIL);

    // manual-retry path reconstructs the same input, detail included (no silent loss)
    expect(inputFromEvidence(evidence!)).toMatchObject({ ticketNo: '2026-000004', detail: DETAIL });
  });
});
