/**
 * Real Ops Hub v1 client (first real integration slice). Implements the domain gateway
 * interfaces over the Hub's minimal mobile routes:
 *
 *   GET  /api/v1/sync/session-status
 *   GET  /api/v1/sync/assignments
 *   POST /api/v1/sync/submit
 *
 * This is deliberately NOT the ADR 004 `SyncTransport` engine (`/sync/commands`, `/sync/changes`,
 * tus uploads) — that protocol is the real `OpsHubSyncTransport`, which lives beside this V1
 * client. Wire contract: docs/integration/ops-triad-contract.md.
 *
 * Mapping discipline (cross-cutting invariant #2):
 *  - Reads throw typed errors (`HubNetworkError` / `HubAuthError` / `HubResponseError`) — the
 *    caller locks field work visibly instead of assuming a clock-in or inventing assignments.
 *  - Submit NEVER throws for an expected condition; it returns a `HubSubmitOutcome` so every arm
 *    (accepted / rejected / auth / transient) is handled and rejection detail is never lost.
 *  - Only an explicit `accepted: true` body makes a submit "accepted". A 2xx with anything else
 *    (captive portal, proxy garbage) is `transient`, not success.
 */
import {
  HubAuthError,
  HubNetworkError,
  HubResponseError,
  type AssignmentSource,
  type FieldTicketDetail,
  type FieldTicketSubmitter,
  type HubAssignment,
  type HubFieldTicketSubmission,
  type HubRequestOptions,
  type HubSessionStatus,
  type HubSubmitOutcome,
  type SessionStatusSource,
  parseHubAssignmentEntry,
} from '../../domain';
import type { HubRuntimeConfig } from '../../config/hubConfig';
import { boundedAbortableFetch } from './boundedFetch';

/** Minimal response surface the client needs — lets tests fake fetch with plain objects. */
export interface HubHttpResponse {
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}

/** Request init the client hands its fetch. `signal` aborts the underlying network work. */
export interface HubFetchInit {
  method: 'GET' | 'POST';
  headers: Record<string, string>;
  body?: string;
  signal?: AbortSignal;
}

export type HubFetch = (url: string, init: HubFetchInit) => Promise<HubHttpResponse>;

const ROUTES = {
  sessionStatus: '/api/v1/sync/session-status',
  assignments: '/api/v1/sync/assignments',
  submit: '/api/v1/sync/submit',
} as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Snake-case the full paper-ticket detail for the wire (`field_ticket_detail`). Only the camelCase
 * keys are converted; ft/inches/total/water/condensate are already wire-shaped. Undefined fields are
 * dropped so the Hub sees a clean, minimal blob. See docs/integration/field-ticket-full-form-hub-spec.md.
 */
function toWireDetail(d: FieldTicketDetail): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (d.rigNo !== undefined) out.rig_no = d.rigNo;
  if (d.times !== undefined) {
    const tm: Record<string, unknown> = {};
    if (d.times.yardArrival !== undefined) tm.yard_arrival = d.times.yardArrival;
    if (d.times.timeIn !== undefined) tm.time_in = d.times.timeIn;
    if (d.times.timeOut !== undefined) tm.time_out = d.times.timeOut;
    out.times = tm;
  }
  if (d.tanks !== undefined) {
    out.tanks = d.tanks.map((tk) => {
      const o: Record<string, unknown> = {};
      if (tk.label !== undefined) o.label = tk.label;
      if (tk.locationTime !== undefined) o.location_time = tk.locationTime;
      if (tk.beginning !== undefined) o.beginning = tk.beginning;
      if (tk.ending !== undefined) o.ending = tk.ending;
      if (tk.waterPulled !== undefined) o.water_pulled = tk.waterPulled;
      if (tk.barrelsPulled !== undefined) o.barrels_pulled = tk.barrelsPulled;
      return o;
    });
  }
  if (d.lineItems !== undefined) {
    out.line_items = d.lineItems.map((li) => ({
      description: li.description,
      ...(li.qty !== undefined ? { qty: li.qty } : {}),
      ...(li.rate !== undefined ? { rate: li.rate } : {}),
      ...(li.total !== undefined ? { total: li.total } : {}),
    }));
  }
  return out;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function isLegacyAcceptedStatus(value: unknown): boolean {
  return value === 'accepted' || value === 'created' || value === 'submitted';
}

/** Default wall-clock bound per request. RN's fetch has NO default timeout — without a bound, a
 * black-holed connection would hang a submit forever and leave its local evidence sitting
 * in-flight. */
const DEFAULT_TIMEOUT_MS = 15_000;

