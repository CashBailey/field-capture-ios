import Foundation
import FieldContracts
// Port of __tests__/auth.test.ts (domain parts only — the `HubAuthApiV1` wire-mapping describe
// block lives in FieldAdapters, out of scope for this port). Session auth slice (spec req 8):
// login flow, token storage, refresh/expiry, logout — every path resolves to a typed state, and
// signing out never destroys unsynced work.
import XCTest

@testable import FieldDomain

private final class FakeTokenStore: TokenStore {
    let durability: StoreDurability = .volatileMemory
    var session: AuthSession?
    var beforeReplace: (() -> Void)?
    func load() async throws -> AuthSession? { session }
    func save(_ session: AuthSession) async throws { self.session = session }
    func clear() async throws { session = nil }
    func replace(_ expected: AuthSession?, with replacement: AuthSession?) async throws -> Bool {
        let hook = beforeReplace
        beforeReplace = nil
        hook?()
        guard session == expected else { return false }
        session = replacement
        return true
    }
}

private final class FakeAuthApi: AuthApi {
    var loginHandler: () async throws -> AuthApiResult
    var refreshHandler: () async throws -> AuthApiResult
    var logoutHandler: (String, String?) async throws -> Void
    private(set) var logoutCalls: [String] = []

    init(
        login: @escaping () async throws -> AuthApiResult = { .transient(reason: .network, detail: nil) },
        refresh: @escaping () async throws -> AuthApiResult = { .transient(reason: .network, detail: nil) },
        logout: @escaping (String, String?) async throws -> Void = { _, _ in }
    ) {
        loginHandler = login
        refreshHandler = refresh
        logoutHandler = logout
    }

    func login(_ credentials: AuthCredentials) async throws -> AuthApiResult { try await loginHandler() }
    func refresh(_ refreshToken: String) async throws -> AuthApiResult { try await refreshHandler() }
    func logout(sessionToken: String, refreshToken: String?) async throws {
        logoutCalls.append(sessionToken)
        try await logoutHandler(sessionToken, refreshToken)
    }
}

private func isoDate(_ s: String) -> Date {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFractional.date(from: s) { return d }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: s)!
}

private func jwtWithExp(_ expSeconds: Int) -> String {
    func b64url(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(["alg": "HS256", "typ": "JWT"])).\(b64url(["exp": expSeconds])).sig"
}

final class AuthTests: XCTestCase {
    private let SESSION = AuthSession(sessionToken: "tok-1")
    private let NOW: () -> Date = { isoDate("2026-06-10T19:00:00.000Z") }

    // ---- login ----

    func testStoresTheSessionOnlyWhenHubExplicitlyAuthenticates() async throws {
        let tokenStore = FakeTokenStore()
        let result = try await login(
            AuthDeps(api: FakeAuthApi(login: { .authenticated(session: self.SESSION) }), tokenStore: tokenStore),
            credentials: AuthCredentials(username: "driver", password: "pw")
        )
        XCTAssertEqual(result, .signedIn)
        XCTAssertEqual(tokenStore.session, SESSION)
    }

    func testMapsInvalidCredentialsAndTransientFailuresToStatesNoThrowNoTokenStored() async throws {
        let tokenStore = FakeTokenStore()
        let bad = try await login(
            AuthDeps(
                api: FakeAuthApi(login: { .invalidCredentials(httpStatus: 401, detail: "nope") }),
                tokenStore: tokenStore),
            credentials: AuthCredentials(username: "driver", password: "wrong")
        )
        XCTAssertEqual(bad, .invalidCredentials(detail: "nope"))
        let offline = try await login(
            AuthDeps(api: FakeAuthApi(), tokenStore: tokenStore),
            credentials: AuthCredentials(username: "driver", password: "pw")
        )
        guard case .unavailable = offline else { return XCTFail("expected unavailable") }
        XCTAssertNil(tokenStore.session)
    }

    // ---- getValidSession (expiry + refresh discipline) ----

