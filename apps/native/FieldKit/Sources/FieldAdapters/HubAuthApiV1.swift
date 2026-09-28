// Port of adapters/auth/HubAuthApiV1.ts — Hub v1 auth routes (the sign-in slice the triad
// contract deferred):
//
//   POST /api/v1/auth/login    { username, password, device_id? } -> 200 { access_token, refresh_token, token_type }
//   POST /api/v1/auth/refresh  { refresh_token, device_id? }      -> 200 (same shape)
//   POST /api/v1/auth/logout   (Authorization: Bearer ...) -> 2xx (body ignored)
//
// `device_id` is this install's stable id. OpsHub scopes the refresh-token family by device_id
// (auth_service.get_valid_refresh / revoke_device_family), so sending it isolates each install:
// without it every mobile device + office browser collapse into the shared "web" family, where one
// device's token-reuse or logout revokes the others. A configured mobile identity therefore fails
// closed when it cannot be resolved; only callers that intentionally omit the source use Hub's
// legacy "web" default.
//
// The bearer token field is `access_token` — VERIFIED live against opshub (it returns
// {access_token, refresh_token, token_type}, no expires_at; the JWT carries its own exp). We still
// accept a legacy `session_token` so a Hub that renames it back keeps working. Reading the wrong
// field would reject a perfectly good login as "malformed" and block sign-in on the device.
//
// Mapping discipline mirrors OpsHubV1Client:
//  - every call is wall-clock-bounded — a black-holed login can never hang the sign-in screen;
//  - a 2xx WITHOUT a bearer token string is `.transient`, never "signed in";
//  - 401/403 -> invalid-credentials; 429/5xx/network/malformed -> transient. As data, not throws.
import Foundation
import FieldDomain

private enum Routes {
    static let login = "/api/v1/auth/login"
    static let refresh = "/api/v1/auth/refresh"
    static let logout = "/api/v1/auth/logout"
    static let me = "/api/v1/me"
}

public struct HubAuthDeviceIdentityError: Error, LocalizedError, Equatable {
    public var errorDescription: String? {
        "This phone's secure device identity is unavailable."
    }
}

public final class HubAuthApiV1: AuthApi, Sendable {
    private let baseUrl: String
    private let fetchFn: HubFetch
    private let timeoutMs: Int
    private let deviceIdSource: (@Sendable () throws -> String?)?

    public init(
        _ baseUrl: String,
        _ fetchFn: HubFetch? = nil,
        timeoutMs: Int = 15_000,
        deviceId: (@Sendable () throws -> String?)? = nil
    ) {
        self.baseUrl = baseUrl
        self.fetchFn = fetchFn ?? urlSessionHubFetch
        self.timeoutMs = timeoutMs
        self.deviceIdSource = deviceId
    }

    /// Resolve this install's `device_id`. Lazy so the device-identity store needn't be ready at
    /// construction. Once a source is configured, missing/blank identity fails closed rather than
    /// collapsing this phone into Hub's shared "web" refresh-token family.
    private func resolveDeviceId() throws -> String? {
        guard let deviceIdSource else { return nil }
        guard let value = try deviceIdSource(), !value.isEmpty else {
            throw HubAuthDeviceIdentityError()
        }
        return value
    }

    private func deviceIdField() throws -> [String: String] {
        guard let deviceId = try resolveDeviceId() else { return [:] }
        return ["device_id": deviceId]
    }

    private func boundedPost(_ path: String, _ body: [String: Any], _ extraHeaders: [String: String] = [:]) async throws
        -> HubHttpResponse
    {
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        for (k, v) in extraHeaders { headers[k] = v }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await boundedFetch(
            fetchFn, "\(baseUrl)\(path)", HubFetchInit(method: "POST", headers: headers, body: data),
            timeoutMs: timeoutMs)
    }

    private func boundedGet(_ path: String, _ extraHeaders: [String: String] = [:]) async throws -> HubHttpResponse {
        var headers = ["Accept": "application/json"]
        for (k, v) in extraHeaders { headers[k] = v }
        return try await boundedFetch(
            fetchFn, "\(baseUrl)\(path)", HubFetchInit(method: "GET", headers: headers), timeoutMs: timeoutMs)
    }

    private func fetchUserProfile(_ sessionToken: String) async -> UserProfile? {
        do {
            let response = try await boundedGet(Routes.me, ["Authorization": "Bearer \(sessionToken)"])
            guard response.ok else { return nil }
            return Self.parseUserProfile(response.json())
        } catch {
            // Profile display must not block auth. The app can still use the token and show an
            // honest "not provided" fallback until Hub/profile is reachable.
            return nil
        }
    }

