// Port of src/domain/auth.ts — Session auth slice: login, secure token storage, expiry/refresh
// handling, logout.
//
// Hub derives the employee from the bearer token — Mobile only carries the token (contract
// boundary). The rules here:
//  - Every auth operation resolves to a typed STATE, never an unhandled throw and never a hang
//    (the API adapter is time-bounded).
//  - An expired/expiring token is refreshed when a refresh token exists; otherwise the caller
//    gets `.authRequired` and must re-login. Nothing ever "probably authenticated".
//  - Logout clears the token ONLY. Unsynced evidence is preserved — signing out must never
//    destroy field work (the durable store keeps it for the next sign-in).
import Foundation

public struct AuthSession: Equatable, Sendable {
    public var sessionToken: String
    /// ISO 8601 expiry as Hub reported it; absent = Hub did not say (treated as non-expiring).
    public var expiresAt: String?
    public var refreshToken: String?
    public var userProfile: UserProfile?

    public init(
        sessionToken: String,
        expiresAt: String? = nil,
        refreshToken: String? = nil,
        userProfile: UserProfile? = nil
    ) {
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.userProfile = userProfile
    }
}

/// Hub-authenticated user profile returned by `GET /api/v1/me`.
public struct UserProfile: Equatable, Sendable {
    public var id: String?
    public var username: String?
    public var email: String?
    public var displayName: String?
    public var title: String?
    public var department: String?
    public var isActive: Bool?
    public var employeeId: String?
    public var phone: String?
    public var assignedYard: String?
    public var defaultTruck: String?
    public var defaultTrailer: String?
    public var accessProfile: String?
    public var roles: [String]?
    public var language: String?

    public init(
        id: String? = nil,
        username: String? = nil,
        email: String? = nil,
        displayName: String? = nil,
        title: String? = nil,
        department: String? = nil,
        isActive: Bool? = nil,
        employeeId: String? = nil,
        phone: String? = nil,
        assignedYard: String? = nil,
        defaultTruck: String? = nil,
        defaultTrailer: String? = nil,
        accessProfile: String? = nil,
        roles: [String]? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.title = title
        self.department = department
        self.isActive = isActive
        self.employeeId = employeeId
        self.phone = phone
        self.assignedYard = assignedYard
        self.defaultTruck = defaultTruck
        self.defaultTrailer = defaultTrailer
        self.accessProfile = accessProfile
        self.roles = roles
        self.language = language
    }
}

/// Where the session lives between launches. The real one is the device keychain.
public protocol TokenStore {
    var durability: StoreDurability { get }
    func load() async throws -> AuthSession?
    func save(_ session: AuthSession) async throws
    func clear() async throws
    /// Replace exactly the session the caller previously read. Durable stores with concurrent
    /// writers should override this atomically; the default preserves compatibility for simple
    /// single-threaded and test stores.
    func replace(_ expected: AuthSession?, with replacement: AuthSession?) async throws -> Bool
}

public extension TokenStore {
    func replace(_ expected: AuthSession?, with replacement: AuthSession?) async throws -> Bool {
        guard try await load() == expected else { return false }
        if let replacement {
            try await save(replacement)
        } else {
            try await clear()
        }
        return true
    }
}

/// The credentials a login attempt carries — mirrors the inline TS object type shared by
/// `AuthApi.login` and the domain `login` function.
public struct AuthCredentials: Equatable, Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Every expected Hub answer as data; only `.authenticated` yields a usable session.
public enum AuthApiResult: Equatable, Sendable {
    public enum TransientReason: String, Equatable, Sendable {
        case network
        case server
        case malformedResponse = "malformed-response"
    }

    case authenticated(session: AuthSession)
    case invalidCredentials(httpStatus: Int, detail: String?)
    case transient(reason: TransientReason, detail: String?)
}

public protocol AuthApi {
    func login(_ credentials: AuthCredentials) async throws -> AuthApiResult
    func refresh(_ refreshToken: String) async throws -> AuthApiResult
    /// Best-effort server-side invalidation. The Hub revokes the refresh-token family keyed on
    /// the refresh token (not the access token), so it is passed through when present; the local
    /// clear happens regardless of the outcome.
    func logout(sessionToken: String, refreshToken: String?) async throws
}

public struct AuthDeps {
    public var api: AuthApi
    public var tokenStore: TokenStore
    public var now: (() -> Date)?

    public init(api: AuthApi, tokenStore: TokenStore, now: (() -> Date)? = nil) {
        self.api = api
        self.tokenStore = tokenStore
        self.now = now
    }
}

public enum LoginResult: Equatable, Sendable {
    case signedIn
    case invalidCredentials(detail: String?)
    case unavailable(reason: String)
}

public func login(_ deps: AuthDeps, credentials: AuthCredentials) async throws -> LoginResult {
    let result = try await deps.api.login(credentials)
    switch result {
    case .authenticated(let session):
        try await deps.tokenStore.save(session)
        return .signedIn
    case .invalidCredentials(_, let detail):
        return .invalidCredentials(detail: detail)
    case .transient(let reason, let detail):
        return .unavailable(reason: detail ?? reason.rawValue)
    }
}

