// Port of adapters/sync/OpsHubSyncTransport.ts — Real ADR 004 `SyncTransport` over the Ops Hub
// full sync routes:
//
//   POST /api/v1/sync/commands  — submit an idempotent command/event batch
//   GET  /api/v1/sync/changes   — pull authoritative changes after the stored frontier
//   POST /api/v1/sync/uploads   — open (or dedupe) a tus upload session for a blob
//
// This adapter is the V2 protocol and LAYERS BESIDE the V1 `OpsHubV1Client` — the V1 routes stay
// served and the V1 client stays exported as compatibility.
//
// Mapping discipline (cross-cutting invariant #2):
//  - Transport/protocol failures THROW typed errors (`HubNetworkError` / `HubAuthError` /
//    `HubResponseError`); the engine maps a throw to "transient for the whole batch" — items go
//    back to pending with backoff, never silently dropped.
//  - Per-operation outcomes come back as DATA (`CommandResult`) — accepted / rejected /
//    needs-review each carry their reason verbatim.
//  - A malformed response NEVER becomes a guessed outcome: any results entry that does not
//    parse fails the whole call loudly (`HubResponseError`), leaving every item retryable.
//  - A stale `since` token surfaces as `StaleChangeTokenError` (with Hub's suggested reset
//    frontier when present) — never as an empty page that would freeze the frontier.
//
// `Payload`/`Change` are instantiated as `JSONValue` — the opaque-JSON idiom FieldContracts/
// FieldDomain already use for other `unknown`-typed TS payloads (see `SyncOutbox.swift`).
//
// Deviation from the TS: see `OpsHubV1Client.swift`'s header — this adapter takes
// `baseUrl`/`sessionToken` directly rather than a shared `HubRuntimeConfig`, since `FieldAdapters`
// cannot depend on `FieldRuntime` (which owns that type).
import Foundation
import FieldContracts
import FieldDomain

private enum Routes {
    static let commands = "/api/v1/sync/commands"
    static let changes = "/api/v1/sync/changes"
    static let uploads = "/api/v1/sync/uploads"
}

public final class OpsHubSyncTransport: SyncTransport, Sendable {
    public typealias Payload = JSONValue
    public typealias Change = JSONValue

    private let baseUrl: String
    private let sessionToken: String
    private let fetchFn: HubFetch
    private let timeoutMs: Int
    /// Resolve a FRESH bearer per request (reuse `AppController.getSession`'s single-flight
    /// refresh). Without it the transport would send the token bound at construction and keep
    /// sending it stale after a refresh. Falls back to `sessionToken` when absent.
    private let tokenProvider: HubTokenProvider?

    public init(
        baseUrl: String,
        sessionToken: String,
        fetchFn: HubFetch? = nil,
        timeoutMs: Int = 15_000,
        tokenProvider: HubTokenProvider? = nil
    ) {
        self.baseUrl = baseUrl
        self.sessionToken = sessionToken
        self.fetchFn = fetchFn ?? urlSessionHubFetch
        self.timeoutMs = timeoutMs
        self.tokenProvider = tokenProvider
    }

    private func resolveToken() async throws -> String {
        if let tokenProvider { return try await tokenProvider() }
        return sessionToken
    }

