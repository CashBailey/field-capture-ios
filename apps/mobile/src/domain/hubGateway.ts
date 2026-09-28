/**
 * Mobile-facing Ops Hub gateway contract (first real integration slice).
 *
 * Pure types + interfaces only — NO HTTP here. `adapters/sync/OpsHubV1Client` implements these
 * over the Hub v1 routes (`/api/v1/sync/session-status`, `/api/v1/sync/assignments`,
 * `/api/v1/sync/submit`); the domain services depend only on these interfaces so they stay
 * hardware- and network-free in tests.
 *
 * This slice is deliberately NOT the full ADR 004 envelope protocol (`/sync/commands`,
 * `/sync/changes`, tus uploads) — that engine remains deferred and `SyncTransport` keeps its
 * placeholder. See docs/integration/ops-triad-contract.md.
 */

import type { fieldwork } from '@fieldcapture/contracts';

import type { FieldTicketDetail } from './fieldTicketDetail';

// ---- errors (typed, so domain code can classify without string matching) ----

/** The request never reached Hub (offline, DNS, timeout). Retryable; work stays local. */
export class HubNetworkError extends Error {
  readonly cause?: unknown;

  constructor(message: string, options?: { cause?: unknown }) {
    super(message);
    this.name = 'HubNetworkError';
    this.cause = options?.cause;
  }
}

/** Hub rejected our credentials (401/403 on a read). Visible; never silently ignored. */
export class HubAuthError extends Error {
  readonly httpStatus: number;
  constructor(message: string, httpStatus: number) {
    super(message);
    this.name = 'HubAuthError';
    this.httpStatus = httpStatus;
  }
}

/** Hub answered, but not in the agreed shape (5xx, non-JSON, missing required fields). */
export class HubResponseError extends Error {
  readonly httpStatus?: number;
  constructor(message: string, httpStatus?: number) {
    super(message);
    this.name = 'HubResponseError';
    this.httpStatus = httpStatus;
  }
}

// ---- session status (TimeClock clock-in, via Hub — the authority) ----

/** Hub's answer to "is the logged-in driver clocked in?" (GET /api/v1/sync/session-status). */
export interface HubSessionStatus {
  clockedIn: boolean;
  /**
   * ISO 8601, or null when not clocked in / not reported. The real Hub sends this as both
   * `clocked_in_since` and a `since` alias (opshub `SessionStatusOut`); we read either.
   */
  clockedInSince: string | null;
  /** e.g. "timeclock" — which system produced the open punch. */
  source: string | null;
  employeeId: string | null;
  assignmentsAvailable: boolean;
  /**
   * The Hub's authoritative server time (ISO 8601, `server_time`), used for clock-skew handling
   * and to seed the offline-policy window. Present only when the Hub reports it.
   */
  serverTime?: string;
}

/**
 * Per-request options. `signal` cancels the underlying network work (timeout or user action) —
 * cancellation NEVER cancels the work item itself: local evidence stays queued and retryable.
 */
export interface HubRequestOptions {
  signal?: AbortSignal;
}

export interface SessionStatusSource {
  getSessionStatus(options?: HubRequestOptions): Promise<HubSessionStatus>;
}

// ---- assignments (active SRs for the logged-in driver, with frozen snapshots) ----

export interface AssignmentNamedRef {
  id?: string;
  name: string;
}

export interface AssignmentWell extends AssignmentNamedRef {
  leaseId?: string;
}

export type AssignmentDisposalSite = AssignmentNamedRef;

/** Single source of truth lives in the contracts package (the Hub-shaped requirements). */
export type AssignmentWorkflowRequirements = fieldwork.WorkflowRequirements;

/** The Service Request lifecycle states (opshub `dispatch/constants.py ServiceRequestStatus`). */
export type AssignmentStatus =
  | 'requested'
  | 'authorized'
  | 'assigned'
  | 'in_progress'
  | 'completed'
  | 'closed'
  | 'on_hold'
  | 'cancelled';

export interface AssignmentGpsPoint {
  lat: number;
  lon: number;
}

export interface AssignmentWellCoordinate extends AssignmentGpsPoint {
  wellId?: string;
}

/**
 * Validation-only well coordinates (Hub `coordinates`). Used for Phase-7 geofence hints, NOT for
 * navigation, routing, or map rendering — Field Capture is field capture, not FieldNav.
 */
export interface AssignmentCoordinates {
  primary?: AssignmentGpsPoint;
  wells: AssignmentWellCoordinate[];
}

/** Hub `geofence_hints`: how close to the well a location-validation check should expect to be. */
export interface AssignmentGeofenceHints {
  radiusM?: number;
  required: boolean;
  source?: string;
}

