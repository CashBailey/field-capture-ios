import FieldContracts
// Port of __tests__/field-session.test.ts — clock gate + assignment pull (first real OpsHub
// integration slice).
import XCTest

@testable import FieldDomain

private struct FakeSessionStatusSource: SessionStatusSource {
    let status: HubSessionStatus
    func getSessionStatus(options: HubRequestOptions?) async throws -> HubSessionStatus { status }
}

private struct FailingSessionStatusSource: SessionStatusSource {
    let error: Error
    func getSessionStatus(options: HubRequestOptions?) async throws -> HubSessionStatus { throw error }
}

private struct FakeAssignmentSource: AssignmentSource {
    let getAssignmentsFn: () async throws -> [HubAssignment]
    func getAssignments(options: HubRequestOptions?) async throws -> [HubAssignment] {
        try await getAssignmentsFn()
    }
}

final class FieldSessionTests: XCTestCase {
    private let CLOCKED_IN = HubSessionStatus(
        clockedIn: true, clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock",
        employeeId: "emp-1", assignmentsAvailable: true
    )
    private let CLOCKED_OUT = HubSessionStatus(
        clockedIn: false, clockedInSince: nil, source: nil, employeeId: "emp-1", assignmentsAvailable: false
    )
    private let ASSIGNMENTS: [HubAssignment] = [
        HubAssignment(serviceRequestId: "sr-1", snapshotHash: "h1", snapshot: ["srId": "sr-1"] as [String: Any]),
        HubAssignment(serviceRequestId: "sr-2", snapshotHash: "h2", snapshot: ["srId": "sr-2"] as [String: Any]),
    ]
    private let WITHIN_LIMIT_POLICY = OfflinePolicy(
        state: .offlineWithinLimit, elapsedMs: 2 * 60 * 60 * 1000, remainingMs: 22 * 60 * 60 * 1000,
        windowMs: 24 * 60 * 60 * 1000
    )
    private let OVER_LIMIT_POLICY = OfflinePolicy(
        state: .offlineOverLimit, elapsedMs: 25 * 60 * 60 * 1000, remainingMs: 0, windowMs: 24 * 60 * 60 * 1000
    )

    // ---- clock gate (Hub/TimeClock is the authority on clock-in) ----

    func testUnlocksFieldWorkWhenHubSaysTheDriverIsClockedIn() async throws {
        let gate = try await evaluateClockGate(FakeSessionStatusSource(status: CLOCKED_IN))
        XCTAssertEqual(
            gate, .unlocked(clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock", employeeId: "emp-1"))
    }

    func testLocksFieldWorkWhenTheDriverIsNotClockedIn() async throws {
        let gate = try await evaluateClockGate(FakeSessionStatusSource(status: CLOCKED_OUT))
        XCTAssertEqual(gate, .locked(reason: .notClockedIn, detail: nil))
    }

    func testLocksVisiblyWhenHubIsUnreachable() async throws {
        let gate = try await evaluateClockGate(FailingSessionStatusSource(error: HubNetworkError("offline")))
        guard case .locked(let reason, _) = gate else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, .hubUnreachable)
    }

    func testLocksVisiblyWhenAuthFails() async throws {
        let gate = try await evaluateClockGate(
            FailingSessionStatusSource(error: HubAuthError("bad token", httpStatus: 401)))
        guard case .locked(let reason, _) = gate else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, .authFailed)
    }

