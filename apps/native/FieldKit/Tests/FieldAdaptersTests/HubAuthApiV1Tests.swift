import FieldDomain
// Port of the "HubAuthApiV1 (wire mapping, fake fetch)" describe block from
// apps/mobile/__tests__/auth.test.ts. Wire fixtures are kept byte-exact with the TS.
import XCTest

@testable import FieldAdapters

private func respond(_ status: Int, _ body: [String: Any]? = nil) -> HubHttpResponse {
    guard let body else { return HubHttpResponse(status: status) }
    let data = try! JSONSerialization.data(withJSONObject: body)
    return HubHttpResponse(status: status, body: data)
}

final class HubAuthApiV1Tests: XCTestCase {
    func test_authenticatesOnLiveFieldhubAccessToken() async throws {
        // The exact shape verified live against opshub POST /api/v1/auth/login.
        let calls = LockedBox<[String]>([])
        let liveApi = HubAuthApiV1("https://hub.test") { url, requestInit in
            calls.mutate { $0.append("\(requestInit.method) \(url)") }
            if url.hasSuffix("/api/v1/me") {
                return respond(
                    200,
                    [
                        "id": "user-1", "username": "driver.user", "email": "driver.user@example.test",
                        "display_name": "Driver User", "title": "Driver", "department": "Operations",
                        "is_active": true, "employee_id": "emp-1", "phone": "(432) 555-0101",
                        "assigned_yard": "Midland Yard", "default_truck": "Truck 7",
                        "default_trailer": "Vacuum Trailer 19", "roles": ["driver", "end_user"],
                        "access_profile": "driver", "language": "en",
                    ])
            }
            return respond(200, ["access_token": "jwt-access", "refresh_token": "r", "token_type": "bearer"])
        }
        let result = try await liveApi.login(AuthCredentials(username: "u", password: "p"))
        XCTAssertEqual(
            result,
            .authenticated(
                session: AuthSession(
                    sessionToken: "jwt-access",
                    refreshToken: "r",
                    userProfile: UserProfile(
                        id: "user-1", username: "driver.user", email: "driver.user@example.test",
                        displayName: "Driver User", title: "Driver", department: "Operations",
                        isActive: true, employeeId: "emp-1", phone: "(432) 555-0101",
                        assignedYard: "Midland Yard", defaultTruck: "Truck 7", defaultTrailer: "Vacuum Trailer 19",
                        accessProfile: "driver", roles: ["driver", "end_user"], language: "en"
                    )
                )))
        XCTAssertEqual(calls.value, ["POST https://hub.test/api/v1/auth/login", "GET https://hub.test/api/v1/me"])
    }

    func test_omitsNullOptionalProfileFields() async throws {
        let apiV1 = HubAuthApiV1("https://hub.test") { url, _ in
            if url.hasSuffix("/api/v1/me") {
                return respond(
                    200,
                    [
                        "display_name": "Driver User", "employee_id": "emp-1",
                        "assigned_yard": NSNull(), "default_truck": NSNull(), "default_trailer": NSNull(),
                    ])
            }
            return respond(200, ["access_token": "jwt-access", "refresh_token": "r", "token_type": "bearer"])
        }
        let result = try await apiV1.login(AuthCredentials(username: "u", password: "p"))
        XCTAssertEqual(
            result,
            .authenticated(
                session: AuthSession(
                    sessionToken: "jwt-access", refreshToken: "r",
                    userProfile: UserProfile(displayName: "Driver User", employeeId: "emp-1")
                )))
    }

    func test_keepsAuthSuccessfulWhenProfileEndpointUnavailable() async throws {
        let apiV1 = HubAuthApiV1("https://hub.test") { url, _ in
            if url.hasSuffix("/api/v1/me") { return respond(503) }
            return respond(200, ["access_token": "jwt-access", "refresh_token": "r", "token_type": "bearer"])
        }
        let result = try await apiV1.login(AuthCredentials(username: "u", password: "p"))
        XCTAssertEqual(result, .authenticated(session: AuthSession(sessionToken: "jwt-access", refreshToken: "r")))
    }

    func test_legacySessionTokenAndBare2xxTransient() async throws {
        let legacyApi = HubAuthApiV1("https://hub.test") { _, _ in
            respond(200, ["session_token": "tok", "expires_at": "2026-06-11T00:00:00Z", "refresh_token": "r"])
        }
        let result = try await legacyApi.login(AuthCredentials(username: "u", password: "p"))
        XCTAssertEqual(
            result,
            .authenticated(
                session: AuthSession(sessionToken: "tok", expiresAt: "2026-06-11T00:00:00Z", refreshToken: "r")))

        let portalApi = HubAuthApiV1("https://hub.test") { _, _ in respond(200, ["welcome": "to the coffee shop wifi"])
        }
        let portalResult = try await portalApi.login(AuthCredentials(username: "u", password: "p"))
        guard case .transient(let reason, _) = portalResult else {
            return XCTFail("expected transient, got \(portalResult)")
        }
        XCTAssertEqual(reason, .malformedResponse)
    }

