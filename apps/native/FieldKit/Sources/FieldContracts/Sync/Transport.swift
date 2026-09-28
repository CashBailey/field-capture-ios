// Port of sync/transport.ts — The phone ↔ Hub sync seam (ADR 004). This is a CONTRACT (interface)
// only — the foundation ships no engine. A later slice implements it over HTTPS
// (`/sync/commands`, `/sync/changes`) + tus uploads; until then the app's placeholder refuses to
// fake a sync rather than silently dropping work (cross-cutting invariant #2). Mirrors the
// PrinterTransport seam (ADR 003).

public struct SyncNotImplementedError: Error, CustomStringConvertible, Equatable {
    public let what: String
    public var description: String {
        "\(what) is not implemented yet — gated on the Ops Hub sync engine (ADR 004)."
    }
    public init(_ what: String) { self.what = what }
}

/**
 * Hub no longer holds the change history behind the client's `since` token (e.g. its change log
 * was compacted past the frontier). The client must reset its frontier — to `resetTo` when Hub
 * provides one, otherwise to the zero token — and resync from there. Raised by a real transport's
 * `pullChanges`; never swallowed into an empty page (an empty page would silently freeze the
 * frontier forever).
 */
public struct StaleChangeTokenError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// Hub-suggested frontier to restart from (absent = full resync from the zero token).
    public let resetTo: ChangeToken?
    public var description: String { message }
    public init(_ message: String, resetTo: ChangeToken? = nil) {
        self.message = message
        self.resetTo = resetTo
    }
}

/// The frontier a device starts from before its first successful pull (full resync origin).
public let ZERO_CHANGE_TOKEN = ChangeToken(authorityEpoch: 0, commitSeq: 0)

/// A page of authoritative changes pulled from Hub, plus the frontier to persist after applying.
public struct ChangePage<Change: Sendable>: Sendable {
    public var token: ChangeToken
    public var changes: [Change]

    public init(token: ChangeToken, changes: [Change]) {
        self.token = token
        self.changes = changes
    }
}
extension ChangePage: Equatable where Change: Equatable {}

public protocol SyncTransport: Sendable {
    associatedtype Payload: Sendable
    associatedtype Change: Sendable

    /// Submit an idempotent command/event batch; Hub returns a per-operation outcome.
    func submitBatch(_ batch: [OperationEnvelope<Payload>]) async throws -> [CommandResult<Payload>]
    /// Pull authoritative changes strictly after `since` — the server-issued frontier, not clock time.
    func pullChanges(since: ChangeToken) async throws -> ChangePage<Change>
    /// Open (or dedupe by content hash) a tus upload session for a blob.
    func openUploadSession(_ request: UploadSessionRequest) async throws -> UploadSessionResponse
}
