/**
 * Minimal field-ticket submit path (first real OpsHub integration slice).
 *
 * Invariants (cross-cutting #2 — never silently lose work, never pretend it is safe):
 *  - Evidence is recorded locally BEFORE the network is touched, keyed by the idempotency key.
 *  - The evidence reaches `accepted` ONLY when Hub accepts (or replays a previous accept).
 *  - Every other outcome preserves the evidence: transient/blocked/auth → back to `pending`
 *    (retryable with the SAME key, so retries can never double-create a ticket on Hub);
 *    needs-review → frozen as evidence for manual resolution.
 *
 * State legality is enforced with the tested contracts state machine (`sync.assertTransition`),
 * and write identity with the contracts envelope + idempotency helpers.
 */
import { sync, SYNC_OP_TYPES } from '@fieldcapture/contracts';

type SyncOpType = (typeof SYNC_OP_TYPES)[number];
const TICKET_SUBMIT_OP: SyncOpType = 'ticket.submit';

import type { FieldTicketDetail } from './fieldTicketDetail';
import type {
  FieldTicketSubmitter,
  HubFieldTicketSubmission,
  HubSubmitOutcome,
  StoreDurability,
} from './hubGateway';

/** What the caller provides; the idempotency key is derived, never hand-rolled. */
export interface FieldTicketInput {
  serviceRequestId: string;
  /** Hash of the assignment snapshot this ticket was captured against (drift detection). */
  snapshotHash: string;
  ticketNo: string;
  quantityBbl: number;
  disposalTicketNo: string;
  /** Stable per-install id + per-device sequence + operation UUID → idempotency key. */
  deviceInstanceId: string;
  localSeq: number;
  opUuid: string;
  /** Full paper-ticket detail (gauges, times, rig #, line items); rides along additively. */
  detail?: FieldTicketDetail;
}

/**
 * Local evidence of a submission attempt — the durable outbox row for the submit path. Wraps a
 * real contracts `OperationEnvelope` (validated by `assertEnvelopeConsistent`) so this record can
 * later migrate into the full ADR 004 outbox without reshaping.
 *
 * Outbox-shape mapping: id / idempotency_key = `envelope.idempotencyKey`, type = `envelope.type`,
 * payload = `envelope.payload`, status = `state` ("retry" ≙ `pending` with `attempts > 0`;
 * "failed" ≙ terminal `rejected` / `needs-review`), last_error = `lastDetail` /
 * `lastTransientReason`, created_at / updated_at below.
 */
export interface TicketEvidence {
  envelope: sync.OperationEnvelope<HubFieldTicketSubmission>;
  state: sync.OutboxItemState;
  attempts: number;
  /** ISO 8601 — when this evidence was first recorded / last changed. */
  createdAt: string;
  updatedAt: string;
  /** Hub's most recent machine-readable rejection code, preserved verbatim. */
  lastRejectionCode?: string;
  /** Hub's human-readable detail for the most recent failure, preserved verbatim. */
  lastDetail?: string;
  /** HTTP status of the most recent non-accepted Hub answer. */
  lastHttpStatus?: number;
  /** When the most recent Hub outcome landed (ISO 8601). */
  lastOutcomeAt?: string;
  /**
   * 'network' | 'server' | 'malformed-response' (transient), 'auth-failed' (needs re-auth),
   * 'client-error' (the submitter threw locally), or 'restart-interrupted' (boot sweep).
   */
  lastTransientReason?: string;
  /** Epoch ms before which the background retry engine must not redispatch (full-jitter backoff). */
  nextAttemptAtMs?: number;
}

export interface TicketEvidenceStore {
  readonly durability: StoreDurability;
  save(evidence: TicketEvidence): void;
  get(idempotencyKey: string): TicketEvidence | undefined;
  list(): TicketEvidence[];
}

/**
 * In-memory evidence store. VOLATILE: lost on app restart. TEST SEAM ONLY — production uses
 * `data/SqliteTicketEvidenceStore` (durable, SQLCipher in real builds). Never wire this into
 * the app shell; the UI must not present its contents as saved.
 */
export class VolatileTicketEvidenceStore implements TicketEvidenceStore {
  readonly durability: StoreDurability = 'volatile-memory';
  private byKey = new Map<string, TicketEvidence>();

  save(evidence: TicketEvidence): void {
    this.byKey.set(evidence.envelope.idempotencyKey, evidence);
  }

  get(idempotencyKey: string): TicketEvidence | undefined {
    return this.byKey.get(idempotencyKey);
  }

  list(): TicketEvidence[] {
    return [...this.byKey.values()];
  }
}