/// Clear the local session. Unsynced evidence is NOT touched — work survives a sign-out.
public func logout(_ deps: AuthDeps) async throws {
    let session = try await deps.tokenStore.load()
    if let session {
        // Do not erase a new login that lands after this logout started.
        _ = try await deps.tokenStore.replace(session, with: nil)
    }
    if let session {
        do {
            try await deps.api.logout(sessionToken: session.sessionToken, refreshToken: session.refreshToken)
        } catch {
            // Server-side invalidation is best-effort; the local session is already gone and the
            // token expires server-side anyway. Never block a sign-out on the network.
        }
    }
}

public enum SessionState: Equatable, Sendable {
    public enum AuthRequiredReason: String, Equatable, Sendable {
        case noSession = "no-session"
        case expired
        case refreshRejected = "refresh-rejected"
    }

    case valid(session: AuthSession)
    case authRequired(reason: AuthRequiredReason)
    /// A session exists but could not be refreshed right now (offline/5xx); not signed out.
    case unavailable(reason: String)
}

/// Refresh when the token expires within this margin — a token that dies mid-submit is a 401.
private let EXPIRY_MARGIN_MS: Double = 60_000

/// Best-effort ISO-8601 parse (mirrors JS `Date.parse`'s tolerance for both fractional-second and
/// whole-second `Z`-suffixed timestamps). Returns epoch ms, or nil if unparseable.
private func parseIso8601Ms(_ value: String) -> Double? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) { return date.timeIntervalSince1970 * 1000 }

    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    if let date = whole.date(from: value) { return date.timeIntervalSince1970 * 1000 }

    return nil
}

/**
 * Decode the `exp` claim (epoch ms) from a JWT access token, or nil if it is not a JWT / has no
 * numeric `exp`. The Hub does not return an explicit `expires_at`, so this is how a session learns
 * its own expiry and can refresh PROACTIVELY instead of only after a 401.
 */
private func decodeJwtExpMs(_ token: String) -> Double? {
    let parts = token.components(separatedBy: ".")
    guard parts.count == 3 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = b64.count % 4
    if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: b64) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data),
        let claims = obj as? [String: Any],
        let expRaw = claims["exp"], !(expRaw is Bool),
        let expNumber = expRaw as? NSNumber,
        expNumber.doubleValue.isFinite
    else { return nil }
    return expNumber.doubleValue * 1000
}

/// Effective expiry (epoch ms): Hub's explicit `expiresAt` if present, else the JWT `exp` claim.
/// nil = no expiry information at all (treated as non-expiring). `Double.nan` = an unparseable
/// explicit expiry (treated as expiring NOW) — mirroring `Date.parse`'s `NaN` sentinel in the TS.
private func sessionExpiryMs(_ session: AuthSession) -> Double? {
    if let expiresAt = session.expiresAt {
        return parseIso8601Ms(expiresAt) ?? Double.nan
    }
    return decodeJwtExpMs(session.sessionToken)
}

private func isExpiring(_ session: AuthSession, nowMs: Double) -> Bool {
    guard let expiresMs = sessionExpiryMs(session) else { return false }
    if expiresMs.isNaN { return true }
    return expiresMs - nowMs <= EXPIRY_MARGIN_MS
}

/**
 * The session to use for Hub calls right now: stored & fresh → valid; expiring with a refresh
 * token → refreshed (and re-stored); otherwise auth-required. Offline during refresh keeps the
 * old session out of use (`.unavailable`) rather than guessing.
 */
public func getValidSession(_ deps: AuthDeps) async throws -> SessionState {
    let nowMs = ((deps.now ?? { Date() })()).timeIntervalSince1970 * 1000
    guard let session = try await deps.tokenStore.load() else {
        return .authRequired(reason: .noSession)
    }
    if !isExpiring(session, nowMs: nowMs) {
        return .valid(session: session)
    }
    guard let refreshToken = session.refreshToken else {
        if try await deps.tokenStore.replace(session, with: nil) {
            return .authRequired(reason: .expired)
        }
        return try await stateAfterStaleAuthOperation(deps.tokenStore)
    }
    let result = try await deps.api.refresh(refreshToken)
    switch result {
    case .authenticated(let newSession):
        // A login, logout, or newer refresh may have replaced this session while the request was
        // in flight. Never let the stale response overwrite that newer decision (or resurrect a
        // session after sign-out).
        guard try await deps.tokenStore.replace(session, with: newSession) else {
            return try await stateAfterStaleAuthOperation(deps.tokenStore)
        }
        return .valid(session: newSession)
    case .invalidCredentials:
        // The refresh token itself was rejected — that session is dead. Clear it ONLY if it is
        // still the stored one: a login/refresh that landed while this call was in flight must
        // not have its fresh session wiped by a stale rejection.
        if try await deps.tokenStore.replace(session, with: nil) {
            return .authRequired(reason: .refreshRejected)
        }
        return try await stateAfterStaleAuthOperation(deps.tokenStore)
    case .transient(let reason, let detail):
        return .unavailable(reason: detail ?? reason.rawValue)
    }
}

private func stateAfterStaleAuthOperation(_ tokenStore: TokenStore) async throws -> SessionState {
    if let current = try await tokenStore.load() {
        return .valid(session: current)
    }
    return .authRequired(reason: .noSession)
}