    func testLocksVisiblyWhenHubAnswersGarbage() async throws {
        let gate = try await evaluateClockGate(
            FailingSessionStatusSource(error: HubResponseError("session-status body is missing a boolean clocked_in"))
        )
        guard case .locked(let reason, _) = gate else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, .badHubResponse)
    }

    func testLocksVisiblyWhenHubReturnsA5xxOnSessionStatus() async throws {
        let gate = try await evaluateClockGate(
            FailingSessionStatusSource(
                error: HubResponseError("Hub returned 503 for GET /api/v1/sync/session-status", httpStatus: 503))
        )
        guard case .locked(let reason, _) = gate else { return XCTFail("expected locked") }
        XCTAssertEqual(reason, .badHubResponse)
    }

    private struct BoomError: Error {}

    func testDoesNotSwallowClientSideProgrammingErrorsAsALockReason() async throws {
        do {
            _ = try await evaluateClockGate(FailingSessionStatusSource(error: BoomError()))
            XCTFail("expected throw")
        } catch is BoomError {
            // expected
        }
    }

    // ---- applyOfflinePolicyToGate ----

    func testKeepsWorkActionableDuringAShortHubOutageOnlyAfterAHubProvenUnlock() {
        let hubUnlocked = FieldWorkGate.unlocked(
            clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock", employeeId: "emp-1")
        let result = applyOfflinePolicyToGate(
            previousGate: hubUnlocked,
            nextGate: .locked(reason: .hubUnreachable, detail: "offline"),
            offlinePolicy: WITHIN_LIMIT_POLICY
        )
        XCTAssertEqual(result, hubUnlocked)
    }

    func testDoesNotInventAClockInOnColdOfflineStartupEvenInsideTheGraceWindow() {
        let nextGate = FieldWorkGate.locked(reason: .hubUnreachable, detail: "offline")
        let result = applyOfflinePolicyToGate(
            previousGate: .locked(reason: .hubUnreachable, detail: nil),
            nextGate: nextGate,
            offlinePolicy: WITHIN_LIMIT_POLICY
        )
        XCTAssertEqual(result, nextGate)
    }

    func testBlocksNewWorkOnceTheOfflineWindowIsOverLimit() {
        let result = applyOfflinePolicyToGate(
            previousGate: .unlocked(clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock", employeeId: "emp-1"),
            nextGate: .locked(reason: .hubUnreachable, detail: "offline"),
            offlinePolicy: OVER_LIMIT_POLICY
        )
        XCTAssertEqual(result, .locked(reason: .offlineOverLimit, detail: "offline-over-limit-evidence"))
    }

    func testDoesNotSoftenAuthFailuresOrBadHubResponses() {
        let nextGate = FieldWorkGate.locked(reason: .authFailed, detail: nil)
        let result = applyOfflinePolicyToGate(
            previousGate: .unlocked(clockedInSince: "2026-06-09T12:00:00Z", source: "timeclock", employeeId: nil),
            nextGate: nextGate,
            offlinePolicy: WITHIN_LIMIT_POLICY
        )
        XCTAssertEqual(result, nextGate)
    }

    func testFormatsTheOverLimitLockReasonForDrivers() {
        XCTAssertEqual(
            fieldWorkGateLockReason(.offlineOverLimit),
            "offline over limit — reconnect to Ops Hub before starting new work"
        )
    }

    // ---- refreshFieldSession (clock gate + assignment pull) ----

    func testPullsAssignmentsAndRetainsSnapshotHashesWhenUnlocked() async throws {
        let store = VolatileAssignmentStore()
        let result = try await refreshFieldSession(
            statusSource: FakeSessionStatusSource(status: CLOCKED_IN),
            assignmentSource: FakeAssignmentSource(getAssignmentsFn: { self.ASSIGNMENTS }),
            store: store
        )
        guard case .unlocked = result.gate else { return XCTFail("expected unlocked") }
        XCTAssertEqual(result.assignments, .synced(count: 2))
        XCTAssertEqual(store.listAssignments().map(\.serviceRequestId), ["sr-1", "sr-2"])
        XCTAssertEqual(store.getSnapshotHash("sr-1"), "h1")
        XCTAssertEqual(store.getSnapshotHash("sr-2"), "h2")
    }

    func testDoesNotPullAssignmentsWhenLocked() async throws {
        let store = VolatileAssignmentStore()
        var called = false
        let result = try await refreshFieldSession(
            statusSource: FakeSessionStatusSource(status: CLOCKED_OUT),
            assignmentSource: FakeAssignmentSource(getAssignmentsFn: {
                called = true
                return self.ASSIGNMENTS
            }),
            store: store
        )
        XCTAssertEqual(result.gate, .locked(reason: .notClockedIn, detail: nil))
        XCTAssertEqual(result.assignments, .notPulled)
        XCTAssertFalse(called)
        XCTAssertEqual(store.listAssignments().count, 0)
    }

    func testReportsAssignmentsUnavailableAndKeepsThePriorCacheIfThePullFailsAfterUnlock() async throws {
        let store = VolatileAssignmentStore()
        store.putAssignments([ASSIGNMENTS[0]])
        let result = try await refreshFieldSession(
            statusSource: FakeSessionStatusSource(status: CLOCKED_IN),
            assignmentSource: FakeAssignmentSource(getAssignmentsFn: { throw HubNetworkError("offline") }),
            store: store
        )
        guard case .unlocked = result.gate else { return XCTFail("expected unlocked") }
        guard case .unavailable = result.assignments else { return XCTFail("expected unavailable") }
        XCTAssertEqual(store.listAssignments().map(\.serviceRequestId), ["sr-1"])
    }

    func testKeepsCachedRichAssignmentsWhenAMalformedRefreshIsRejected() async throws {
        let store = VolatileAssignmentStore()
        store.putAssignments([
            HubAssignment(
                serviceRequestId: "sr-1", snapshotHash: "h1", snapshot: ["srId": "sr-1"] as [String: Any],
                latestServerVersion: "h1",
                details: AssignmentDetails(
                    customer: AssignmentNamedRef(id: "cust-1", name: "ACME Oil"),
                    workflowRequirements: WorkflowRequirements(
                        clockInRequired: true, requiredSteps: [.preTripDvir, .jha])
                )
            )
        ])

        let result = try await refreshFieldSession(
            statusSource: FakeSessionStatusSource(status: CLOCKED_IN),
            assignmentSource: FakeAssignmentSource(getAssignmentsFn: {
                throw HubResponseError("assignment[0].customer is malformed")
            }),
            store: store
        )

        guard case .unlocked = result.gate else { return XCTFail("expected unlocked") }
        guard case .unavailable = result.assignments else { return XCTFail("expected unavailable") }
        let cached = store.listAssignments()
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached[0].serviceRequestId, "sr-1")
        XCTAssertEqual(cached[0].snapshotHash, "h1")
        XCTAssertEqual(cached[0].latestServerVersion, "h1")
        XCTAssertEqual(cached[0].details?.customer?.name, "ACME Oil")
    }

    // ---- VolatileAssignmentStore (explicit about durability limits) ----

    func testDeclaresItselfVolatile() {
        XCTAssertEqual(VolatileAssignmentStore().durability, .volatileMemory)
    }

    func testReplacesTheAssignmentSetOnEachSuccessfulSync() {
        let store = VolatileAssignmentStore()
        store.putAssignments(ASSIGNMENTS)
        store.putAssignments([ASSIGNMENTS[1]])
        XCTAssertEqual(store.listAssignments().map(\.serviceRequestId), ["sr-2"])
        XCTAssertNil(store.getSnapshotHash("sr-1"))
    }

    func testSurfacesWorkflowRequirementsFromRichMetadataAndLegacySnapshots() {
        let store = VolatileAssignmentStore()
        store.putAssignments([
            HubAssignment(
                serviceRequestId: "sr-rich", snapshotHash: "h-rich", snapshot: [:] as [String: Any],
                details: AssignmentDetails(
                    workflowRequirements: WorkflowRequirements(
                        clockInRequired: true, requiredSteps: [.preTripDvir, .jha])
                )
            ),
            HubAssignment(
                serviceRequestId: "sr-legacy", snapshotHash: "h-legacy",
                snapshot: [
                    "workflow_requirements": [
                        "clock_in_required": true,
                        "required_steps": ["post_trip_dvir"],
                    ] as [String: Any]
                ] as [String: Any]
            ),
        ])

        XCTAssertEqual(
            parseWorkflowRequirementsFromAssignments(store.listAssignments(), "sr-rich"),
            WorkflowRequirements(clockInRequired: true, requiredSteps: [.preTripDvir, .jha])
        )
        XCTAssertEqual(
            parseWorkflowRequirementsFromAssignments(store.listAssignments(), "sr-legacy"),
            WorkflowRequirements(clockInRequired: true, requiredSteps: [.postTripDvir])
        )
    }
}
