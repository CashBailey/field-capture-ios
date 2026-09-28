import FieldContracts
import FieldDomain
// Port of apps/mobile/__tests__/opshub-sync-transport.test.ts — wire-contract tests for
// `OpsHubSyncTransport` (POST /sync/commands, GET /sync/changes, POST /sync/uploads).
// Discipline under test: snake_case wire mapping is exact, per-operation outcomes come back as
// data, transport/protocol failures throw typed errors, and a malformed response never becomes a
// guessed outcome.
import XCTest

@testable import FieldAdapters

private func jsonResponse(_ status: Int, _ body: Any) -> HubHttpResponse {
    let data = try! JSONSerialization.data(withJSONObject: body)
    return HubHttpResponse(status: status, body: data)
}

private final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HubHttpResponse]
    private(set) var calls: [(url: String, requestInit: HubFetchInit)] = []

    init(_ responses: HubHttpResponse...) { self.responses = responses }

    var fetchFn: HubFetch {
        { url, requestInit in
            let next = self.recordCallAndDequeueResponse(url: url, requestInit: requestInit)
            guard let next else { throw URLError(.unknown) }
            return next
        }
    }

    private func recordCallAndDequeueResponse(url: String, requestInit: HubFetchInit) -> HubHttpResponse? {
        lock.lock()
        defer { lock.unlock() }
        calls.append((url, requestInit))
        return responses.count > 1 ? responses.removeFirst() : responses.first
    }
}

private let CONFIG_BASE_URL = "http://hub.test"
private let CONFIG_SESSION_TOKEN = "tok-123"

private let ENVELOPE = OperationEnvelope<JSONValue>(
    opId: "op-1", kind: .command, type: "ticket.submit", idempotencyKey: "gtr:devA:7:op-1",
    localSeq: 7, dependsOn: ["op-0"], precondition: VersionPrecondition(baseVersion: 3),
    payload: .object(["hello": .string("hub")])
)

final class OpsHubSyncTransportTests: XCTestCase {
    // MARK: - per-call token provider