    func test_mapsStatusesToOutcomes() async throws {
        let denied = HubAuthApiV1("https://hub.test") { _, _ in respond(401, ["detail": "bad password"]) }
        let deniedResult = try await denied.login(AuthCredentials(username: "u", password: "x"))
        XCTAssertEqual(deniedResult, .invalidCredentials(httpStatus: 401, detail: "bad password"))

        let down = HubAuthApiV1("https://hub.test") { _, _ in respond(503) }
        let downResult = try await down.refresh("r")
        guard case .transient(let reason, _) = downResult else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .server)

        let offline = HubAuthApiV1("https://hub.test") { _, _ in throw URLError(.networkConnectionLost) }
        let offlineResult = try await offline.login(AuthCredentials(username: "u", password: "p"))
        guard case .transient(let reason, _) = offlineResult else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .network)
    }

    func test_neverHangsBlackHoledLoginResolvesTransientAtTimeout() async throws {
        let blackHole = HubAuthApiV1(
            "https://hub.test",
            { _, _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return respond(200)
            }, timeoutMs: 20)
        let result = try await blackHole.login(AuthCredentials(username: "u", password: "p"))
        guard case .transient(let reason, _) = result else { return XCTFail("expected transient") }
        XCTAssertEqual(reason, .network)
    }

    func test_logoutNeverThrowsEvenOffline() async throws {
        let offline = HubAuthApiV1("https://hub.test") { _, _ in throw URLError(.networkConnectionLost) }
        // A refresh token is present, so the round-trip is attempted (and fails) — sign-out still resolves.
        try await offline.logout(sessionToken: "tok", refreshToken: "refresh-1")
    }

    func test_logoutPostsRefreshTokenAndDeviceId() async throws {
        let calls = LockedBox<[(url: String, body: [String: Any])]>([])
        let apiV1 = HubAuthApiV1(
            "https://hub.test",
            { url, requestInit in
                let body =
                    requestInit.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                calls.mutate { $0.append((url, body)) }
                return respond(200, ["status": "ok"])
            }, deviceId: { "install-123" })
        try await apiV1.logout(sessionToken: "access-tok", refreshToken: "refresh-9")
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertEqual(calls.value[0].url, "https://hub.test/api/v1/auth/logout")
        XCTAssertEqual(calls.value[0].body["refresh_token"] as? String, "refresh-9")
        XCTAssertEqual(calls.value[0].body["device_id"] as? String, "install-123")
    }

    func test_logoutWithNoRefreshTokenMakesNoNetworkCall() async throws {
        let called = LockedBox<Bool>(false)
        let apiV1 = HubAuthApiV1(
            "https://hub.test",
            { _, _ in
                called.mutate { $0 = true }
                return respond(200, ["status": "ok"])
            }, deviceId: { "install-123" })
        try await apiV1.logout(sessionToken: "access-tok", refreshToken: nil)
        XCTAssertFalse(called.value)
    }

    func test_sendsDeviceIdOnLoginAndRefresh() async throws {
        let bodies = LockedBox<[[String: Any]]>([])
        let withDevice = HubAuthApiV1(
            "https://hub.test",
            { _, requestInit in
                if requestInit.method == "POST" {
                    let body =
                        requestInit.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        ?? [:]
                    bodies.mutate { $0.append(body) }
                }
                return respond(200, ["access_token": "a", "refresh_token": "r", "token_type": "bearer"])
            }, deviceId: { "install-123" })
        _ = try await withDevice.login(AuthCredentials(username: "u", password: "p"))
        _ = try await withDevice.refresh("r")
        XCTAssertEqual(bodies.value[0]["username"] as? String, "u")
        XCTAssertEqual(bodies.value[0]["device_id"] as? String, "install-123")
        XCTAssertEqual(bodies.value[1]["refresh_token"] as? String, "r")
        XCTAssertEqual(bodies.value[1]["device_id"] as? String, "install-123")
    }

    func test_configuredDeviceIdentityFailsClosedButAnIntentionallyAbsentSourceRemainsCompatible() async throws {
        let bodies = LockedBox<[[String: Any]]>([])
        let capture: HubFetch = { _, requestInit in
            if requestInit.method == "POST" {
                let body =
                    requestInit.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                bodies.mutate { $0.append(body) }
            }
            return respond(200, ["access_token": "a", "token_type": "bearer"])
        }
        // A configured mobile resolver must never degrade into Hub's shared "web" token family.
        let thrower = HubAuthApiV1("https://hub.test", capture, deviceId: { throw URLError(.unknown) })
        do {
            _ = try await thrower.login(AuthCredentials(username: "u", password: "p"))
            XCTFail("expected device identity failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .unknown)
        }
        XCTAssertTrue(bodies.value.isEmpty)

        let blank = HubAuthApiV1("https://hub.test", capture, deviceId: { "" })
        do {
            _ = try await blank.refresh("refresh")
            XCTFail("expected blank device identity failure")
        } catch {
            XCTAssertTrue(error is HubAuthDeviceIdentityError)
        }
        XCTAssertTrue(bodies.value.isEmpty)

        // No deviceId configured → omitted entirely (backward compatible with the office-web default).
        let none = HubAuthApiV1("https://hub.test", capture)
        _ = try await none.login(AuthCredentials(username: "u", password: "p"))
        XCTAssertNil(bodies.value[0]["device_id"])
    }
}

/// Tiny lock-guarded box so async-closure test fakes can record calls without data races.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&_value)
    }
}
