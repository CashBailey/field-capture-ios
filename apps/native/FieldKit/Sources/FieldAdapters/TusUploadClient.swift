// Port of adapters/sync/TusUploadClient.ts — Tus-style resumable upload HTTP client (ADR 004).
// Talks to the per-session `upload_url` Hub returned from `POST /api/v1/sync/uploads`:
//
//   HEAD  <upload_url>             → current durable offset (`Upload-Offset`), and the
//                                    server-computed `Upload-Sha256` once the upload completed
//   PATCH <upload_url> + chunk     → 204 with the new `Upload-Offset`; the final PATCH also
//                                    carries `Upload-Sha256`
//
// Protocol discipline:
//  - Bearer-bearing HEAD/PATCH requests are pinned to the configured Hub origin; cleartext HTTP
//    remains limited to the documented local-development hosts.
//  - The SERVER's offset is the truth on resume (`reconcileOffset` at the engine, FieldContracts).
//  - A 404/410 on the session means it expired server-side — `TusSessionGoneError`; the engine
//    restarts from the durable local copy (the bytes were never purged).
//  - A 409 offset conflict is NOT an error outcome: the engine re-probes and resumes.
//  - Hash verification is the ENGINE's job (`verifyUploadHash`, FieldContracts); this client only
//    transports the server-computed hash verbatim.
import Foundation
import FieldDomain

/// Request init a tus HEAD/PATCH call builds — mirrors the TS `TusFetchInit`.
public struct TusFetchInit: Sendable {
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Minimal response surface for tus calls — headers matter here, bodies do not. Mirrors the TS
/// `TusHttpResponse`.
public struct TusHttpResponse: Sendable {
    public var status: Int
    private let lowercasedHeaders: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.lowercasedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }

    /// Header lookup, case-insensitive on the name.
    public func header(_ name: String) -> String? {
        lowercasedHeaders[name.lowercased()]
    }
}

/// The injectable tus transport seam — mirrors the TS `TusFetch`.
public typealias TusFetch = @Sendable (String, TusFetchInit) async throws -> TusHttpResponse

/// The upload session no longer exists on Hub (expired/garbage-collected). Restart locally.
public struct TusSessionGoneError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// The server answered outside the tus contract (unexpected status / missing offset header).
public struct TusProtocolError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let httpStatus: Int?
    public var description: String { message }
    public init(_ message: String, httpStatus: Int? = nil) {
        self.message = message
        self.httpStatus = httpStatus
    }
}

/// A PATCH landed at the wrong offset — the Hub's durable offset differs from where we wrote
/// (opshub `sync/protocol.py`: 409 with `Upload-Offset` and NO `Upload-Sha256`). RESUMABLE: the
/// engine re-probes (HEAD) and continues from the server's true offset. Carries that offset.
public struct TusOffsetConflictError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let serverOffset: Int?
    public var description: String { message }
    public init(_ message: String, serverOffset: Int? = nil) {
        self.message = message
        self.serverOffset = serverOffset
    }
}

/// The Hub received the whole file but its bytes hash to something DIFFERENT than the declared
/// sha256 (opshub `sync/protocol.py`: 409 WITH `Upload-Sha256`). FATAL: re-sending the same
/// bytes can never fix it — the engine must restart the blob from the durable local copy. Carries
/// the server-computed digest.
public struct TusHashMismatchError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let serverSha256: String?
    public var description: String { message }
    public init(_ message: String, serverSha256: String? = nil) {
        self.message = message
        self.serverSha256 = serverSha256
    }
}

/// Raised when credentials or the trusted Hub origin are missing or invalid.
public struct TusUploadClientConfigError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

private struct TusURLValidationError: Error {
    let message: String
}