export interface AssignmentDetails {
  /** Human-facing SR number (Hub `request_no`, e.g. "2026-000001"). */
  requestNo?: string;
  /** SR lifecycle status; drives the inbox Active/On hold filters. */
  status?: AssignmentStatus;
  customer?: AssignmentNamedRef;
  lease?: AssignmentNamedRef;
  wells?: AssignmentWell[];
  material?: string;
  disposalSite?: AssignmentDisposalSite;
  vehicle?: AssignmentNamedRef;
  trailer?: AssignmentNamedRef;
  /** Hub sends `job_type` as an object `{id,name}` (opshub `_entity_ref`), not a bare string. */
  jobType?: AssignmentNamedRef;
  coordinates?: AssignmentCoordinates;
  geofenceHints?: AssignmentGeofenceHints;
  workflowRequirements?: AssignmentWorkflowRequirements;
}

/** One assigned Service Request: a frozen snapshot plus the hash Hub uses to detect drift. */
export interface HubAssignment {
  serviceRequestId: string;
  /** Hub-computed hash of the frozen snapshot; echoed back on submit for drift detection. */
  snapshotHash: string;
  /** The frozen SR snapshot as Hub sent it. Opaque to this slice; the form slices type it later. */
  snapshot: unknown;
  /**
   * Hub's latest authoritative SR/assignment version, used only for display/drift diagnostics.
   * The real Hub sends this as a STRING equal to `snapshot_hash` (opshub `sync/router.py`),
   * never a numeric counter.
   */
  latestServerVersion?: string;
  /** Normalized rich assignment metadata for UI and workflow gating. */
  details?: AssignmentDetails;
}

export interface AssignmentSource {
  getAssignments(options?: HubRequestOptions): Promise<HubAssignment[]>;
}

// ---- minimal field-ticket submit ----

/** The minimal field-ticket payload Hub accepts in this slice (POST /api/v1/sync/submit). */
export interface HubFieldTicketSubmission {
  /** `gtr:<device_instance_id>:<local_seq>:<op_uuid>` — built with the contracts helper. */
  idempotencyKey: string;
  serviceRequestId: string;
  /** The assignment's snapshot hash, echoed back so Hub can flag drift (412-style). */
  snapshotHash: string;
  ticketNo: string;
  quantityBbl: number;
  disposalTicketNo: string;
  /**
   * Full paper-ticket detail (gauges, times, rig #, line items). Additive — the Hub currently
   * ignores unknown submit fields (verified 201); it is sent as `field_ticket_detail` on the wire
   * and persisted once the Hub adds the column. The contract scalars above are unaffected.
   */
  detail?: FieldTicketDetail;
}

/**
 * Every possible Hub answer to a submit, as data (never thrown): the caller MUST handle each arm,
 * and only `accepted` may ever mark local work durable (cross-cutting invariant #2).
 *
 * - accepted     → Hub committed it (duplicate=true means an idempotent replay of an earlier
 *                  accept — equally durable).
 * - rejected     → Hub said no. kind "blocked" (403/409-style: not clocked in, original still
 *                  in progress) is retryable after the user acts; kind "needs-review"
 *                  (412/422-style: snapshot drift, idempotency mismatch) freezes the work for
 *                  manual review. rejectionCode/detail preserve Hub's reason verbatim.
 * - auth-failed  → 401; re-auth then retry. Work stays local.
 * - transient    → network failure, 5xx/429, or a malformed 2xx body. Retry later; never durable.
 */
export type HubSubmitOutcome =
  | {
      outcome: 'accepted';
      duplicate: boolean;
      /**
       * Hub committed the ticket BUT flagged that the snapshot we submitted against had drifted
       * (real Hub returns 201 with `snapshot_drift: true`). The work is durable; this is a
       * review signal that must NOT be swallowed. Present only when drift occurred.
       */
      snapshotDrift?: boolean;
      ticketId?: string;
    }
  | {
      outcome: 'rejected';
      kind: 'blocked' | 'needs-review';
      httpStatus: number;
      rejectionCode: string;
      detail?: string;
    }
  | { outcome: 'auth-failed'; httpStatus: number }
  | {
      outcome: 'transient';
      reason: 'network' | 'server' | 'malformed-response';
      httpStatus?: number;
      detail?: string;
    };

export interface FieldTicketSubmitter {
  submitFieldTicket(
    submission: HubFieldTicketSubmission,
    options?: HubRequestOptions,
  ): Promise<HubSubmitOutcome>;
}

// ---- store durability (honesty about what survives a restart) ----

/**
 * Every local store must declare what it actually guarantees:
 *  - 'volatile-memory'    — in-memory test seam; lost on restart. Never present its contents as
 *                           "saved on the device".
 *  - 'durable-plain'      — survives restart, NOT encrypted at rest (e.g. a native SQLite build
 *                           without SQLCipher). Honest fallback; production builds use SQLCipher.
 *  - 'durable-encrypted'  — survives restart, encrypted at rest (SQLCipher; key in the device
 *                           keychain). The database layer detects which one it really got
 *                           (`PRAGMA cipher_version`) — implementations must not claim
 *                           encryption they cannot verify.
 */
export type StoreDurability = 'volatile-memory' | 'durable-plain' | 'durable-encrypted';
