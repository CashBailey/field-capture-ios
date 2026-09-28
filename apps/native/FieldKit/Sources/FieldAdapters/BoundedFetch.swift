// Port of adapters/sync/boundedFetch.ts — Shared wall-clock-bounded HTTP seam used by every
// Hub-facing adapter (OpsHubV1Client, OpsHubSyncTransport, HubAuthApiV1, TusUploadClient).
//
// The TS version races a real `fetch` against a timer and tears the socket down via
// `AbortController` when either fires. Swift has no `AbortSignal` — structured concurrency's Task
// cancellation is the platform-native equivalent: canceling the enclosing `Task` (or losing the
// race to the timeout timer) cancels whichever child task is still in flight, and `URLSession`'s
// async `data(for:)` is itself cancellation-aware (a canceled Task cancels the underlying
// `URLSessionTask`). So there is no separate `signal` parameter here — the caller cancels its own
// Task instead. Cancellation never cancels the WORK ITSELF: callers map the failure to their
// transient arm and local evidence stays queued (cross-cutting invariant #2).
import Foundation

/// Request init every Hub-facing HTTP call builds (method/headers/body) — mirrors the TS
/// `HubFetchInit`.
public struct HubFetchInit: Sendable {
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Minimal response surface every Hub adapter needs — mirrors the TS `HubHttpResponse`
/// (`ok`/`status`/`json()`), letting tests fake the wire with plain values instead of a real
/// `URLSession` round-trip.
public struct HubHttpResponse: Sendable {
    public var status: Int
    public var body: Data
    public var ok: Bool { (200..<300).contains(status) }

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    /// Parse the body as JSON, or nil if it is empty/not valid JSON (mirrors the TS
    /// `.json().catch(() => undefined)` tolerance).
    public func json() -> Any? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }
}

/// The injectable fetch seam every Hub JSON adapter takes (mirrors the TS `HubFetch`) so tests can
/// stub the wire with a plain closure.
public typealias HubFetch = @Sendable (String, HubFetchInit) async throws -> HubHttpResponse

/// Resolve a FRESH bearer per request. Mirrors the repeated inline TS type
/// `() => string | Promise<string>` that `OpsHubSyncTransport`/`TusUploadClient` each declare —
/// named once here since Swift needs a nominal type to share it across those two adapters.
public typealias HubTokenProvider = @Sendable () async throws -> String

/// The default `HubFetch`, backed by real `URLSession`.
@Sendable public func urlSessionHubFetch(_ url: String, _ requestInit: HubFetchInit) async throws -> HubHttpResponse {
    guard let requestUrl = URL(string: url) else { throw URLError(.badURL) }
    var request = URLRequest(url: requestUrl)
    request.httpMethod = requestInit.method
    for (key, value) in requestInit.headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = requestInit.body
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return HubHttpResponse(status: http.statusCode, body: data)
}

/// Thrown when the timeout timer wins the race against the real operation.
public struct BoundedFetchTimeoutError: Error, CustomStringConvertible, Equatable {
    public let timeoutMs: Int
    public var description: String { "request timed out after \(timeoutMs)ms" }
    public init(timeoutMs: Int) { self.timeoutMs = timeoutMs }
}

/// Race `operation` against a `timeoutMs` timer; whichever finishes first wins and the other is
/// canceled. Also refuses to start if the calling Task is already canceled (mirrors the TS
/// `externalSignal?.aborted` pre-dispatch check).
public func withTimeout<T: Sendable>(
    _ timeoutMs: Int,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            throw BoundedFetchTimeoutError(timeoutMs: timeoutMs)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

/// `fetch` with a wall-clock bound that ABORTS the underlying network work (see the file header).
public func boundedFetch(
    _ fetchFn: @escaping HubFetch,
    _ url: String,
    _ requestInit: HubFetchInit,
    timeoutMs: Int
) async throws -> HubHttpResponse {
    try await withTimeout(timeoutMs) { try await fetchFn(url, requestInit) }
}