/// A bearer may only follow the Hub onto its own origin. Cleartext is reserved for the same local
/// development hosts accepted by the native runtime configuration.
private struct TusHubOrigin: Equatable, Sendable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    init(_ rawUrl: String) throws {
        guard rawUrl == rawUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            let components = URLComponents(string: rawUrl),
            components.url != nil,
            let rawScheme = components.scheme,
            let rawHost = components.host,
            components.user == nil,
            components.password == nil
        else {
            throw TusURLValidationError(message: "expected an absolute HTTP(S) URL without credentials")
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw TusURLValidationError(message: "unsupported URL scheme \(rawScheme)")
        }

        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty else {
            throw TusURLValidationError(message: "URL host is empty")
        }
        guard scheme == "https" || Self.isLocalDevelopmentHost(host) else {
            throw TusURLValidationError(message: "cleartext HTTP is allowed only for local development hosts")
        }

        self.scheme = scheme
        self.host = host
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
    }

    var description: String { "\(scheme)://\(host):\(port)" }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                part.count == 1 || part.first != "0",
                part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let value = Int(part),
                (0...255).contains(value)
            else {
                return false
            }
            octets.append(value)
        }

        return octets[0] == 127
            || octets[0] == 10
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}

/// The server's durable view of a session: bytes held, and the whole-file hash once complete.
public struct TusProbeResult: Equatable, Sendable {
    public var offset: Int
    public var sha256: String?
    public init(offset: Int, sha256: String? = nil) {
        self.offset = offset
        self.sha256 = sha256
    }
}

public struct TusPatchResult: Equatable, Sendable {
    public var offset: Int
    /// Present on the final PATCH (server verified the whole file).
    public var sha256: String?
    public init(offset: Int, sha256: String? = nil) {
        self.offset = offset
        self.sha256 = sha256
    }
}

private func parseOffset(_ response: TusHttpResponse, _ what: String) throws -> Int {
    guard let raw = response.header("Upload-Offset"), let offset = Int(raw), offset >= 0 else {
        throw TusProtocolError(
            "\(what) returned no usable Upload-Offset (got \(response.header("Upload-Offset") ?? "undefined"))",
            httpStatus: response.status)
    }
    return offset
}

public final class TusUploadClient: Sendable {
    private let sessionToken: String?
    /// Resolve a FRESH bearer per request (reuse `AppController.getSyncSessionToken`'s
    /// single-flight refresh). A multi-chunk upload can outlive a token, so without this a PATCH
    /// would 401 on a token that rotated mid-transfer. Falls back to the static `sessionToken`
    /// when absent.
    private let tokenProvider: HubTokenProvider?
    private let fetchFn: TusFetch
    private let timeoutMs: Int
    private let trustedHubOrigin: TusHubOrigin?

    /// `hubBaseUrl` pins bearer-bearing requests to the configured Hub origin. It remains optional
    /// for source compatibility, but `probe` and `uploadChunk` fail closed when it is absent.
    public init(
        sessionToken: String? = nil,
        tokenProvider: HubTokenProvider? = nil,
        fetchFn: TusFetch? = nil,
        timeoutMs: Int = 60_000,  // chunk uploads legitimately take longer than JSON calls
        hubBaseUrl: String? = nil
    ) throws {
        guard tokenProvider != nil || !(sessionToken ?? "").isEmpty else {
            throw TusUploadClientConfigError("TusUploadClient requires a tokenProvider or a non-empty sessionToken")
        }
        self.sessionToken = sessionToken
        self.tokenProvider = tokenProvider
        self.fetchFn = fetchFn ?? createTusFetch()
        self.timeoutMs = timeoutMs
        if let hubBaseUrl {
            do {
                self.trustedHubOrigin = try TusHubOrigin(hubBaseUrl)
            } catch let error as TusURLValidationError {
                throw TusUploadClientConfigError("invalid Hub base URL: \(error.message)")
            }
        } else {
            // Keep the initializer source-compatible, but fail closed before resolving or sending
            // a bearer. Production wiring always supplies the configured Hub URL.
            self.trustedHubOrigin = nil
        }
    }

    private func validateUploadUrl(_ uploadUrl: String) throws {
        guard let trustedHubOrigin else {
            throw TusUploadClientConfigError(
                "TusUploadClient requires hubBaseUrl before an authenticated upload request")
        }

        let uploadOrigin: TusHubOrigin
        do {
            uploadOrigin = try TusHubOrigin(uploadUrl)
        } catch let error as TusURLValidationError {
            throw TusProtocolError("refusing untrusted upload URL: \(error.message)")
        }
        guard uploadOrigin == trustedHubOrigin else {
            throw TusProtocolError(
                "refusing cross-origin upload URL (expected \(trustedHubOrigin), got \(uploadOrigin))")
        }
    }