    private func headers(_ token: String, _ extra: [String: String] = [:]) -> [String: String] {
        var h = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// Shared request path: network → `HubNetworkError`; 401/403 → `HubAuthError`. Returns the
    /// raw response for route-specific status handling (e.g. 410 stale-token).
    private func request(_ path: String, method: String, body: Data? = nil, contentType: String? = nil) async throws
        -> HubHttpResponse
    {
        let token = try await resolveToken()
        var extraHeaders: [String: String] = [:]
        if let contentType { extraHeaders["Content-Type"] = contentType }
        let response: HubHttpResponse
        do {
            response = try await boundedFetch(
                fetchFn, "\(baseUrl)\(path)",
                HubFetchInit(method: method, headers: headers(token, extraHeaders), body: body),
                timeoutMs: timeoutMs
            )
        } catch {
            throw HubNetworkError("Hub unreachable for \(method) \(path): \(error)", cause: error)
        }
        if response.status == 401 || response.status == 403 {
            throw HubAuthError(
                "Hub auth failed (\(response.status)) for \(method) \(path)", httpStatus: response.status)
        }
        return response
    }

    private func jsonBody(_ response: HubHttpResponse, _ what: String) throws -> Any {
        guard let json = response.json() else {
            throw HubResponseError("Hub returned a non-JSON body for \(what)", httpStatus: response.status)
        }
        return json
    }

    public func submitBatch(_ batch: [OperationEnvelope<JSONValue>]) async throws -> [CommandResult<JSONValue>] {
        if batch.isEmpty { return [] }
        let bodyData = try JSONSerialization.data(withJSONObject: ["operations": batch.map(Self.envelopeToWire)])
        let response = try await request(
            Routes.commands, method: "POST", body: bodyData, contentType: "application/json")
        guard response.ok else {
            throw HubResponseError(
                "Hub returned \(response.status) for POST \(Routes.commands)", httpStatus: response.status)
        }
        let body = try jsonBody(response, "POST \(Routes.commands)")
        guard let rec = body as? [String: Any], let results = rec["results"] as? [Any] else {
            throw HubResponseError("commands response is missing a results list", httpStatus: response.status)
        }
        return try results.enumerated().map { i, r in try Self.parseWireResult(r, i) }
    }

    public func pullChanges(since: ChangeToken) async throws -> ChangePage<JSONValue> {
        let query = "?after_epoch=\(since.authorityEpoch)&after_seq=\(since.commitSeq)"
        let response = try await request("\(Routes.changes)\(query)", method: "GET")
        if response.status == 410 {
            // Hub compacted its change log past our frontier: full/partial resync required. The
            // suggested reset frontier is optional; absent means restart from the zero token.
            let body = response.json()
            var resetTo: ChangeToken?
            if let rec = body as? [String: Any], let rawReset = rec["reset_to"] {
                resetTo = try Self.parseWireToken(rawReset, "stale-token reset_to")
            }
            throw StaleChangeTokenError(
                "change token <\(since.authorityEpoch),\(since.commitSeq)> is stale on Hub", resetTo: resetTo)
        }
        guard response.ok else {
            throw HubResponseError(
                "Hub returned \(response.status) for GET \(Routes.changes)", httpStatus: response.status)
        }
        let body = try jsonBody(response, "GET \(Routes.changes)")
        guard let rec = body as? [String: Any], let changes = rec["changes"] as? [Any] else {
            throw HubResponseError("changes response is missing a changes list", httpStatus: response.status)
        }
        let token = try Self.parseWireToken(rec["token"], "changes token")
        return ChangePage(token: token, changes: changes.map { JSONValue.from($0) })
    }

    public func openUploadSession(_ request: UploadSessionRequest) async throws -> UploadSessionResponse {
        let bodyDict: [String: Any] = [
            "blob_id": request.blobId,
            "sha256": request.sha256,
            "byte_length": request.byteLength,
            "mime_type": request.mimeType,
            "idempotency_key": request.idempotencyKey,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        let response = try await self.request(
            Routes.uploads, method: "POST", body: bodyData, contentType: "application/json")
        guard response.ok else {
            throw HubResponseError(
                "Hub returned \(response.status) for POST \(Routes.uploads)", httpStatus: response.status)
        }
        let body = try jsonBody(response, "POST \(Routes.uploads)")
        let rec = body as? [String: Any]
        if rec?["result"] as? String == "already-present" {
            return .alreadyPresent(blobId: try Self.requireString(rec?["blob_id"], "uploads blob_id"))
        }
        if rec?["result"] as? String == "new-session" {
            return .newSession(
                uploadSessionId: try Self.requireString(rec?["upload_session_id"], "uploads upload_session_id"),
                uploadUrl: try Self.requireString(rec?["upload_url"], "uploads upload_url")
            )
        }
        throw HubResponseError("uploads response has an unknown result shape", httpStatus: response.status)
    }
}

private extension OpsHubSyncTransport {
    static func requireString(_ value: Any?, _ what: String) throws -> String {
        guard let s = value as? String, !s.isEmpty else {
            throw HubResponseError("\(what) is missing or not a string")
        }
        return s
    }

    static func parseWireToken(_ value: Any?, _ what: String) throws -> ChangeToken {
        guard let rec = value as? [String: Any], let epoch = rec["authority_epoch"] as? Int,
            let seq = rec["commit_seq"] as? Int
        else {
            throw HubResponseError("\(what) is not a {authority_epoch, commit_seq} change token")
        }
        return ChangeToken(authorityEpoch: epoch, commitSeq: seq)
    }

    static func envelopeToWire(_ env: OperationEnvelope<JSONValue>) -> [String: Any] {
        var wire: [String: Any] = [
            "op_id": env.opId,
            "kind": env.kind.rawValue,
            "type": env.type,
            "idempotency_key": env.idempotencyKey,
            "local_seq": env.localSeq,
            "depends_on": env.dependsOn,
        ]
        if let precondition = env.precondition {
            wire["precondition"] = ["base_version": precondition.baseVersion]
        }
        wire["payload"] = env.payload.toAny()
        return wire
    }

    static func parseWireResult(_ value: Any, _ index: Int) throws -> CommandResult<JSONValue> {
        guard let rec = value as? [String: Any] else {
            throw HubResponseError("results[\(index)] is not an object")
        }
        let opId = try requireString(rec["op_id"], "results[\(index)].op_id")
        switch rec["outcome"] as? String {
        case "accepted":
            let token = try parseWireToken(rec["token"], "results[\(index)].token")
            return .accepted(opId: opId, token: token)
        case "rejected":
            let rejectionCode = try requireString(rec["rejection_code"], "results[\(index)].rejection_code")
            let detail = (rec["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let latest = rec["latest"].map { JSONValue.from($0) }
            return .rejected(opId: opId, rejectionCode: rejectionCode, detail: detail, latest: latest)
        case "needs-review":
            let reviewReason = try requireString(rec["review_reason"], "results[\(index)].review_reason")
            return .needsReview(opId: opId, reviewReason: reviewReason)
        default:
            // An unknown outcome must fail loud — guessing would either fake a success or
            // silently freeze an item; failing the call keeps the whole batch retryable.
            throw HubResponseError("results[\(index)].outcome is unknown: \(String(describing: rec["outcome"]))")
        }
    }
}

/// Bridges untyped JSON (`JSONSerialization` output) to/from the opaque `JSONValue` tree, mirroring
/// the private helper `FieldDomain/SyncChanges.swift` uses for the same purpose (each is
/// file-scoped, so the duplication across modules is harmless).
private extension JSONValue {
    static func from(_ any: Any?) -> JSONValue {
        guard let any, !(any is NSNull) else { return .null }
        switch any {
        case let v as JSONValue: return v
        case let v as Bool: return .bool(v)
        case let v as String: return .string(v)
        case let v as Int: return .number(Double(v))
        case let v as Double: return .number(v)
        case let v as NSNumber: return .number(v.doubleValue)
        case let v as [Any]: return .array(v.map { JSONValue.from($0) })
        case let v as [String: Any]: return .object(v.mapValues { JSONValue.from($0) })
        default: return .null
        }
    }

    /// Convert back to a `JSONSerialization`-compatible `Any` for wire encoding.
    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        }
    }
}