    private func sessionCall(_ path: String, _ body: [String: Any]) async -> AuthApiResult {
        let response: HubHttpResponse
        do {
            response = try await boundedPost(path, body)
        } catch {
            return .transient(reason: .network, detail: "\(error)")
        }
        let rec = (response.json() as? [String: Any]) ?? [:]
        let detail = Self.optionalString(rec["detail"])

        if response.ok {
            // Live opshub returns `access_token`; a legacy Hub may use `session_token`. Accept either.
            guard
                let sessionToken = Self.optionalString(rec["access_token"]) ?? Self.optionalString(rec["session_token"])
            else {
                // 2xx without a bearer token: captive portal / proxy garbage. Never "signed in".
                return .transient(reason: .malformedResponse, detail: "2xx response without an access_token")
            }
            var session = AuthSession(
                sessionToken: sessionToken,
                expiresAt: Self.optionalString(rec["expires_at"]),
                refreshToken: Self.optionalString(rec["refresh_token"])
            )
            if let userProfile = await fetchUserProfile(sessionToken) {
                session.userProfile = userProfile
            }
            return .authenticated(session: session)
        }
        if response.status == 401 || response.status == 403 {
            return .invalidCredentials(httpStatus: response.status, detail: detail)
        }
        return .transient(
            reason: response.status == 429 || response.status >= 500 ? .server : .malformedResponse, detail: detail)
    }

    public func login(_ credentials: AuthCredentials) async throws -> AuthApiResult {
        var body: [String: Any] = ["username": credentials.username, "password": credentials.password]
        for (k, v) in try deviceIdField() { body[k] = v }
        return await sessionCall(Routes.login, body)
    }

    public func refresh(_ refreshToken: String) async throws -> AuthApiResult {
        var body: [String: Any] = ["refresh_token": refreshToken]
        for (k, v) in try deviceIdField() { body[k] = v }
        return await sessionCall(Routes.refresh, body)
    }

    public func logout(sessionToken: String, refreshToken: String?) async throws {
        // Best-effort: the caller already cleared the local session; failures are irrelevant. The
        // Hub revokes this install's refresh-token family by (refresh_token, device_id) and
        // ignores the bearer — without a refresh token there is nothing to revoke, so skip the
        // round-trip rather than POST a guaranteed-422 empty body.
        guard let refreshToken, !refreshToken.isEmpty else { return }
        var body: [String: Any] = ["refresh_token": refreshToken]
        for (k, v) in try deviceIdField() { body[k] = v }
        do {
            _ = try await boundedPost(Routes.logout, body, ["Authorization": "Bearer \(sessionToken)"])
        } catch {
            // Offline sign-out is still a sign-out.
        }
    }
}

private extension HubAuthApiV1 {
    static func optionalString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    static func pickString(_ rec: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let s = optionalString(rec[key]) { return s }
        }
        return nil
    }

    static func pickBool(_ rec: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let b = rec[key] as? Bool { return b }
        }
        return nil
    }

    static func optionalStringList(_ value: Any?) -> [String]? {
        guard let arr = value as? [Any] else { return nil }
        let strings = arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    static func parseUserProfile(_ value: Any?) -> UserProfile? {
        guard let rec = value as? [String: Any] else { return nil }
        let profile = UserProfile(
            id: pickString(rec, "id"),
            username: pickString(rec, "username"),
            email: pickString(rec, "email"),
            displayName: pickString(rec, "display_name", "displayName"),
            title: pickString(rec, "title"),
            department: pickString(rec, "department"),
            isActive: pickBool(rec, "is_active", "isActive"),
            employeeId: pickString(rec, "employee_id", "employeeId"),
            phone: pickString(rec, "phone"),
            assignedYard: pickString(rec, "assigned_yard", "assignedYard"),
            defaultTruck: pickString(rec, "default_truck", "defaultTruck"),
            defaultTrailer: pickString(rec, "default_trailer", "defaultTrailer"),
            accessProfile: pickString(rec, "access_profile", "accessProfile"),
            roles: optionalStringList(rec["roles"]),
            language: pickString(rec, "language")
        )
        let isEmpty =
            profile.id == nil && profile.username == nil && profile.email == nil
            && profile.displayName == nil && profile.title == nil && profile.department == nil
            && profile.isActive == nil && profile.employeeId == nil && profile.phone == nil
            && profile.assignedYard == nil && profile.defaultTruck == nil && profile.defaultTrailer == nil
            && profile.accessProfile == nil && profile.roles == nil && profile.language == nil
        return isEmpty ? nil : profile
    }
}
