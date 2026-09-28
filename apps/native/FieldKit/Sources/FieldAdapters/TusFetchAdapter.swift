// Port of adapters/sync/tusFetchAdapter.ts — Adapts a plain fetch-like transport to the `TusFetch`
// seam `TusUploadClient` expects. Without this the client's `header(name)` calls have nothing to
// read and every probe/PATCH throws. The mapping is deliberately tiny: a `FetchLikeResponse`'s
// status + headers become `TusHttpResponse`'s `status`/`header(name)`; the byte body and
// cancellation (Swift structured-concurrency Task cancellation is the native equivalent of the TS
// `AbortSignal`) thread straight through. The bearer/Tus-Resumable headers are added by the
// client, not here.
//
// Built + tested standalone so swapping in the real `URLSession`-backed transport is a one-line
// change, mirroring the TS comment about `wireAppRuntime`.
import Foundation

/// The minimal slice of a `URLSession`-style response this depends on (keeps it test-friendly) —
/// mirrors the TS `FetchLikeResponse`.
public struct FetchLikeResponse: Sendable {
    public var status: Int
    /// Raw header map as the transport returned it (case preserved on the wire; lookup in
    /// `TusHttpResponse.header(_:)` is case-insensitive).
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }
}

/// A `fetch`-like transport seam, one level below `TusFetch` — mirrors the TS `FetchLike`.
public typealias FetchLike = @Sendable (String, TusFetchInit) async throws -> FetchLikeResponse

/// The real `FetchLike`, backed by `URLSession`.
@Sendable public func urlSessionFetchLike(_ url: String, _ requestInit: TusFetchInit) async throws -> FetchLikeResponse
{
    guard let requestUrl = URL(string: url) else { throw URLError(.badURL) }
    var request = URLRequest(url: requestUrl)
    request.httpMethod = requestInit.method
    for (key, value) in requestInit.headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = requestInit.body
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var headerMap: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
        if let k = key as? String, let v = value as? String { headerMap[k] = v }
    }
    return FetchLikeResponse(status: http.statusCode, headers: headerMap)
}

/// Wrap a fetch-like function as a `TusFetch`. Defaults to the real `URLSession`-backed transport.
public func createTusFetch(_ fetchFn: FetchLike? = nil) -> TusFetch {
    let doFetch = fetchFn ?? urlSessionFetchLike
    return { url, requestInit in
        let response = try await doFetch(url, requestInit)
        return TusHttpResponse(status: response.status, headers: response.headers)
    }
}