    func test_sendsFreshTokenPerRequest() async throws {
        let token = LockedBox<String>("tok-old")
        let f = FakeFetch(
            jsonResponse(200, ["token": ["authority_epoch": 1, "commit_seq": 0], "changes": [Any]()]),
            jsonResponse(200, ["token": ["authority_epoch": 1, "commit_seq": 0], "changes": [Any]()])
        )
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn,
            tokenProvider: { token.value })
        _ = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 0))
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-old")
        token.mutate { $0 = "tok-refreshed" }
        _ = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 0))
        XCTAssertEqual(f.calls[1].requestInit.headers["Authorization"], "Bearer tok-refreshed")
    }

    func test_awaitsAsyncTokenProvider() async throws {
        let f = FakeFetch(jsonResponse(200, ["token": ["authority_epoch": 1, "commit_seq": 0], "changes": [Any]()]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn,
            tokenProvider: {
                try await Task.sleep(nanoseconds: 1_000_000)
                return "tok-async"
            })
        _ = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 0))
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-async")
    }

    func test_fallsBackToStaticConfigTokenWhenNoProvider() async throws {
        let f = FakeFetch(jsonResponse(200, ["token": ["authority_epoch": 1, "commit_seq": 0], "changes": [Any]()]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        _ = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 0))
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-123")
    }

    // MARK: - submitBatch

    func test_submitBatch_postsExactWireShape() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "results": [
                        ["op_id": "op-1", "outcome": "accepted", "token": ["authority_epoch": 1, "commit_seq": 42]]
                    ]
                ]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        _ = try await transport.submitBatch([ENVELOPE])

        XCTAssertEqual(f.calls[0].url, "http://hub.test/api/v1/sync/commands")
        XCTAssertEqual(f.calls[0].requestInit.method, "POST")
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-123")
        let body = try JSONSerialization.jsonObject(with: f.calls[0].requestInit.body!) as! [String: Any]
        let ops = body["operations"] as! [[String: Any]]
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0]["op_id"] as? String, "op-1")
        XCTAssertEqual(ops[0]["kind"] as? String, "command")
        XCTAssertEqual(ops[0]["type"] as? String, "ticket.submit")
        XCTAssertEqual(ops[0]["idempotency_key"] as? String, "gtr:devA:7:op-1")
        XCTAssertEqual(ops[0]["local_seq"] as? Int, 7)
        XCTAssertEqual(ops[0]["depends_on"] as? [String], ["op-0"])
        XCTAssertEqual((ops[0]["precondition"] as? [String: Any])?["base_version"] as? Int, 3)
        XCTAssertEqual((ops[0]["payload"] as? [String: Any])?["hello"] as? String, "hub")
    }

    func test_submitBatch_omitsPreconditionForEvents() async throws {
        let f = FakeFetch(jsonResponse(200, ["results": [Any]()]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let event = OperationEnvelope<JSONValue>(
            opId: ENVELOPE.opId, kind: .event, type: ENVELOPE.type, idempotencyKey: ENVELOPE.idempotencyKey,
            localSeq: ENVELOPE.localSeq, dependsOn: [], precondition: nil, payload: ENVELOPE.payload
        )
        _ = try await transport.submitBatch([event])
        let body = try JSONSerialization.jsonObject(with: f.calls[0].requestInit.body!) as! [String: Any]
        let wire = (body["operations"] as! [[String: Any]])[0]
        XCTAssertNil(wire["precondition"])
    }

    func test_submitBatch_mapsAllThreeOutcomes() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "results": [
                        ["op_id": "a", "outcome": "accepted", "token": ["authority_epoch": 2, "commit_seq": 9]],
                        [
                            "op_id": "b", "outcome": "rejected", "rejection_code": "stale_version",
                            "detail": "SR changed", "latest": ["version": 4],
                        ],
                        ["op_id": "c", "outcome": "needs-review", "review_reason": "assignment_changed"],
                    ]
                ]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let results = try await transport.submitBatch([ENVELOPE])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0], .accepted(opId: "a", token: ChangeToken(authorityEpoch: 2, commitSeq: 9)))
        XCTAssertEqual(
            results[1],
            .rejected(
                opId: "b", rejectionCode: "stale_version", detail: "SR changed",
                latest: .object(["version": .number(4)])))
        XCTAssertEqual(results[2], .needsReview(opId: "c", reviewReason: "assignment_changed"))
    }

    func test_submitBatch_emptyBatchNeverTouchesNetwork() async throws {
        let f = FakeFetch(jsonResponse(200, ["results": [Any]()]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let results = try await transport.submitBatch([])
        XCTAssertEqual(results, [])
        XCTAssertEqual(f.calls.count, 0)
    }

    func test_submitBatch_malformedResponsesThrowHubResponseError() async throws {
        let bodies: [[String: Any]] = [
            ["results": [["op_id": "a", "outcome": "maybe"]]],
            ["results": [["op_id": "a", "outcome": "accepted"]]],
            ["results": [["op_id": "a", "outcome": "rejected"]]],
            ["ok": true],
        ]
        for body in bodies {
            let transport = OpsHubSyncTransport(
                baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
                fetchFn: FakeFetch(jsonResponse(200, body)).fetchFn)
            await assertThrowsErrorType(HubResponseError.self) { _ = try await transport.submitBatch([ENVELOPE]) }
        }
    }

    func test_submitBatch_throwsTypedErrors() async throws {
        let offline: HubFetch = { _, _ in throw URLError(.networkConnectionLost) }
        let transportOffline = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: offline)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await transportOffline.submitBatch([ENVELOPE]) }

        let transport401 = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(401, [:])).fetchFn)
        await assertThrowsErrorType(HubAuthError.self) { _ = try await transport401.submitBatch([ENVELOPE]) }

        let transport503 = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(503, [:])).fetchFn)
        await assertThrowsErrorType(HubResponseError.self) { _ = try await transport503.submitBatch([ENVELOPE]) }
    }

    // MARK: - pullChanges

    func test_pullChanges_getsAfterFrontierAndMapsPage() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "token": ["authority_epoch": 1, "commit_seq": 58],
                    "changes": [["entity": "assignment", "id": "sr-1"]],
                ]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let page = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 57))

        XCTAssertEqual(f.calls[0].url, "http://hub.test/api/v1/sync/changes?after_epoch=1&after_seq=57")
        XCTAssertEqual(page.token, ChangeToken(authorityEpoch: 1, commitSeq: 58))
        XCTAssertEqual(page.changes, [.object(["entity": .string("assignment"), "id": .string("sr-1")])])
    }

    func test_pullChanges_410ThrowsStaleChangeTokenErrorWithResetTo() async throws {
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(
                jsonResponse(
                    410, ["error": "stale_change_token", "reset_to": ["authority_epoch": 2, "commit_seq": 0]])
            ).fetchFn
        )
        do {
            _ = try await transport.pullChanges(since: ChangeToken(authorityEpoch: 1, commitSeq: 5))
            XCTFail("expected StaleChangeTokenError")
        } catch let error as StaleChangeTokenError {
            XCTAssertEqual(error.resetTo, ChangeToken(authorityEpoch: 2, commitSeq: 0))
        }
    }

    func test_pullChanges_410WithoutResetToStillThrows() async throws {
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(410, ["error": "stale_change_token"])).fetchFn
        )
        do {
            _ = try await transport.pullChanges(since: ZERO_CHANGE_TOKEN)
            XCTFail("expected StaleChangeTokenError")
        } catch let error as StaleChangeTokenError {
            XCTAssertNil(error.resetTo)
        }
    }

    func test_pullChanges_malformedTokenThrowsHubResponseError() async throws {
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(200, ["token": ["authority_epoch": "x"], "changes": [Any]()])).fetchFn
        )
        await assertThrowsErrorType(HubResponseError.self) {
            _ = try await transport.pullChanges(since: ZERO_CHANGE_TOKEN)
        }
    }

    // MARK: - openUploadSession

    private static let REQUEST = UploadSessionRequest(
        blobId: "blob-1", sha256: "abc123", byteLength: 1024, mimeType: "image/jpeg", idempotencyKey: "gtr:devA:8:up-1")

    func test_openUploadSession_postsWireShapeAndMapsNewSession() async throws {
        let f = FakeFetch(
            jsonResponse(
                201,
                [
                    "result": "new-session", "upload_session_id": "sess-1",
                    "upload_url": "http://hub.test/api/v1/sync/uploads/sess-1",
                ]))
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let session = try await transport.openUploadSession(Self.REQUEST)

        let body = try JSONSerialization.jsonObject(with: f.calls[0].requestInit.body!) as! [String: Any]
        XCTAssertEqual(body["blob_id"] as? String, "blob-1")
        XCTAssertEqual(body["sha256"] as? String, "abc123")
        XCTAssertEqual(body["byte_length"] as? Int, 1024)
        XCTAssertEqual(body["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(body["idempotency_key"] as? String, "gtr:devA:8:up-1")
        XCTAssertEqual(
            session, .newSession(uploadSessionId: "sess-1", uploadUrl: "http://hub.test/api/v1/sync/uploads/sess-1"))
    }

    func test_openUploadSession_mapsContentHashDedupe() async throws {
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(200, ["result": "already-present", "blob_id": "blob-1"])).fetchFn
        )
        let session = try await transport.openUploadSession(Self.REQUEST)
        XCTAssertEqual(session, .alreadyPresent(blobId: "blob-1"))
    }

    func test_openUploadSession_unknownResultShapeThrows() async throws {
        let transport = OpsHubSyncTransport(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(200, ["result": "fine"])).fetchFn
        )
        await assertThrowsErrorType(HubResponseError.self) { _ = try await transport.openUploadSession(Self.REQUEST) }
    }
}
