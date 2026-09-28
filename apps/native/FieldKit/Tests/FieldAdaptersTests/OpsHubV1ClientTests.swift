import FieldContracts
import FieldDomain
// Port of apps/mobile/__tests__/opshub-v1-client.test.ts.
import XCTest

@testable import FieldAdapters

private func jsonResponse(_ status: Int, _ body: Any) -> HubHttpResponse {
    let data = try! JSONSerialization.data(withJSONObject: body)
    return HubHttpResponse(status: status, body: data)
}

/// Records calls; replies from a queue (or repeats a single canned response).
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

private let offlineFetch: HubFetch = { _, _ in throw URLError(.networkConnectionLost) }

private let SUBMISSION = HubFieldTicketSubmission(
    idempotencyKey: "gtr:devA:1:op-1",
    serviceRequestId: "sr-9",
    snapshotHash: "hash-abc",
    ticketNo: "12345",
    quantityBbl: 120,
    disposalTicketNo: "D-123"
)

private let CONFIG_BASE_URL = "http://hub.test"
private let CONFIG_SESSION_TOKEN = "tok-123"

final class OpsHubV1ClientTests: XCTestCase {
    // MARK: - getSessionStatus

    func test_getSessionStatus_callsWithBearerAuth() async throws {
        let f = FakeFetch(jsonResponse(200, ["clocked_in": true, "clocked_in_since": "2026-06-09T12:00:00Z"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        _ = try await client.getSessionStatus()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(f.calls[0].url, "http://hub.test/api/v1/sync/session-status")
        XCTAssertEqual(f.calls[0].requestInit.method, "GET")
        XCTAssertEqual(f.calls[0].requestInit.headers["Authorization"], "Bearer tok-123")
    }

    func test_getSessionStatus_mapsClockedInResponse() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "clocked_in": true, "clocked_in_since": "2026-06-09T12:00:00Z", "source": "timeclock",
                    "employee_id": "emp-1", "assignments_available": true, "server_time": "2026-06-09T12:00:05Z",
                ]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let status = try await client.getSessionStatus()
        XCTAssertEqual(
            status,
            HubSessionStatus(
                clockedIn: true, clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock",
                employeeId: "emp-1", assignmentsAvailable: true, serverTime: "2026-06-09T12:00:05Z"
            ))
    }

    func test_getSessionStatus_readsSinceAlias() async throws {
        let f = FakeFetch(
            jsonResponse(
                200, ["clocked_in": true, "since": "2026-06-09T06:30:00Z", "server_time": "2026-06-09T13:00:00Z"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let status = try await client.getSessionStatus()
        XCTAssertEqual(status.clockedInSince, "2026-06-09T06:30:00Z")
        XCTAssertEqual(status.serverTime, "2026-06-09T13:00:00Z")
    }

    func test_getSessionStatus_mapsClockedOut() async throws {
        let f = FakeFetch(jsonResponse(200, ["clocked_in": false]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let status = try await client.getSessionStatus()
        XCTAssertFalse(status.clockedIn)
        XCTAssertNil(status.clockedInSince)
    }

    func test_getSessionStatus_401_throwsHubAuthError() async throws {
        let f = FakeFetch(jsonResponse(401, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        await assertThrowsErrorType(HubAuthError.self) { _ = try await client.getSessionStatus() }
    }

    func test_getSessionStatus_403_throwsHubAuthError() async throws {
        let f = FakeFetch(jsonResponse(403, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        await assertThrowsErrorType(HubAuthError.self) { _ = try await client.getSessionStatus() }
    }

    func test_getSessionStatus_offline_throwsHubNetworkError() async throws {
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: offlineFetch)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await client.getSessionStatus() }
    }

    func test_getSessionStatus_malformedBody_throwsHubResponseError() async throws {
        let f = FakeFetch(jsonResponse(200, ["nope": 1]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        await assertThrowsErrorType(HubResponseError.self) { _ = try await client.getSessionStatus() }
    }

    func test_getSessionStatus_5xx_throwsHubResponseError() async throws {
        let f = FakeFetch(jsonResponse(500, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        await assertThrowsErrorType(HubResponseError.self) { _ = try await client.getSessionStatus() }
    }

    // MARK: - getAssignments

    private static let WIRE_ASSIGNMENT: [String: Any] = [
        "service_request_id": "sr-9", "snapshot_hash": "hash-abc", "snapshot": ["srId": "sr-9", "customer": "ACME"],
    ]

    func test_getAssignments_mapsEntriesWithSnapshotHashes() async throws {
        let f = FakeFetch(jsonResponse(200, ["assignments": [Self.WIRE_ASSIGNMENT]]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let got = try await client.getAssignments()
        XCTAssertEqual(f.calls[0].url, "http://hub.test/api/v1/sync/assignments")
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].serviceRequestId, "sr-9")
        XCTAssertEqual(got[0].snapshotHash, "hash-abc")
    }

    func test_getAssignments_mapsRichFieldsPreservingSnapshot() async throws {
        let rich: [String: Any] = [
            "service_request_id": "sr-99", "snapshot_hash": "hash-rich", "latest_server_version": 42,
            "snapshot": ["srId": "sr-99", "legacy": true],
            "customer": ["customer_id": "cust-1", "name": "ACME Oil"],
            "lease": ["lease_id": "lease-1", "name": "North Lease"],
            "wells": [["well_id": "well-12", "lease_id": "lease-1", "name": "Well 12H"]],
            "material": ["name": "Produced water"],
            "disposal_site": ["site_id": "disp-1", "name": "SWD 8"],
            "vehicle": ["vehicle_id": "truck-7", "label": "Truck 7"],
            "job_type": ["id": "jt-1", "name": "water-haul"],
            "ignored_extra": ["value": "ignored"],
            "workflow_requirements": ["clock_in_required": true, "required_steps": ["pre_trip_dvir", "jha"]],
        ]
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN,
            fetchFn: FakeFetch(jsonResponse(200, ["assignments": [rich]])).fetchFn)
        let assignments = try await client.getAssignments()
        XCTAssertEqual(assignments.count, 1)
        let a = assignments[0]
        XCTAssertEqual(a.serviceRequestId, "sr-99")
        XCTAssertEqual(a.snapshotHash, "hash-rich")
        XCTAssertEqual(a.latestServerVersion, "42")
        XCTAssertEqual(a.details?.customer, AssignmentNamedRef(id: "cust-1", name: "ACME Oil"))
        XCTAssertEqual(a.details?.lease, AssignmentNamedRef(id: "lease-1", name: "North Lease"))
        XCTAssertEqual(a.details?.wells, [AssignmentWell(id: "well-12", name: "Well 12H", leaseId: "lease-1")])
        XCTAssertEqual(a.details?.material, "Produced water")
        XCTAssertEqual(a.details?.disposalSite, AssignmentNamedRef(id: "disp-1", name: "SWD 8"))
        XCTAssertEqual(a.details?.vehicle, AssignmentNamedRef(id: "truck-7", name: "Truck 7"))
        XCTAssertEqual(a.details?.jobType, AssignmentNamedRef(id: "jt-1", name: "water-haul"))
        XCTAssertEqual(
            a.details?.workflowRequirements,
            WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir, .jha]))
    }

    func test_getAssignments_ignoresExtraFields() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "assignments": [
                        [
                            "service_request_id": "sr-9", "snapshot_hash": "hash-abc",
                            "ignored_extra": ["value": "ignored"],
                        ]
                    ]
                ]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let got = try await client.getAssignments()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].serviceRequestId, "sr-9")
        XCTAssertEqual(got[0].snapshotHash, "hash-abc")
        XCTAssertNil(got[0].snapshot)
    }

    func test_getAssignments_derivesWorkflowRequirements() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "assignments": [
                        [
                            "service_request_id": "sr-rich", "snapshot_hash": "hash-rich",
                            "workflow_requirements": ["clock_in_required": true, "required_steps": ["pre_trip_dvir"]],
                            "snapshot": [String: Any](),
                        ],
                        [
                            "service_request_id": "sr-legacy", "snapshot_hash": "hash-legacy",
                            "snapshot": ["workflow_requirements": ["require_jha_per_sr": true]],
                        ],
                    ]
                ]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let assignments = try await client.getAssignments()

        XCTAssertEqual(
            parseWorkflowRequirementsFromAssignments(assignments, "sr-rich"),
            WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir])
        )
        XCTAssertEqual(
            parseWorkflowRequirementsFromAssignments(assignments, "sr-legacy"),
            WorkflowRequirements(clockInRequired: false, requiredSteps: [.jha])
        )
    }

    func test_getAssignments_acceptsBareArrayBody() async throws {
        let f = FakeFetch(jsonResponse(200, [Self.WIRE_ASSIGNMENT]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let got = try await client.getAssignments()
        XCTAssertEqual(got.count, 1)
    }

    func test_getAssignments_mapsEmptyList() async throws {
        let f = FakeFetch(jsonResponse(200, ["assignments": [Any]()]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let got = try await client.getAssignments()
        XCTAssertEqual(got.count, 0)
    }

    func test_getAssignments_missingSnapshotHash_throwsHubResponseError() async throws {
        let f = FakeFetch(jsonResponse(200, ["assignments": [["service_request_id": "sr-9"]]]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        await assertThrowsErrorType(HubResponseError.self) { _ = try await client.getAssignments() }
    }

    func test_getAssignments_401AndOffline() async throws {
        let f401 = FakeFetch(jsonResponse(401, [:]))
        let client401 = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f401.fetchFn)
        await assertThrowsErrorType(HubAuthError.self) { _ = try await client401.getAssignments() }

        let clientOffline = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: offlineFetch)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await clientOffline.getAssignments() }
    }

    // MARK: - submitFieldTicket

    func test_submit_postsSnakeCasePayload() async throws {
        let f = FakeFetch(jsonResponse(201, ["accepted": true]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        _ = try await client.submitFieldTicket(SUBMISSION)
        let call = f.calls[0]
        XCTAssertEqual(call.url, "http://hub.test/api/v1/sync/submit")
        XCTAssertEqual(call.requestInit.method, "POST")
        XCTAssertEqual(call.requestInit.headers["Authorization"], "Bearer tok-123")
        XCTAssertEqual(call.requestInit.headers["Idempotency-Key"], "gtr:devA:1:op-1")
        let bodyJson = try JSONSerialization.jsonObject(with: call.requestInit.body!) as! [String: Any]
        XCTAssertEqual(bodyJson["idempotency_key"] as? String, "gtr:devA:1:op-1")
        XCTAssertEqual(bodyJson["service_request_id"] as? String, "sr-9")
        XCTAssertEqual(bodyJson["snapshot_hash"] as? String, "hash-abc")
        XCTAssertEqual(bodyJson["ticket_no"] as? String, "12345")
        XCTAssertEqual(bodyJson["quantity_bbl"] as? Double, 120)
        XCTAssertEqual(bodyJson["disposal_ticket_no"] as? String, "D-123")
    }

    func test_submit_maps201ToAcceptedNotDuplicate() async throws {
        let f = FakeFetch(jsonResponse(201, ["accepted": true, "ticket_id": "ft-1"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: nil, ticketId: "ft-1"))
    }

    func test_submit_mapsDuplicateReplay() async throws {
        let f = FakeFetch(jsonResponse(200, ["accepted": true, "duplicate": true, "ticket_id": "ft-1"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: true, snapshotDrift: nil, ticketId: "ft-1"))
    }

    func test_submit_surfacesSnapshotDriftOnAccepted201() async throws {
        let f = FakeFetch(
            jsonResponse(201, ["accepted": true, "ticket_id": "ft-drift", "duplicate": false, "snapshot_drift": true]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: true, ticketId: "ft-drift"))
    }

    func test_submit_omitsSnapshotDriftWhenFalse() async throws {
        let f = FakeFetch(jsonResponse(201, ["accepted": true, "ticket_id": "ft-1", "snapshot_drift": false]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: nil, ticketId: "ft-1"))
    }

    func test_submit_mapsLegacySuccessShape() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                ["field_ticket_id": "legacy-ft-1", "status": "created", "duplicate": false, "snapshot_drift": false]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: nil, ticketId: "legacy-ft-1"))
    }

    func test_submit_mapsLegacyDuplicate() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                ["field_ticket_id": "legacy-ft-1", "status": "accepted", "duplicate": true, "snapshot_drift": false]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .accepted(let duplicate, _, let ticketId) = result else { return XCTFail("expected accepted") }
        XCTAssertTrue(duplicate)
        XCTAssertEqual(ticketId, "legacy-ft-1")
    }

    func test_submit_neverLetsLegacyShapeOverrideExplicitAcceptedFalse() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                [
                    "accepted": false, "field_ticket_id": "legacy-ft-1", "status": "submitted", "duplicate": false,
                    "snapshot_drift": false,
                ]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .transient(let reason, _, _) = result else { return XCTFail("expected transient, got \(result)") }
        XCTAssertEqual(reason, .malformedResponse)
    }

    func test_submit_readsFieldTicketIdOnModernAcceptedPath() async throws {
        let f = FakeFetch(jsonResponse(200, ["accepted": true, "field_ticket_id": "ft-legacy-id"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .accepted(duplicate: false, snapshotDrift: nil, ticketId: "ft-legacy-id"))
    }

    func test_submit_mapsLegacySnapshotDriftTrueToNeedsReview() async throws {
        let f = FakeFetch(
            jsonResponse(
                200,
                ["field_ticket_id": "legacy-ft-1", "status": "created", "duplicate": false, "snapshot_drift": true]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(
            result, .rejected(kind: .needsReview, httpStatus: 200, rejectionCode: "snapshot_drift", detail: nil))
    }

    func test_submit_maps403ToBlocked() async throws {
        let f = FakeFetch(jsonResponse(403, ["reason_code": "not_clocked_in", "detail": "no open punch"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(
            result, .rejected(kind: .blocked, httpStatus: 403, rejectionCode: "not_clocked_in", detail: "no open punch")
        )
    }

    func test_submit_maps403NoBodyCodeToFallback() async throws {
        let f = FakeFetch(jsonResponse(403, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .rejected(let kind, _, let code, _) = result else { return XCTFail("expected rejected") }
        XCTAssertEqual(kind, .blocked)
        XCTAssertEqual(code, "forbidden")
    }

    func test_submit_maps409WorkflowGuard() async throws {
        let f = FakeFetch(jsonResponse(409, ["detail": "Driver is not clocked in — clock in before submitting work."]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(
            result,
            .rejected(
                kind: .blocked, httpStatus: 409, rejectionCode: "workflow_blocked",
                detail: "Driver is not clocked in — clock in before submitting work."))
    }

    func test_submit_passesThroughExplicit409ReasonCode() async throws {
        let f = FakeFetch(jsonResponse(409, ["reason_code": "in_progress"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .rejected(let kind, let status, let code, _) = result else { return XCTFail("expected rejected") }
        XCTAssertEqual(kind, .blocked)
        XCTAssertEqual(status, 409)
        XCTAssertEqual(code, "in_progress")
    }

    func test_submit_maps412ToNeedsReview() async throws {
        let f = FakeFetch(jsonResponse(412, ["reason_code": "stale_version"]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .rejected(let kind, let status, let code, _) = result else { return XCTFail("expected rejected") }
        XCTAssertEqual(kind, .needsReview)
        XCTAssertEqual(status, 412)
        XCTAssertEqual(code, "stale_version")
    }

    func test_submit_maps422ToNeedsReview() async throws {
        let f = FakeFetch(jsonResponse(422, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .rejected(let kind, let status, _, _) = result else { return XCTFail("expected rejected") }
        XCTAssertEqual(kind, .needsReview)
        XCTAssertEqual(status, 422)
    }

    func test_submit_maps401ToAuthFailed() async throws {
        let f = FakeFetch(jsonResponse(401, [:]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        XCTAssertEqual(result, .authFailed(httpStatus: 401))
    }

    func test_submit_mapsNetworkFailureToTransient() async throws {
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: offlineFetch)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .transient(let reason, _, _) = result else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .network)
    }

    func test_submit_maps5xxAnd429ToTransient() async throws {
        for status in [500, 503, 429] {
            let f = FakeFetch(jsonResponse(status, [:]))
            let client = OpsHubV1Client(
                baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
            let result = try await client.submitFieldTicket(SUBMISSION)
            guard case .transient(let reason, let httpStatus, _) = result else {
                return XCTFail("expected transient for \(status)")
            }
            XCTAssertEqual(reason, .server)
            XCTAssertEqual(httpStatus, status)
        }
    }

    func test_submit_2xxWithoutAcceptedTrueIsMalformedTransient() async throws {
        let f = FakeFetch(jsonResponse(200, ["weird": true]))
        let client = OpsHubV1Client(baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: f.fetchFn)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .transient(let reason, _, _) = result else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .malformedResponse)
    }

    // MARK: - request time-bounding

    func test_hungGet_timesOutIntoHubNetworkError() async throws {
        let hungFetch: HubFetch = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return jsonResponse(200, [:])
        }
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: hungFetch, timeoutMs: 10)
        await assertThrowsErrorType(HubNetworkError.self) { _ = try await client.getSessionStatus() }
    }

    func test_hungSubmit_timesOutIntoTransient() async throws {
        let hungFetch: HubFetch = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return jsonResponse(200, [:])
        }
        let client = OpsHubV1Client(
            baseUrl: CONFIG_BASE_URL, sessionToken: CONFIG_SESSION_TOKEN, fetchFn: hungFetch, timeoutMs: 10)
        let result = try await client.submitFieldTicket(SUBMISSION)
        guard case .transient(let reason, _, _) = result else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .network)
    }
}

/// Asserts an async throwing expression throws an error of exactly `errorType`.
func assertThrowsErrorType<E: Error>(
    _ errorType: E.Type,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> Void
) async {
    do {
        try await expression()
        XCTFail("expected \(E.self) to be thrown", file: file, line: line)
    } catch is E {
        // expected
    } catch {
        XCTFail("expected \(E.self), got \(Swift.type(of: error)): \(error)", file: file, line: line)
    }
}