    private func resolveToken() async throws -> String {
        if let tokenProvider { return try await tokenProvider() }
        return sessionToken ?? ""
    }

    private func headers(_ token: String, _ extra: [String: String] = [:]) -> [String: String] {
        var h = ["Authorization": "Bearer \(token)", "Tus-Resumable": "1.0.0"]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// The server's current durable offset for this session (and hash, once complete).
    public func probe(_ uploadUrl: String) async throws -> TusProbeResult {
        try validateUploadUrl(uploadUrl)
        let token = try await resolveToken()
        let response = try await withTimeout(timeoutMs) {
            try await self.fetchFn(uploadUrl, TusFetchInit(method: "HEAD", headers: self.headers(token)))
        }
        if response.status == 404 || response.status == 410 {
            throw TusSessionGoneError("upload session is gone (\(response.status)): \(uploadUrl)")
        }
        if response.status == 401 || response.status == 403 {
            // Auth, not a tus-protocol fault: surface HubAuthError so the engine flags
            // authRequired and the upload driver PAUSES (consistent with the /sync/commands +
            // openUploadSession legs).
            throw HubAuthError("HEAD \(uploadUrl) auth rejected (\(response.status))", httpStatus: response.status)
        }
        guard response.status == 200 || response.status == 204 else {
            throw TusProtocolError("HEAD \(uploadUrl) returned \(response.status)", httpStatus: response.status)
        }
        return TusProbeResult(offset: try parseOffset(response, "HEAD"), sha256: response.header("Upload-Sha256"))
    }

    /// Upload one chunk at `offset`. Returns the server's new offset (and the whole-file hash on
    /// the final chunk). The Hub returns 409 for TWO distinct reasons, disambiguated by
    /// `Upload-Sha256`:
    ///  - present  → hash mismatch: `TusHashMismatchError` (FATAL — the file is corrupt as declared),
    ///  - absent   → offset conflict: `TusOffsetConflictError` (RESUMABLE — re-probe and continue).
    /// Bytes are never counted as sent without the server's answer.
    public func uploadChunk(_ uploadUrl: String, _ offset: Int, _ chunk: Data) async throws -> TusPatchResult {
        try validateUploadUrl(uploadUrl)
        let token = try await resolveToken()
        let response = try await withTimeout(timeoutMs) {
            try await self.fetchFn(
                uploadUrl,
                TusFetchInit(
                    method: "PATCH",
                    headers: self.headers(
                        token,
                        [
                            "Content-Type": "application/offset+octet-stream",
                            "Upload-Offset": String(offset),
                        ]),
                    body: chunk
                )
            )
        }
        if response.status == 404 || response.status == 410 {
            throw TusSessionGoneError("upload session is gone (\(response.status)): \(uploadUrl)")
        }
        if response.status == 401 || response.status == 403 {
            // Auth, not a tus-protocol fault: HubAuthError so the engine flags authRequired and pauses.
            throw HubAuthError("PATCH \(uploadUrl) auth rejected (\(response.status))", httpStatus: response.status)
        }
        if response.status == 409 {
            if let serverSha256 = response.header("Upload-Sha256") {
                throw TusHashMismatchError(
                    "PATCH \(uploadUrl) reported a hash mismatch (server \(serverSha256))", serverSha256: serverSha256)
            }
            let raw = response.header("Upload-Offset")
            let serverOffset = raw.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
            throw TusOffsetConflictError(
                "PATCH \(uploadUrl) offset conflict; server offset is \(raw ?? "unknown")", serverOffset: serverOffset)
        }
        guard response.status == 204 || response.status == 200 else {
            throw TusProtocolError("PATCH \(uploadUrl) returned \(response.status)", httpStatus: response.status)
        }
        return TusPatchResult(offset: try parseOffset(response, "PATCH"), sha256: response.header("Upload-Sha256"))
    }
}