export class OpsHubV1Client
  implements SessionStatusSource, AssignmentSource, FieldTicketSubmitter
{
  private readonly config: HubRuntimeConfig;
  private readonly fetchFn: HubFetch;
  private readonly timeoutMs: number;

  constructor(config: HubRuntimeConfig, fetchFn?: HubFetch, options?: { timeoutMs?: number }) {
    this.config = config;
    // Default to the runtime's global fetch (React Native provides one); injectable for tests.
    this.fetchFn = fetchFn ?? (globalThis.fetch as unknown as HubFetch);
    this.timeoutMs = options?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /**
   * fetch with a wall-clock bound that ABORTS the underlying network work (see boundedFetch.ts).
   * A hung Hub degrades into the normal network-failure path (locked gate / transient submit)
   * instead of an indefinite hang; cancellation never cancels the queued work itself.
   */
  private boundedFetch(
    url: string,
    init: { method: 'GET' | 'POST'; headers: Record<string, string>; body?: string },
    externalSignal?: AbortSignal,
  ): Promise<HubHttpResponse> {
    return boundedAbortableFetch(this.fetchFn, url, init, this.timeoutMs, externalSignal);
  }

  private headers(extra?: Record<string, string>): Record<string, string> {
    return {
      Authorization: `Bearer ${this.config.sessionToken}`,
      Accept: 'application/json',
      ...extra,
    };
  }

  /** Shared GET path: network → HubNetworkError; 401/403 → HubAuthError; other non-2xx / non-JSON → HubResponseError. */
  private async getJson(path: string, options?: HubRequestOptions): Promise<unknown> {
    let response: HubHttpResponse;
    try {
      response = await this.boundedFetch(
        `${this.config.baseUrl}${path}`,
        {
          method: 'GET',
          headers: this.headers(),
        },
        options?.signal,
      );
    } catch (error) {
      throw new HubNetworkError(`Hub unreachable for GET ${path}: ${String(error)}`, {
        cause: error,
      });
    }
    if (response.status === 401 || response.status === 403) {
      throw new HubAuthError(
        `Hub auth failed (${response.status}) for GET ${path}`,
        response.status,
      );
    }
    if (!response.ok) {
      throw new HubResponseError(
        `Hub returned ${response.status} for GET ${path}`,
        response.status,
      );
    }
    try {
      return await response.json();
    } catch {
      throw new HubResponseError(`Hub returned a non-JSON body for GET ${path}`, response.status);
    }
  }

  async getSessionStatus(options?: HubRequestOptions): Promise<HubSessionStatus> {
    const body = await this.getJson(ROUTES.sessionStatus, options);
    if (!isRecord(body) || typeof body.clocked_in !== 'boolean') {
      // Never guess clock state from a malformed answer — the gate stays locked instead.
      throw new HubResponseError('session-status body is missing a boolean clocked_in');
    }
    // The real Hub sends `clocked_in_since` AND a `since` alias (same value); read either.
    const serverTime = optionalString(body.server_time);
    return {
      clockedIn: body.clocked_in,
      clockedInSince: optionalString(body.clocked_in_since) ?? optionalString(body.since) ?? null,
      source: optionalString(body.source) ?? null,
      employeeId: optionalString(body.employee_id) ?? null,
      assignmentsAvailable: body.assignments_available === true,
      ...(serverTime !== undefined ? { serverTime } : {}),
    };
  }

  async getAssignments(options?: HubRequestOptions): Promise<HubAssignment[]> {
    const body = await this.getJson(ROUTES.assignments, options);
    const raw = Array.isArray(body) ? body : isRecord(body) ? body.assignments : undefined;
    if (!Array.isArray(raw)) {
      throw new HubResponseError('assignments body is not a list');
    }
    return raw.map((entry, i) => parseHubAssignmentEntry(entry, `assignment[${i}]`));
  }

  async submitFieldTicket(
    submission: HubFieldTicketSubmission,
    options?: HubRequestOptions,
  ): Promise<HubSubmitOutcome> {
    let response: HubHttpResponse;
    try {
      response = await this.boundedFetch(
        `${this.config.baseUrl}${ROUTES.submit}`,
        {
          method: 'POST',
          headers: this.headers({
            'Content-Type': 'application/json',
            // Also in the body; the header lets Hub middleware dedupe before parsing.
            'Idempotency-Key': submission.idempotencyKey,
          }),
          body: JSON.stringify({
            idempotency_key: submission.idempotencyKey,
            service_request_id: submission.serviceRequestId,
            snapshot_hash: submission.snapshotHash,
            ticket_no: submission.ticketNo,
            quantity_bbl: submission.quantityBbl,
            disposal_ticket_no: submission.disposalTicketNo,
            ...(submission.detail !== undefined
              ? { field_ticket_detail: toWireDetail(submission.detail) }
              : {}),
          }),
        },
        options?.signal,
      );
    } catch (error) {
      return { outcome: 'transient', reason: 'network', detail: String(error) };
    }

    const body = await response.json().then(
      (b) => b,
      () => undefined, // a non-JSON body never crashes the mapping; status drives the outcome
    );
    const rec = isRecord(body) ? body : {};
    const code = optionalString(rec.rejection_code) ?? optionalString(rec.reason_code);
    const detail = optionalString(rec.detail);

    if (response.ok) {
      if (rec.accepted === true) {
        const duplicate = rec.duplicate === true || code === 'duplicate';
        // Tolerant id read (spec: accept both): modern ticket_id, legacy field_ticket_id.
        const ticketId = optionalString(rec.ticket_id) ?? optionalString(rec.field_ticket_id);
        // The real Hub returns 201 + snapshot_drift:true when it commits a ticket whose snapshot
        // had drifted. The work is durable, but the drift must be surfaced for office review —
        // never swallowed. (Verified live against opshub /sync/submit.)
        const snapshotDrift = rec.snapshot_drift === true;
        return {
          outcome: 'accepted',
          duplicate,
          ...(snapshotDrift ? { snapshotDrift: true } : {}),
          ...(ticketId !== undefined ? { ticketId } : {}),
        };
      }
      if (rec.snapshot_drift === true) {
        return {
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: response.status,
          rejectionCode: code ?? 'snapshot_drift',
          ...(detail !== undefined ? { detail } : {}),
        };
      }
      // Compatibility only: older Hub builds returned `{ field_ticket_id, status, duplicate,
      // snapshot_drift }` WITHOUT an `accepted` field at all. The legacy read applies ONLY when
      // `accepted` is absent — a present `accepted: false` (or garbage) is Hub explicitly not
      // accepting, and must never be promoted to success by the compat path. Also require a
      // success-like status and no snapshot drift so arbitrary 2xx bodies stay transient.
      const legacyTicketId = optionalString(rec.field_ticket_id);
      if (
        !('accepted' in rec) &&
        legacyTicketId !== undefined &&
        isLegacyAcceptedStatus(rec.status) &&
        rec.snapshot_drift !== true
      ) {
        return {
          outcome: 'accepted',
          duplicate: rec.duplicate === true || code === 'duplicate',
          ticketId: legacyTicketId,
        };
      }
      // 2xx without an explicit accept: do NOT mark work durable on a guess.
      return {
        outcome: 'transient',
        reason: 'malformed-response',
        httpStatus: response.status,
        detail: '2xx response without accepted:true',
      };
    }

    switch (response.status) {
      case 401:
        return { outcome: 'auth-failed', httpStatus: 401 };
      case 403:
        // e.g. not clocked in, SR not assigned to this driver. User-visible, retryable after acting.
        return {
          outcome: 'rejected',
          kind: 'blocked',
          httpStatus: 403,
          rejectionCode: code ?? 'forbidden',
          ...(detail !== undefined ? { detail } : {}),
        };
      case 409:
        // Real Hub: the forced-workflow guard rejected this — the driver is NOT clocked in, or a
        // Hub-required step (pre-trip DVIR / JHA) is missing for this SR (opshub
        // workflow.WorkflowError). Retryable after the user acts (clock in / complete the step).
        // NOT an idempotency conflict. Body carries only `detail`; preserve Hub's verbatim reason.
        return {
          outcome: 'rejected',
          kind: 'blocked',
          httpStatus: 409,
          rejectionCode: code ?? 'workflow_blocked',
          ...(detail !== undefined ? { detail } : {}),
        };
      // 412/422 are DEFENSIVE: the live V1 /sync/submit returns only 201/403/409 (verified against
      // opshub). These arms stay as a safety net for any future contract that does surface
      // drift/idempotency as a hard status, mapping both to needs-review with an informative code.
      case 412:
        return {
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: 412,
          rejectionCode: code ?? 'stale_version',
          ...(detail !== undefined ? { detail } : {}),
        };
      case 422:
        return {
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: 422,
          rejectionCode: code ?? 'idempotency_mismatch',
          ...(detail !== undefined ? { detail } : {}),
        };
      default:
        if (response.status === 429 || response.status >= 500) {
          return {
            outcome: 'transient',
            reason: 'server',
            httpStatus: response.status,
            ...(detail !== undefined ? { detail } : {}),
          };
        }
        // Any other 4xx: an unanticipated contract disagreement — surface for review with the
        // status preserved rather than inventing a retry loop or dropping the reason.
        return {
          outcome: 'rejected',
          kind: 'needs-review',
          httpStatus: response.status,
          rejectionCode: code ?? `http_${response.status}`,
          ...(detail !== undefined ? { detail } : {}),
        };
    }
  }
}
