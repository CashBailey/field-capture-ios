/**
 * Change-token frontier logic (ADR 004). The down-sync frontier `<authority_epoch, commit_seq>` is
 * server-issued and monotonic: the server defines order, never client timestamps. This module is
 * the pure guard that the local frontier only ever moves forward.
 *
 * Within an epoch, `commit_seq` is strictly increasing, so the frontier must never regress. An
 * epoch increment is the future cloud/authority cutover (report 03: "one writer per authority
 * epoch"); a higher epoch always wins and its `commit_seq` restarts, so a *lower* commit_seq under
 * a *higher* epoch is legitimate.
 */
import type { ChangeToken } from "./types";
import { compareChangeTokens } from "./types";

export class ChangeTokenError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ChangeTokenError";
  }
}

/** True if `candidate` is strictly newer than `current`. */
export function isTokenNewer(candidate: ChangeToken, current: ChangeToken): boolean {
  return compareChangeTokens(candidate, current) > 0;
}

/** The newer of two tokens (ties return `a`). */
export function maxToken(a: ChangeToken, b: ChangeToken): ChangeToken {
  return compareChangeTokens(b, a) > 0 ? b : a;
}

/**
 * Advance the local down-sync frontier to `next`, enforcing monotonicity. Returns the new frontier.
 * - `next.authorityEpoch > current` → accept (authority cutover; commit_seq frontier restarts).
 * - same epoch, `next.commitSeq >= current` → accept (equal is a no-op; the server may resend).
 * - same epoch, `next.commitSeq <  current` → THROW (frontier regression within an epoch is a bug).
 * - `next.authorityEpoch < current`        → THROW (stale authority; epoch must never go backward).
 */
export function advanceFrontier(current: ChangeToken, next: ChangeToken): ChangeToken {
  // Validate before comparing: a NaN/non-integer commitSeq would slip past the `<` regression guard
  // (NaN comparisons are always false) and silently poison the frontier for every later comparison.
  // Fail loud instead — mirrors buildIdempotencyKey's Number.isInteger discipline.
  for (const [label, t] of [
    ["current", current],
    ["next", next],
  ] as const) {
    if (!Number.isInteger(t.authorityEpoch) || t.authorityEpoch < 0) {
      throw new ChangeTokenError(`${label} authorityEpoch must be a non-negative integer`);
    }
    if (!Number.isInteger(t.commitSeq) || t.commitSeq < 0) {
      throw new ChangeTokenError(`${label} commitSeq must be a non-negative integer`);
    }
  }
  if (next.authorityEpoch < current.authorityEpoch) {
    throw new ChangeTokenError(
      `authority epoch regressed: ${next.authorityEpoch} < ${current.authorityEpoch}`,
    );
  }
  if (next.authorityEpoch === current.authorityEpoch && next.commitSeq < current.commitSeq) {
    throw new ChangeTokenError(
      `commit_seq regressed within epoch ${current.authorityEpoch}: ${next.commitSeq} < ${current.commitSeq}`,
    );
  }
  return next;
}
