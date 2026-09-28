import FieldDomain
// Port of apps/mobile/__tests__/tus-upload-client.test.ts — `TusUploadClient` wire behaviour: HEAD
// probes the durable offset, PATCH advances it, session loss and protocol violations throw typed
// errors, and every call is bounded.
import XCTest

@testable import FieldAdapters

private let HUB_BASE_URL = "https://hub.test"
private let URL_STR = "\(HUB_BASE_URL)/api/v1/sync/uploads/sess-1"

private func response(_ status: Int, _ headers: [String: String] = [:]) -> TusHttpResponse {
    TusHttpResponse(status: status, headers: headers)
}

private final class FakeTusFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [TusHttpResponse]
    private(set) var calls: [(url: String, requestInit: TusFetchInit)] = []

    init(_ responses: TusHttpResponse...) { self.responses = responses }

    var fetchFn: TusFetch {
        { url, requestInit in
            let next = self.recordCallAndDequeueResponse(url: url, requestInit: requestInit)
            guard let next else { throw URLError(.unknown) }
            return next
        }
    }

    private func recordCallAndDequeueResponse(url: String, requestInit: TusFetchInit) -> TusHttpResponse? {
        lock.lock()
        defer { lock.unlock() }
        calls.append((url, requestInit))
        return responses.count > 1 ? responses.removeFirst() : responses.first
    }
}

private func client(_ fetchFn: @escaping TusFetch) throws -> TusUploadClient {
    try TusUploadClient(
        sessionToken: "tok-123", fetchFn: fetchFn, timeoutMs: 1_000, hubBaseUrl: HUB_BASE_URL)
}

final class TusUploadClientTests: XCTestCase {
    // MARK: - upload URL trust boundary

    func test_probe_rejectsCrossOriginUrlBeforeResolvingOrSendingBearer() async throws {
        let f = FakeTusFetch(response(200, ["Upload-Offset": "0"]))
        let tokenCalls = LockedBox<Int>(0)
        let c = try TusUploadClient(
            tokenProvider: {
                tokenCalls.mutate { $0 += 1 }
                return "secret-token"
            },
            fetchFn: f.fetchFn,
            hubBaseUrl: HUB_BASE_URL)

        await assertThrowsErrorType(TusProtocolError.self) {
            _ = try await c.probe("https://attacker.example/uploads/session")
        }

        XCTAssertEqual(tokenCalls.value, 0)
        XCTAssertTrue(f.calls.isEmpty)
    }

    func test_uploadChunk_rejectsCrossOriginAndCleartextUrlsWithoutSendingBearer() async throws {
        let f = FakeTusFetch(response(204, ["Upload-Offset": "1"]))
        let c = try client(f.fetchFn)

        await assertThrowsErrorType(TusProtocolError.self) {
            _ = try await c.uploadChunk("https://cdn.example/uploads/session", 0, Data([1]))
        }
        await assertThrowsErrorType(TusProtocolError.self) {
            _ = try await c.uploadChunk("http://hub.test/uploads/session", 0, Data([1]))
        }

        XCTAssertTrue(f.calls.isEmpty)
    }

    func test_localDevelopmentHttpAllowsOnlyTheConfiguredLocalOrigin() async throws {
        let f = FakeTusFetch(response(200, ["Upload-Offset": "0"]))
        let c = try TusUploadClient(
            sessionToken: "dev-token", fetchFn: f.fetchFn, hubBaseUrl: "http://127.0.0.1:8000")

        _ = try await c.probe("http://127.0.0.1:8000/api/v1/sync/uploads/session")
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer dev-token")

        await assertThrowsErrorType(TusProtocolError.self) {
            _ = try await c.probe("http://127.0.0.1:9000/api/v1/sync/uploads/session")
        }
        XCTAssertEqual(f.calls.count, 1)
    }

    func test_publicCleartextHubBaseUrlIsRejectedAtInitialization() {
        XCTAssertThrowsError(
            try TusUploadClient(
                sessionToken: "token", fetchFn: FakeTusFetch(response(200)).fetchFn,
                hubBaseUrl: "http://hub.example.com")
        ) { error in
            XCTAssertTrue(error is TusUploadClientConfigError)
        }
    }

    func test_legacyInitializerWithoutHubBaseUrlFailsClosedBeforeFetch() async throws {
        let f = FakeTusFetch(response(200, ["Upload-Offset": "0"]))
        let c = try TusUploadClient(sessionToken: "token", fetchFn: f.fetchFn)

        await assertThrowsErrorType(TusUploadClientConfigError.self) {
            _ = try await c.probe(URL_STR)
        }
        XCTAssertTrue(f.calls.isEmpty)
    }

    // MARK: - probe (HEAD)

    func test_probe_returnsServerOffsetWithBearerAndTusHeader() async throws {
        let f = FakeTusFetch(response(200, ["Upload-Offset": "512"]))
        let c = try client(f.fetchFn)
        let result = try await c.probe(URL_STR)
        XCTAssertEqual(result, TusProbeResult(offset: 512))
        XCTAssertEqual(f.calls[0].requestInit.method, "HEAD")
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-123")
        XCTAssertEqual(f.calls[0].requestInit.headers["Tus-Resumable"], "1.0.0")
    }

