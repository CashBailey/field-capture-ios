/**
 * Conflict-resolution contract (ADR 004). Conflict resolution lives in exactly one place — Hub —
 * and the phone never auto-merges. This module names the machine-readable outcomes and maps each
 * Hub `CommandResult` to the local follow-up the phone must take.
 *
 * The governing rules (report 03):
 * - accepted     → commit locally, record the change token.
 * - rejected     → mark the local draft conflicted, pull a fresh snapshot, let the user re-apply or
 *                  abandon. NEVER silently merge or overwrite.
 * - needs-review → preserve the work as evidence, freeze the record, flag for manual review. The
 *                  phone never "wins" authority retroactively, but evidence is never discarded
 *                  (cross-cutting invariant #2).
 */
import type { ChangeToken, CommandResult } from "./types";

/** Machine-readable rejection codes Hub returns (report 03 — race/lock/stale containment). */
export const REJECTION_CODES = [
  "missing_precondition", // 428: a mutable edit arrived with no base_version / If-Match
  "stale_version", // 412: base_version is behind the authoritative row
  "locked_sr", // edit attempted on an SR locked by an accepted work-start
  "assignment_changed", // owner/assistant changed before this edit committed
  "revoked_actor", // actor was revoked/inactive by validation time
  "duplicate", // idempotency-key replay of an already-committed op
] as const;
export type RejectionCode = (typeof REJECTION_CODES)[number];

/** Cases that must escalate to manual review rather than auto-resolve (report 03). */
export const REVIEW_TRIGGERS = [
  "offline-work-start-after-reassignment",
  "competing-work-start-evidence",
  "signature-from-revoked-actor",
  "stale-finalization",
  "dependency-never-committed",
] as const;
export type ReviewTrigger = (typeof REVIEW_TRIGGERS)[number];

export function isRejectionCode(code: string): code is RejectionCode {
  return (REJECTION_CODES as readonly string[]).includes(code);
}

/**
 * The local follow-up for a Hub outcome. `mark-conflicted` always pulls a fresh snapshot (the phone
 * has no authority to resolve). `preserve-evidence-and-flag` freezes the record but keeps the work.
 */
export type LocalSyncAction =
  | { action: "commit"; token: ChangeToken }
  | { action: "mark-conflicted"; rejectionCode: string; pullSnapshot: true }
  | { action: "preserve-evidence-and-flag"; reviewReason: string; freeze: true };

export function localActionFor<T>(result: CommandResult<T>): LocalSyncAction {
  switch (result.outcome) {
    case "accepted":
      return { action: "commit", token: result.token };
    case "rejected":
      return { action: "mark-conflicted", rejectionCode: result.rejectionCode, pullSnapshot: true };
    case "needs-review":
      return {
        action: "preserve-evidence-and-flag",
        reviewReason: result.reviewReason,
        freeze: true,
      };
    default: {
      // Defense-in-depth (cross-cutting #2): a future wire-deserialized outcome must fail LOUD,
      // never return undefined and let the caller drop a real conflict on the floor.
      const _exhaustive: never = result;
      void _exhaustive;
      throw new Error(`unknown command outcome: ${(result as { outcome: string }).outcome}`);
    }
  }
}
