/**
 * The phone ↔ Hub sync seam (ADR 004). This is a CONTRACT (interface) only — the foundation ships
 * no engine. A later slice implements it over HTTPS (`/sync/commands`, `/sync/changes`) + tus
 * uploads; until then the app's placeholder refuses to fake a sync rather than silently dropping
 * work (cross-cutting invariant #2). Mirrors the PrinterTransport seam (ADR 003).
 */
import type {
  ChangeToken,
  CommandResult,
  OperationEnvelope,
  UploadSessionRequest,
  UploadSessionResponse,
} from "./types";

export class SyncNotImplementedError extends Error {
  constructor(what: string) {
    super(`${what} is not implemented yet — gated on the Ops Hub sync engine (ADR 004).`);
    this.name = "SyncNotImplementedError";
  }
}

/**
 * Hub no longer holds the change history behind the client's `since` token (e.g. its change log
 * was compacted past the frontier). The client must reset its frontier — to `resetTo` when Hub
 * provides one, otherwise to the zero token — and resync from there. Raised by a real transport's
 * `pullChanges`; never swallowed into an empty page (an empty page would silently freeze the
 * frontier forever).
 */
export class StaleChangeTokenError extends Error {
  /** Hub-suggested frontier to restart from (absent = full resync from the zero token). */
  readonly resetTo?: ChangeToken;
  constructor(message: string, resetTo?: ChangeToken) {
    super(message);
    this.name = "StaleChangeTokenError";
    if (resetTo !== undefined) this.resetTo = resetTo;
  }
}

/** The frontier a device starts from before its first successful pull (full resync origin). */
export const ZERO_CHANGE_TOKEN: ChangeToken = Object.freeze({ authorityEpoch: 0, commitSeq: 0 });

/** A page of authoritative changes pulled from Hub, plus the frontier to persist after applying. */
export interface ChangePage<TChange = unknown> {
  token: ChangeToken;
  changes: TChange[];
}

export interface SyncTransport {
  /** Submit an idempotent command/event batch; Hub returns a per-operation outcome. */
  submitBatch(batch: readonly OperationEnvelope[]): Promise<CommandResult[]>;
  /** Pull authoritative changes strictly after `since` — the server-issued frontier, not clock time. */
  pullChanges(since: ChangeToken): Promise<ChangePage>;
  /** Open (or dedupe by content hash) a tus upload session for a blob. */
  openUploadSession(request: UploadSessionRequest): Promise<UploadSessionResponse>;
}
