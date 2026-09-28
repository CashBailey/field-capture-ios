import { OpsHubV1Client } from '../src/adapters/sync';
import type { HubFetch, HubHttpResponse } from '../src/adapters/sync';
import {
  HubAuthError,
  HubNetworkError,
  HubResponseError,
  parseWorkflowRequirementsFromAssignments,
  type HubFieldTicketSubmission,
} from '../src/domain';

const CONFIG = { baseUrl: 'http://hub.test', sessionToken: 'tok-123' };

function jsonResponse(status: number, body: unknown): HubHttpResponse {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

/** Records calls; replies from a queue (or a single canned response). */
function fakeFetch(...responses: HubHttpResponse[]): HubFetch & {
  calls: {
    url: string;
    init: { method: string; headers: Record<string, string>; body?: string };
  }[];
} {
  const calls: {
    url: string;
    init: { method: string; headers: Record<string, string>; body?: string };
  }[] = [];
  const fn = async (
    url: string,
    init: { method: string; headers: Record<string, string>; body?: string },
  ) => {
    calls.push({ url, init });
    const next = responses.length > 1 ? responses.shift() : responses[0];
    if (!next) throw new Error('fakeFetch: no response queued');
    return next;
  };
  return Object.assign(fn, { calls });
}

const offlineFetch: HubFetch = async () => {
  throw new TypeError('Network request failed');
};

const SUBMISSION: HubFieldTicketSubmission = {
  idempotencyKey: 'gtr:devA:1:op-1',
  serviceRequestId: 'sr-9',
  snapshotHash: 'hash-abc',
  ticketNo: '12345',
  quantityBbl: 120,
  disposalTicketNo: 'D-123',
};

describe('OpsHubV1Client', () => {
  describe('getSessionStatus', () => {
    it('calls GET /api/v1/sync/session-status with bearer auth', async () => {
      const f = fakeFetch(
        jsonResponse(200, { clocked_in: true, clocked_in_since: '2026-06-09T12:00:00Z' }),
      );
      const client = new OpsHubV1Client(CONFIG, f);
      await client.getSessionStatus();
      expect(f.calls).toHaveLength(1);
      expect(f.calls[0].url).toBe('http://hub.test/api/v1/sync/session-status');
      expect(f.calls[0].init.method).toBe('GET');
      expect(f.calls[0].init.headers.Authorization).toBe('Bearer tok-123');
    });

    it('maps a clocked-in response, consuming server_time (clock-skew handling)', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            clocked_in: true,
            clocked_in_since: '2026-06-09T12:00:00Z',
            source: 'timeclock',
            employee_id: 'emp-1',
            assignments_available: true,
            server_time: '2026-06-09T12:00:05Z',
          }),
        ),
      );
      await expect(client.getSessionStatus()).resolves.toEqual({
        clockedIn: true,
        clockedInSince: '2026-06-09T12:00:00Z',
        source: 'timeclock',
        employeeId: 'emp-1',
        assignmentsAvailable: true,
        serverTime: '2026-06-09T12:00:05Z',
      });
    });

    it('reads the `since` alias when clocked_in_since is absent (real Hub sends both)', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            clocked_in: true,
            since: '2026-06-09T06:30:00Z',
            server_time: '2026-06-09T13:00:00Z',
          }),
        ),
      );
      await expect(client.getSessionStatus()).resolves.toMatchObject({
        clockedIn: true,
        clockedInSince: '2026-06-09T06:30:00Z',
        serverTime: '2026-06-09T13:00:00Z',
      });
    });

    it('maps a clocked-out response', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { clocked_in: false })),
      );
      await expect(client.getSessionStatus()).resolves.toMatchObject({
        clockedIn: false,
        clockedInSince: null,
      });
    });

    it('rejects with HubAuthError on 401', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(401, {})));
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubAuthError);
    });

    it('rejects with HubAuthError on 403', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(403, {})));
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubAuthError);
    });

    it('rejects with HubNetworkError when fetch itself fails (offline)', async () => {
      const client = new OpsHubV1Client(CONFIG, offlineFetch);
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubNetworkError);
    });

    it('rejects with HubResponseError on a malformed body rather than guessing clock state', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(200, { nope: 1 })));
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubResponseError);
    });

    it('rejects with HubResponseError on an unexpected 5xx', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(500, {})));
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubResponseError);
    });
  });

  describe('getAssignments', () => {
    const WIRE_ASSIGNMENT = {
      service_request_id: 'sr-9',
      snapshot_hash: 'hash-abc',
      snapshot: { srId: 'sr-9', customer: 'ACME' },
    };

    it('calls GET /api/v1/sync/assignments and maps entries with snapshot hashes', async () => {
      const f = fakeFetch(jsonResponse(200, { assignments: [WIRE_ASSIGNMENT] }));
      const client = new OpsHubV1Client(CONFIG, f);
      const got = await client.getAssignments();
      expect(f.calls[0].url).toBe('http://hub.test/api/v1/sync/assignments');
      expect(got).toEqual([
        {
          serviceRequestId: 'sr-9',
          snapshotHash: 'hash-abc',
          snapshot: { srId: 'sr-9', customer: 'ACME' },
        },
      ]);
    });

    it('maps rich assignment fields while preserving the raw snapshot', async () => {
      const rich = {
        service_request_id: 'sr-99',
        snapshot_hash: 'hash-rich',
        // Real Hub sends a string == snapshot_hash; a legacy finite number must still coerce.
        latest_server_version: 42,
        snapshot: { srId: 'sr-99', legacy: true },
        customer: { customer_id: 'cust-1', name: 'ACME Oil' },
        lease: { lease_id: 'lease-1', name: 'North Lease' },
        wells: [
          {
            well_id: 'well-12',
            lease_id: 'lease-1',
            name: 'Well 12H',
          },
        ],
        material: { name: 'Produced water' },
        disposal_site: {
          site_id: 'disp-1',
          name: 'SWD 8',
        },
        vehicle: { vehicle_id: 'truck-7', label: 'Truck 7' },
        // Real Hub sends job_type as an object { id, name }, not a bare string.
        job_type: { id: 'jt-1', name: 'water-haul' },
        ignored_extra: { value: 'ignored' },
        workflow_requirements: {
          clock_in_required: true,
          required_steps: ['pre_trip_dvir', 'jha'],
        },
      };
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { assignments: [rich] })),
      );

      await expect(client.getAssignments()).resolves.toEqual([
        {
          serviceRequestId: 'sr-99',
          snapshotHash: 'hash-rich',
          latestServerVersion: '42',
          snapshot: { srId: 'sr-99', legacy: true },
          details: {
            customer: { id: 'cust-1', name: 'ACME Oil' },
            lease: { id: 'lease-1', name: 'North Lease' },
            wells: [
              {
                id: 'well-12',
                leaseId: 'lease-1',
                name: 'Well 12H',
              },
            ],
            material: 'Produced water',
            disposalSite: { id: 'disp-1', name: 'SWD 8' },
            vehicle: { id: 'truck-7', name: 'Truck 7' },
            jobType: { id: 'jt-1', name: 'water-haul' },
            workflowRequirements: {
              clockInRequired: true,
              requiredSteps: ['pre_trip_dvir', 'jha'],
            },
          },
        },
      ]);
    });

    it('ignores extra fields outside the Mobile assignment contract', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            assignments: [
              {
                service_request_id: 'sr-9',
                snapshot_hash: 'hash-abc',
                ignored_extra: { value: 'ignored' },
              },
            ],
          }),
        ),
      );

      await expect(client.getAssignments()).resolves.toEqual([
        {
          serviceRequestId: 'sr-9',
          snapshotHash: 'hash-abc',
          snapshot: null,
        },
      ]);
    });

    it('derives workflow requirements from rich assignments and legacy snapshots', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            assignments: [
              {
                service_request_id: 'sr-rich',
                snapshot_hash: 'hash-rich',
                workflow_requirements: {
                  clock_in_required: true,
                  required_steps: ['pre_trip_dvir'],
                },
                snapshot: {},
              },
              {
                service_request_id: 'sr-legacy',
                snapshot_hash: 'hash-legacy',
                snapshot: { workflow_requirements: { require_jha_per_sr: true } },
              },
            ],
          }),
        ),
      );
      const assignments = await client.getAssignments();

      expect(parseWorkflowRequirementsFromAssignments(assignments, 'sr-rich')).toEqual({
        clockInRequired: true,
        requiredSteps: ['pre_trip_dvir'],
      });
      // Legacy snapshot fallback (boolean keys) still gates correctly.
      expect(parseWorkflowRequirementsFromAssignments(assignments, 'sr-legacy')).toEqual({
        clockInRequired: false,
        requiredSteps: ['jha'],
      });
    });

    it('accepts a bare-array body too', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(200, [WIRE_ASSIGNMENT])));
      await expect(client.getAssignments()).resolves.toHaveLength(1);
    });

    it('maps an empty assignment list', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { assignments: [] })),
      );
      await expect(client.getAssignments()).resolves.toEqual([]);
    });

    it('rejects with HubResponseError when an entry is missing its snapshot_hash (drift detection depends on it)', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { assignments: [{ service_request_id: 'sr-9' }] })),
      );
      await expect(client.getAssignments()).rejects.toBeInstanceOf(HubResponseError);
    });

    it('rejects with HubAuthError / HubNetworkError consistently with session-status', async () => {
      await expect(
        new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(401, {}))).getAssignments(),
      ).rejects.toBeInstanceOf(HubAuthError);
      await expect(
        new OpsHubV1Client(CONFIG, offlineFetch).getAssignments(),
      ).rejects.toBeInstanceOf(HubNetworkError);
    });
  });

  describe('submitFieldTicket', () => {
    it('POSTs the snake_case payload with bearer auth and Idempotency-Key header', async () => {
      const f = fakeFetch(jsonResponse(201, { accepted: true }));
      const client = new OpsHubV1Client(CONFIG, f);
      await client.submitFieldTicket(SUBMISSION);
      const call = f.calls[0];
      expect(call.url).toBe('http://hub.test/api/v1/sync/submit');
      expect(call.init.method).toBe('POST');
      expect(call.init.headers.Authorization).toBe('Bearer tok-123');
      expect(call.init.headers['Idempotency-Key']).toBe('gtr:devA:1:op-1');
      expect(JSON.parse(call.init.body as string)).toEqual({
        idempotency_key: 'gtr:devA:1:op-1',
        service_request_id: 'sr-9',
        snapshot_hash: 'hash-abc',
        ticket_no: '12345',
        quantity_bbl: 120,
        disposal_ticket_no: 'D-123',
      });
    });

    it('maps 201 to accepted (not a duplicate)', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(201, { accepted: true, ticket_id: 'ft-1' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'accepted',
        duplicate: false,
        ticketId: 'ft-1',
      });
    });

    it('maps a duplicate replay (200 + duplicate flag) to accepted+duplicate — retry-safe', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { accepted: true, duplicate: true, ticket_id: 'ft-1' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'accepted',
        duplicate: true,
        ticketId: 'ft-1',
      });
    });

    it('surfaces snapshot_drift on a 201 ACCEPTED submit (durable, but flagged for review)', async () => {
      // Verified live against opshub: a stale snapshot_hash still commits (201, accepted:true)
      // but the Hub sets snapshot_drift:true. The work is durable; the drift must NOT be swallowed.
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(201, {
            accepted: true,
            ticket_id: 'ft-drift',
            duplicate: false,
            snapshot_drift: true,
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'accepted',
        duplicate: false,
        snapshotDrift: true,
        ticketId: 'ft-drift',
      });
    });

    it('omits snapshotDrift when the Hub reports no drift (no noise on the happy path)', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(201, { accepted: true, ticket_id: 'ft-1', snapshot_drift: false })),
      );
      const result = await client.submitFieldTicket(SUBMISSION);
      expect(result).toEqual({ outcome: 'accepted', duplicate: false, ticketId: 'ft-1' });
      expect('snapshotDrift' in result).toBe(false);
    });

    it('maps the legacy Hub success shape to accepted for compatibility', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            field_ticket_id: 'legacy-ft-1',
            status: 'created',
            duplicate: false,
            snapshot_drift: false,
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'accepted',
        duplicate: false,
        ticketId: 'legacy-ft-1',
      });
    });

    it('maps legacy duplicate success to accepted+duplicate', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            field_ticket_id: 'legacy-ft-1',
            status: 'accepted',
            duplicate: true,
            snapshot_drift: false,
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'accepted',
        duplicate: true,
        ticketId: 'legacy-ft-1',
      });
    });

    it('NEVER lets the legacy shape override an explicit accepted:false', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            accepted: false, // Hub explicitly did not accept — compat must not promote this
            field_ticket_id: 'legacy-ft-1',
            status: 'submitted',
            duplicate: false,
            snapshot_drift: false,
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'transient',
        reason: 'malformed-response',
      });
    });

    it('reads field_ticket_id as the ticket id on the modern accepted:true path too', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(200, { accepted: true, field_ticket_id: 'ft-legacy-id' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'accepted',
        duplicate: false,
        ticketId: 'ft-legacy-id',
      });
    });

    it('maps legacy snapshot_drift=true to needs-review, never accepted', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(200, {
            field_ticket_id: 'legacy-ft-1',
            status: 'created',
            duplicate: false,
            snapshot_drift: true,
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'rejected',
        kind: 'needs-review',
        httpStatus: 200,
        rejectionCode: 'snapshot_drift',
      });
    });

    it('maps 403 (e.g. not clocked in) to a user-visible blocked rejection', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(403, { reason_code: 'not_clocked_in', detail: 'no open punch' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'rejected',
        kind: 'blocked',
        httpStatus: 403,
        rejectionCode: 'not_clocked_in',
        detail: 'no open punch',
      });
    });

    it('maps 403 with no body code to a fallback code (detail never lost silently)', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(403, {})));
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'rejected',
        kind: 'blocked',
        rejectionCode: 'forbidden',
      });
    });

    it('maps the real-Hub 409 workflow guard to blocked with Hub`s verbatim reason', async () => {
      // opshub returns 409 {detail:"Driver is not clocked in — clock in before submitting work."}
      // (workflow.WorkflowError) — no structured code. Blocked = retryable after the user acts.
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(
          jsonResponse(409, {
            detail: 'Driver is not clocked in — clock in before submitting work.',
          }),
        ),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'rejected',
        kind: 'blocked',
        httpStatus: 409,
        rejectionCode: 'workflow_blocked',
        detail: 'Driver is not clocked in — clock in before submitting work.',
      });
    });

    it('still passes through an explicit 409 reason_code when one is provided', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(409, { reason_code: 'in_progress' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'rejected',
        kind: 'blocked',
        httpStatus: 409,
        rejectionCode: 'in_progress',
      });
    });

    it('maps 412 (snapshot/version drift) to needs-review — never silently accepted', async () => {
      const client = new OpsHubV1Client(
        CONFIG,
        fakeFetch(jsonResponse(412, { reason_code: 'stale_version' })),
      );
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'rejected',
        kind: 'needs-review',
        httpStatus: 412,
        rejectionCode: 'stale_version',
      });
    });

    it('maps 422 (idempotency-key payload mismatch) to needs-review', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(422, {})));
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'rejected',
        kind: 'needs-review',
        httpStatus: 422,
      });
    });

    it('maps 401 to auth-failed (visible; the caller re-auths and retries)', async () => {
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(401, {})));
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toEqual({
        outcome: 'auth-failed',
        httpStatus: 401,
      });
    });

    it('maps a network failure to transient — the work is NOT lost and NOT rejected', async () => {
      const client = new OpsHubV1Client(CONFIG, offlineFetch);
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'transient',
        reason: 'network',
      });
    });

    it('maps 5xx/429 to transient (retryable), never to accepted or rejected', async () => {
      for (const status of [500, 503, 429]) {
        const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(status, {})));
        await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
          outcome: 'transient',
          reason: 'server',
          httpStatus: status,
        });
      }
    });

    it('treats a 2xx body without accepted:true as malformed → transient, NOT accepted', async () => {
      // A proxy/captive portal can return 200 with garbage. Marking work durable on that would
      // violate "never pretend unsynced work is safe".
      const client = new OpsHubV1Client(CONFIG, fakeFetch(jsonResponse(200, { weird: true })));
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'transient',
        reason: 'malformed-response',
      });
    });
  });

  describe('request time-bounding (a hung Hub must not hang the app)', () => {
    // A fetch that never settles — simulates a black-holed connection / silent server.
    const hungFetch: HubFetch = () => new Promise<HubHttpResponse>(() => {});

    it('times a hung GET out into HubNetworkError (gate locks visibly, app stays responsive)', async () => {
      const client = new OpsHubV1Client(CONFIG, hungFetch, { timeoutMs: 10 });
      await expect(client.getSessionStatus()).rejects.toBeInstanceOf(HubNetworkError);
    });

    it('times a hung submit out into a transient outcome — evidence never waits forever in-flight', async () => {
      const client = new OpsHubV1Client(CONFIG, hungFetch, { timeoutMs: 10 });
      await expect(client.submitFieldTicket(SUBMISSION)).resolves.toMatchObject({
        outcome: 'transient',
        reason: 'network',
      });
    });
  });
});
