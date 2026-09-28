// Port of apps/mobile/__tests__/tus-fetch-adapter.test.ts — the fetch→TusFetch adapter.
import XCTest

@testable import FieldAdapters

private final class FakeFetchLike: @unchecked Sendable {
    private let lock = NSLock()
    let status: Int
    let headers: [String: String]
    private(set) var calls: [(url: String, requestInit: TusFetchInit)] = []

    init(_ status: Int, _ headers: [String: String]) {
        self.status = status
        self.headers = headers
    }

    var fetchLike: FetchLike {
        { url, requestInit in
            self.recordCall(url: url, requestInit: requestInit)
            return FetchLikeResponse(status: self.status, headers: self.headers)
        }
    }

    private func recordCall(url: String, requestInit: TusFetchInit) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((url, requestInit))
    }
}

final class TusFetchAdapterTests: XCTestCase {
    func test_mapsStatusAndCaseInsensitiveHeaders() async throws {
        let tusFetch = createTusFetch(FakeFetchLike(200, ["Upload-Offset": "512"]).fetchLike)
        let res = try await tusFetch("http://h/u", TusFetchInit(method: "HEAD", headers: [:]))
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(res.header("upload-offset"), "512")  // case-insensitive
        XCTAssertNil(res.header("Missing"))  // absent → nil
    }

    func test_threadsMethodHeadersBodyThrough() async throws {
        let f = FakeFetchLike(204, ["Upload-Offset": "4"])
        let tusFetch = createTusFetch(f.fetchLike)
        let body = Data([1, 2, 3, 4])
        _ = try await tusFetch(
            "http://h/u",
            TusFetchInit(method: "PATCH", headers: ["Content-Type": "application/offset+octet-stream"], body: body))
        XCTAssertEqual(f.calls[0].requestInit.method, "PATCH")
        XCTAssertEqual(f.calls[0].requestInit.headers["Content-Type"], "application/offset+octet-stream")
        XCTAssertEqual(f.calls[0].requestInit.body, body)
    }

    func test_drivesARealTusUploadClientProbeEndToEnd() async throws {
        let fetchLike = FakeFetchLike(200, ["Upload-Offset": "1024", "Upload-Sha256": "abc"]).fetchLike
        let client = try TusUploadClient(
            sessionToken: "tok", fetchFn: createTusFetch(fetchLike), hubBaseUrl: "https://hub.test")
        let result = try await client.probe("https://hub.test/u")
        XCTAssertEqual(result, TusProbeResult(offset: 1024, sha256: "abc"))
    }
}