    func testReturnsTheStoredSessionWhileItIsFresh() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "tok", expiresAt: "2026-06-10T20:00:00.000Z")
        let state = try await getValidSession(AuthDeps(api: FakeAuthApi(), tokenStore: tokenStore, now: NOW))
        XCTAssertEqual(state, .valid(session: tokenStore.session!))
    }

    func testRequiresReAuthWhenThereIsNoSession() async throws {
        let state = try await getValidSession(AuthDeps(api: FakeAuthApi(), tokenStore: FakeTokenStore(), now: NOW))
        XCTAssertEqual(state, .authRequired(reason: .noSession))
    }

    func testRefreshesAnExpiringSessionAndStoresTheNewOne() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T19:00:30.000Z", refreshToken: "refresh-1"
        )
        let fresh = AuthSession(sessionToken: "new", expiresAt: "2026-06-10T23:00:00.000Z")
        var refreshCalledWith: String?
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    refreshCalledWith = "refresh-1"
                    return .authenticated(session: fresh)
                }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertEqual(refreshCalledWith, "refresh-1")
        XCTAssertEqual(state, .valid(session: fresh))
        XCTAssertEqual(tokenStore.session, fresh)
    }

    func testExpiredWithoutARefreshTokenAuthRequiredSessionCleared() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "old", expiresAt: "2026-06-10T18:00:00.000Z")
        let state = try await getValidSession(AuthDeps(api: FakeAuthApi(), tokenStore: tokenStore, now: NOW))
        XCTAssertEqual(state, .authRequired(reason: .expired))
        XCTAssertNil(tokenStore.session)
    }

    func testExpiredWithoutARefreshTokenDoesNotClearANewerLogin() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "old", expiresAt: "2026-06-10T18:00:00.000Z")
        let fresh = AuthSession(sessionToken: "fresh-from-login")
        tokenStore.beforeReplace = { tokenStore.session = fresh }

        let state = try await getValidSession(AuthDeps(api: FakeAuthApi(), tokenStore: tokenStore, now: NOW))

        XCTAssertEqual(state, .valid(session: fresh))
        XCTAssertEqual(tokenStore.session, fresh)
    }

    func testRejectedRefreshAuthRequiredOfflineRefreshUnavailable() async throws {
        let tokenStore = FakeTokenStore()
        let expiring = AuthSession(sessionToken: "old", expiresAt: "2026-06-10T19:00:30.000Z", refreshToken: "r")
        tokenStore.session = expiring
        let rejected = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: { .invalidCredentials(httpStatus: 401, detail: nil) }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertEqual(rejected, .authRequired(reason: .refreshRejected))
        XCTAssertNil(tokenStore.session)

        tokenStore.session = expiring
        let offline = try await getValidSession(AuthDeps(api: FakeAuthApi(), tokenStore: tokenStore, now: NOW))
        guard case .unavailable = offline else { return XCTFail("expected unavailable") }
        XCTAssertEqual(tokenStore.session, expiring)  // kept — retry refresh later
    }

    func testAStaleRefreshRejectionNeverClearsASessionThatWasReplacedMidFlight() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "old", expiresAt: "2026-06-10T19:00:30.000Z", refreshToken: "r")
        let fresh = AuthSession(sessionToken: "fresh-from-login")
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    // a login lands while this refresh is in flight…
                    tokenStore.session = fresh
                    // …then the (now-irrelevant) refresh comes back rejected
                    return .invalidCredentials(httpStatus: 401, detail: nil)
                }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertEqual(state, .valid(session: fresh))
        XCTAssertEqual(tokenStore.session, fresh)  // the fresh session was NOT wiped
    }

    func testAStaleSuccessfulRefreshNeverOverwritesANewerLogin() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T19:00:30.000Z", refreshToken: "r")
        let freshLogin = AuthSession(sessionToken: "fresh-from-login")
        let staleRefresh = AuthSession(sessionToken: "stale-refresh-result")

        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    tokenStore.session = freshLogin
                    return .authenticated(session: staleRefresh)
                }),
                tokenStore: tokenStore,
                now: NOW
            ))

        XCTAssertEqual(state, .valid(session: freshLogin))
        XCTAssertEqual(tokenStore.session, freshLogin)
    }

    func testAStaleSuccessfulRefreshNeverResurrectsALoggedOutSession() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(
            sessionToken: "old", expiresAt: "2026-06-10T19:00:30.000Z", refreshToken: "r")

        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    tokenStore.session = nil
                    return .authenticated(session: AuthSession(sessionToken: "stale-refresh-result"))
                }),
                tokenStore: tokenStore,
                now: NOW
            ))

        XCTAssertEqual(state, .authRequired(reason: .noSession))
        XCTAssertNil(tokenStore.session)
    }

    func testTreatsAnUnparseableExpiryAsExpiringNow() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "old", expiresAt: "garbage", refreshToken: "r")
        let fresh = AuthSession(sessionToken: "new")
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: { .authenticated(session: fresh) }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertEqual(state, .valid(session: fresh))
    }

    // ---- getValidSession (proactive refresh from JWT exp when Hub omits expiresAt) ----

    func testRefreshesProactivelyWhenTheJwtExpIsInsideTheMargin() async throws {
        let nowMs = Int(NOW().timeIntervalSince1970)
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: jwtWithExp(nowMs + 30), refreshToken: "r")
        let fresh = AuthSession(sessionToken: "new")
        var refreshCalledWith: String?
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    refreshCalledWith = "r"
                    return .authenticated(session: fresh)
                }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertEqual(refreshCalledWith, "r")
        XCTAssertEqual(state, .valid(session: fresh))
    }

    func testTreatsAJwtWithAFarFutureExpAsFreshNoRefresh() async throws {
        let nowMs = Int(NOW().timeIntervalSince1970)
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: jwtWithExp(nowMs + 3600), refreshToken: "r")
        var refreshCalled = false
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    refreshCalled = true
                    return .transient(reason: .network, detail: nil)
                }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertFalse(refreshCalled)
        XCTAssertEqual(state, .valid(session: tokenStore.session!))
    }

    func testAnOpaqueNonJwtTokenWithNoExpiresAtStaysNonExpiring() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "opaque-not-a-jwt", refreshToken: "r")
        var refreshCalled = false
        let state = try await getValidSession(
            AuthDeps(
                api: FakeAuthApi(refresh: {
                    refreshCalled = true
                    return .transient(reason: .network, detail: nil)
                }),
                tokenStore: tokenStore, now: NOW
            ))
        XCTAssertFalse(refreshCalled)
        XCTAssertEqual(state, .valid(session: tokenStore.session!))
    }

    // ---- logout ----

    func testClearsTheLocalSessionBestEffortInvalidatesServerSideAndPreservesEvidence() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = SESSION
        let evidenceStore = VolatileTicketEvidenceStore()
        evidenceStore.save(
            TicketEvidence(
                envelope: OperationEnvelope(
                    opId: "op-1", kind: .command, type: "ticket.submit", idempotencyKey: "gtr:dev:0:op-1",
                    localSeq: 0, dependsOn: [],
                    payload: HubFieldTicketSubmission(
                        idempotencyKey: "gtr:dev:0:op-1", serviceRequestId: "sr-1", snapshotHash: "h1",
                        ticketNo: "T-1", quantityBbl: 5, disposalTicketNo: "D-1"
                    )
                ),
                state: .pending, attempts: 1, createdAt: "2026-06-10T18:00:00.000Z",
                updatedAt: "2026-06-10T18:00:00.000Z"
            ))

        let theApi = FakeAuthApi()
        try await logout(AuthDeps(api: theApi, tokenStore: tokenStore))
        XCTAssertNil(tokenStore.session)
        XCTAssertEqual(theApi.logoutCalls, ["tok-1"])
        XCTAssertEqual(evidenceStore.list().count, 1)  // unsynced work survives sign-out

        // a failing server-side logout never blocks the local sign-out
        tokenStore.session = SESSION
        try await logout(
            AuthDeps(
                api: FakeAuthApi(logout: { _, _ in throw HubNetworkError("offline") }),
                tokenStore: tokenStore
            ))
        XCTAssertNil(tokenStore.session)
    }

    func testPassesTheRefreshTokenThroughSoTheHubCanRevokeThisDeviceFamily() async throws {
        let tokenStore = FakeTokenStore()
        tokenStore.session = AuthSession(sessionToken: "tok-1", refreshToken: "refresh-9")
        var calledWith: (String, String?)?
        try await logout(
            AuthDeps(
                api: FakeAuthApi(logout: { token, refresh in calledWith = (token, refresh) }),
                tokenStore: tokenStore
            ))
        XCTAssertEqual(calledWith?.0, "tok-1")
        XCTAssertEqual(calledWith?.1, "refresh-9")
        XCTAssertNil(tokenStore.session)
    }

    func testLogoutDoesNotClearANewerLoginThatLandsMidFlight() async throws {
        let tokenStore = FakeTokenStore()
        let old = AuthSession(sessionToken: "old", refreshToken: "old-refresh")
        let fresh = AuthSession(sessionToken: "fresh-from-login")
        tokenStore.session = old
        tokenStore.beforeReplace = { tokenStore.session = fresh }
        let api = FakeAuthApi()

        try await logout(AuthDeps(api: api, tokenStore: tokenStore))

        XCTAssertEqual(tokenStore.session, fresh)
        XCTAssertEqual(api.logoutCalls, [old.sessionToken])
    }
}
