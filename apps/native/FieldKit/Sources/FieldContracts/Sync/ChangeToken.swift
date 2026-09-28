// Port of sync/change-token.ts — Change-token frontier logic (ADR 004). The down-sync frontier
// <authority_epoch, commit_seq> is server-issued and monotonic: the server defines order, never
// client timestamps. This module is the pure guard that the local frontier only ever moves
// forward.
//
// Within an epoch, `commit_seq` is strictly increasing, so the frontier must never regress. An
// epoch increment is the future cloud/authority cutover (report 03: "one writer per authority
// epoch"); a higher epoch always wins and its `commit_seq` restarts, so a *lower* commit_seq under
// a *higher* epoch is legitimate.

public struct ChangeTokenError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// True if `candidate` is strictly newer than `current`.
public func isTokenNewer(_ candidate: ChangeToken, _ current: ChangeToken) -> Bool {
    compareChangeTokens(candidate, current) > 0
}

/// The newer of two tokens (ties return `a`).
public func maxToken(_ a: ChangeToken, _ b: ChangeToken) -> ChangeToken {
    compareChangeTokens(b, a) > 0 ? b : a
}

/**
 * Advance the local down-sync frontier to `next`, enforcing monotonicity. Returns the new frontier.
 * - `next.authorityEpoch > current` → accept (authority cutover; commit_seq frontier restarts).
 * - same epoch, `next.commitSeq >= current` → accept (equal is a no-op; the server may resend).
 * - same epoch, `next.commitSeq <  current` → THROW (frontier regression within an epoch is a bug).
 * - `next.authorityEpoch < current`        → THROW (stale authority; epoch must never go backward).
 *
 * ponytail: the TS guards both tokens with `Number.isInteger` first (JS numbers can be NaN or
 * fractional). `ChangeToken`'s fields are Swift `Int`, which is always integral, so that guard —
 * and the corresponding "NaN or non-integer token" test case — is unreachable here and dropped.
 */
public func advanceFrontier(_ current: ChangeToken, _ next: ChangeToken) throws -> ChangeToken {
    guard current.authorityEpoch >= 0, next.authorityEpoch >= 0 else {
        throw ChangeTokenError("authorityEpoch must be a non-negative integer")
    }
    guard current.commitSeq >= 0, next.commitSeq >= 0 else {
        throw ChangeTokenError("commitSeq must be a non-negative integer")
    }
    guard next.authorityEpoch >= current.authorityEpoch else {
        throw ChangeTokenError("authority epoch regressed: \(next.authorityEpoch) < \(current.authorityEpoch)")
    }
    guard !(next.authorityEpoch == current.authorityEpoch && next.commitSeq < current.commitSeq) else {
        throw ChangeTokenError(
            "commit_seq regressed within epoch \(current.authorityEpoch): \(next.commitSeq) < \(current.commitSeq)"
        )
    }
    return next
}