    func test_probe_carriesServerHashOnceComplete() async throws {
        let f = FakeTusFetch(response(200, ["Upload-Offset": "1024", "Upload-Sha256": "abc"]))
        let c = try client(f.fetchFn)
        let result = try await c.probe(URL_STR)
        XCTAssertEqual(result, TusProbeResult(offset: 1024, sha256: "abc"))
    }

    func test_probe_404And410ThrowTusSessionGoneError() async throws {
        let c404 = try client(FakeTusFetch(response(404)).fetchFn)
        await assertThrowsErrorType(TusSessionGoneError.self) { _ = try await c404.probe(URL_STR) }
        let c410 = try client(FakeTusFetch(response(410)).fetchFn)
        await assertThrowsErrorType(TusSessionGoneError.self) { _ = try await c410.probe(URL_STR) }
    }

    func test_probe_200WithoutUploadOffsetIsProtocolViolation() async throws {
        let c = try client(FakeTusFetch(response(200)).fetchFn)
        await assertThrowsErrorType(TusProtocolError.self) { _ = try await c.probe(URL_STR) }
    }

    // MARK: - uploadChunk (PATCH)

    func test_uploadChunk_sendsChunkAtOffsetAndReturnsAdvancedOffset() async throws {
        let f = FakeTusFetch(response(204, ["Upload-Offset": "768"]))
        let c = try client(f.fetchFn)
        let chunk = Data([1, 2, 3])
        let result = try await c.uploadChunk(URL_STR, 512, chunk)
        XCTAssertEqual(result, TusPatchResult(offset: 768))
        XCTAssertEqual(f.calls[0].requestInit.headers["Upload-Offset"], "512")
        XCTAssertEqual(f.calls[0].requestInit.headers["Content-Type"], "application/offset+octet-stream")
        XCTAssertEqual(f.calls[0].requestInit.body, chunk)
    }

    func test_uploadChunk_finalChunkCarriesWholeFileHash() async throws {
        let f = FakeTusFetch(response(204, ["Upload-Offset": "1024", "Upload-Sha256": "beef"]))
        let c = try client(f.fetchFn)
        let result = try await c.uploadChunk(URL_STR, 768, Data(count: 256))
        XCTAssertEqual(result, TusPatchResult(offset: 1024, sha256: "beef"))
    }

    func test_uploadChunk_409OffsetConflictIsResumable() async throws {
        // opshub sync/protocol.py: offset conflict carries Upload-Offset, never Upload-Sha256.
        let c = try client(FakeTusFetch(response(409, ["Upload-Offset": "512"])).fetchFn)
        do {
            _ = try await c.uploadChunk(URL_STR, 0, Data([1]))
            XCTFail("expected TusOffsetConflictError")
        } catch let error as TusOffsetConflictError {
            XCTAssertEqual(error.serverOffset, 512)
        }
    }

    func test_uploadChunk_409HashMismatchIsFatal() async throws {
        // opshub sync/protocol.py: hash mismatch returns 409 with Upload-Sha256 = server digest.
        let c = try client(FakeTusFetch(response(409, ["Upload-Offset": "1024", "Upload-Sha256": "deadbeef"])).fetchFn)
        do {
            _ = try await c.uploadChunk(URL_STR, 1024, Data([1]))
            XCTFail("expected TusHashMismatchError")
        } catch let error as TusHashMismatchError {
            XCTAssertEqual(error.serverSha256, "deadbeef")
        }
    }

    func test_uploadChunk_otherUnexpectedStatusesKeepThrowingTusProtocolError() async throws {
        let c = try client(FakeTusFetch(response(418)).fetchFn)
        await assertThrowsErrorType(TusProtocolError.self) { _ = try await c.uploadChunk(URL_STR, 0, Data([1])) }
    }

    func test_uploadChunk_sessionLossMidUploadThrowsTusSessionGoneError() async throws {
        let c = try client(FakeTusFetch(response(410)).fetchFn)
        await assertThrowsErrorType(TusSessionGoneError.self) { _ = try await c.uploadChunk(URL_STR, 0, Data([1])) }
    }

    func test_timeoutAbortsUnderlyingRequest() async throws {
        let seenCancellation = LockedBox<Bool>(false)
        let hung: TusFetch = { _, _ in
            // `Task.sleep` throws `CancellationError` itself the instant it notices cancellation,
            // so swallow that with `try?` and let the loop's own check observe/record it.
            while true {
                if Task.isCancelled {
                    seenCancellation.mutate { $0 = true }
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let c = try TusUploadClient(
            sessionToken: "t", fetchFn: hung, timeoutMs: 10, hubBaseUrl: HUB_BASE_URL)
        do {
            _ = try await c.probe(URL_STR)
            XCTFail("expected the probe to throw")
        } catch {
            // expected — timed out
        }
        XCTAssertTrue(seenCancellation.value)
    }
}