/** The user-visible result. Only `accepted` means the work is durable on Hub. */
export type SubmitFieldTicketResult =
  | {
      status: 'accepted';
      duplicate: boolean;
      /** Hub committed the ticket but flagged snapshot drift — surface for office review. */
      snapshotDrift?: boolean;
      idempotencyKey: string;
    }
  | {
      status: 'blocked';
      rejectionCode: string;
      httpStatus: number;
      detail?: string;
      idempotencyKey: string;
    }
  | {
      status: 'needs-review';
      rejectionCode: string;
      httpStatus: number;
      detail?: string;
      idempotencyKey: string;
    }
  | { status: 'pending-retry'; reason: string; idempotencyKey: string }
  | { status: 'auth-required'; idempotencyKey: string }
  /** Refused locally before any evidence or network I/O — fix the input and resubmit. */
  | { status: 'not-submitted'; reason: 'missing-snapshot-hash'; idempotencyKey: string };

/**
 * Rebuild the evidence record for a new Hub outcome. Each outcome REPLACES the previous failure
 * detail (a stale rejection code must not linger once a later attempt failed differently — the
 * retry engine reads `lastRejectionCode` as "user-action-gated") while `createdAt`, the envelope,
 * and the idempotency key never change. `nextAttemptAtMs` is dropped; the retry engine recomputes
 * it after each transient failure.
 */
function withOutcome(
  evidence: TicketEvidence,
  changes: {
    state: sync.OutboxItemState;
    at: string;
    attemptsDelta?: number;
    rejectionCode?: string | undefined;
    detail?: string | undefined;
    httpStatus?: number | undefined;
    transientReason?: string | undefined;
  },
): TicketEvidence {
  return {
    envelope: evidence.envelope,
    state: changes.state,
    attempts: evidence.attempts + (changes.attemptsDelta ?? 0),
    createdAt: evidence.createdAt,
    updatedAt: changes.at,
    lastOutcomeAt: changes.at,
    ...(changes.rejectionCode !== undefined ? { lastRejectionCode: changes.rejectionCode } : {}),
    ...(changes.detail !== undefined ? { lastDetail: changes.detail } : {}),
    ...(changes.httpStatus !== undefined ? { lastHttpStatus: changes.httpStatus } : {}),
    ...(changes.transientReason !== undefined
      ? { lastTransientReason: changes.transientReason }
      : {}),
  };
}

export interface SubmitFieldTicketDeps {
  submitter: FieldTicketSubmitter;
  evidenceStore: TicketEvidenceStore;
  /** Clock for evidence timestamps; injectable for tests. Defaults to the real clock. */
  now?: () => Date;
}

export async function submitFieldTicket(
  deps: SubmitFieldTicketDeps,
  input: FieldTicketInput,
): Promise<SubmitFieldTicketResult> {
  const stamp = () => (deps.now ?? (() => new Date()))().toISOString();
  // Throws IdempotencyKeyError on bad identity inputs — before any evidence or network I/O.
  const idempotencyKey = sync.buildIdempotencyKey(
    input.deviceInstanceId,
    input.localSeq,
    input.opUuid,
  );

  // Never submit without the assignment's snapshot hash — it is the only drift protection
  // (Hub's 412 guard). A blank hash means the assignment was never pulled or the caller lost
  // it; submitting anyway would silently disarm drift detection.
  if (input.snapshotHash.trim() === '') {
    return { status: 'not-submitted', reason: 'missing-snapshot-hash', idempotencyKey };
  }

  let evidence = deps.evidenceStore.get(idempotencyKey);
  if (evidence === undefined) {
    const envelope: sync.OperationEnvelope<HubFieldTicketSubmission> = {
      opId: input.opUuid,
      kind: 'command',
      type: TICKET_SUBMIT_OP,
      idempotencyKey,
      localSeq: input.localSeq,
      dependsOn: [],
      payload: {
        idempotencyKey,
        serviceRequestId: input.serviceRequestId,
        snapshotHash: input.snapshotHash,
        ticketNo: input.ticketNo,
        quantityBbl: input.quantityBbl,
        disposalTicketNo: input.disposalTicketNo,
        ...(input.detail !== undefined ? { detail: input.detail } : {}),
      },
    };
    sync.assertEnvelopeConsistent(envelope);
    const createdAt = stamp();
    evidence = { envelope, state: 'pending', attempts: 0, createdAt, updatedAt: createdAt };
    deps.evidenceStore.save(evidence);
  } else if (evidence.state === 'accepted') {
    // Hub already accepted this operation; replaying locally is safe and adds nothing.
    return { status: 'accepted', duplicate: true, idempotencyKey };
  } else if (evidence.state === 'in-flight') {
    // A submission of this exact operation is already awaiting Hub's answer (e.g. a double-tap).
    // Never race a second network call with the same key — back off; the first call will land
    // the outcome and the evidence is preserved either way.
    return { status: 'pending-retry', reason: 'already-in-flight', idempotencyKey };
  }

  // pending → in-flight (assertTransition throws on a frozen needs-review/rejected record:
  // frozen evidence must go through manual review, never silent resubmission). The in-flight
  // and accepted states were already handled above, so only frozen states can throw here.
  sync.assertTransition(evidence.state, 'in-flight');
  evidence = { ...evidence, state: 'in-flight', updatedAt: stamp() };
  deps.evidenceStore.save(evidence);

  let outcome: HubSubmitOutcome;
  try {
    outcome = await deps.submitter.submitFieldTicket(evidence.envelope.payload);
  } catch (error) {
    // The Hub client never throws for expected conditions, but the submitter seam can still
    // reject (keychain failure resolving the token, a wrapper bug). Without this catch the
    // evidence would be stranded in-flight — deadlocking the double-submit guard until the
    // next restart sweep. Map the throw to the transient arm: pending, retryable, same key.
    sync.assertTransition(evidence.state, 'pending');
    deps.evidenceStore.save(
      withOutcome(evidence, {
        state: 'pending',
        at: stamp(),
        attemptsDelta: 1,
        transientReason: 'client-error',
        detail: String(error),
      }),
    );
    return { status: 'pending-retry', reason: 'client-error', idempotencyKey };
  }

  switch (outcome.outcome) {
    case 'accepted': {
      sync.assertTransition(evidence.state, 'accepted');
      deps.evidenceStore.save(withOutcome(evidence, { state: 'accepted', at: stamp() }));
      return {
        status: 'accepted',
        duplicate: outcome.duplicate,
        ...(outcome.snapshotDrift ? { snapshotDrift: true } : {}),
        idempotencyKey,
      };
    }
    case 'transient': {
      sync.assertTransition(evidence.state, 'pending');
      deps.evidenceStore.save(
        withOutcome(evidence, {
          state: 'pending',
          at: stamp(),
          attemptsDelta: 1,
          transientReason: outcome.reason,
          detail: outcome.detail,
          httpStatus: outcome.httpStatus,
        }),
      );
      return { status: 'pending-retry', reason: outcome.reason, idempotencyKey };
    }
    case 'auth-failed': {
      sync.assertTransition(evidence.state, 'pending');
      deps.evidenceStore.save(
        withOutcome(evidence, {
          state: 'pending',
          at: stamp(),
          attemptsDelta: 1,
          transientReason: 'auth-failed',
          httpStatus: outcome.httpStatus,
        }),
      );
      return { status: 'auth-required', idempotencyKey };
    }
    case 'rejected': {
      if (outcome.kind === 'blocked') {
        // Retryable after the user acts (clock in / wait out the in-progress original). The
        // rejection code on the evidence marks it user-action-gated: the background retry
        // engine must NOT auto-redispatch it (spec: never auto-retry 403/409).
        sync.assertTransition(evidence.state, 'pending');
        deps.evidenceStore.save(
          withOutcome(evidence, {
            state: 'pending',
            at: stamp(),
            attemptsDelta: 1,
            rejectionCode: outcome.rejectionCode,
            detail: outcome.detail,
            httpStatus: outcome.httpStatus,
          }),
        );
        return {
          status: 'blocked',
          rejectionCode: outcome.rejectionCode,
          httpStatus: outcome.httpStatus,
          detail: outcome.detail,
          idempotencyKey,
        };
      }
      // needs-review: freeze the evidence for manual resolution; never auto-resubmit.
      sync.assertTransition(evidence.state, 'needs-review');
      deps.evidenceStore.save(
        withOutcome(evidence, {
          state: 'needs-review',
          at: stamp(),
          rejectionCode: outcome.rejectionCode,
          detail: outcome.detail,
          httpStatus: outcome.httpStatus,
        }),
      );
      return {
        status: 'needs-review',
        rejectionCode: outcome.rejectionCode,
        httpStatus: outcome.httpStatus,
        detail: outcome.detail,
        idempotencyKey,
      };
    }
    default: {
      // Exhaustiveness guard (cross-cutting #2): an unknown wire outcome fails loud rather than
      // silently dropping the Hub result while the evidence sits in-flight.
      const _exhaustive: never = outcome;
      void _exhaustive;
      throw new Error(
        `unknown submit outcome: ${(outcome as { outcome: string }).outcome} for ${idempotencyKey}`,
      );
    }
  }
}
