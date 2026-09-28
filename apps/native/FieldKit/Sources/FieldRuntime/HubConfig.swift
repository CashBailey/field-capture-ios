// Port of src/config/hubConfig.ts — typed runtime config for the Ops Hub connection.
//
// The Hub URL is baked in at build time (OPS_HUB_URL via Info.plist/Xcode settings). The
// session token is a runtime value from the driver's sign-in. Both are REQUIRED to talk to Hub.
// A missing value throws a typed `HubConfigError` — the app must fail visibly and keep work
// local rather than guess a Hub or fake a sync.
import Foundation

public struct HubConfigError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct HubRuntimeConfig {
    /// Normalized base URL (no trailing slash), e.g. "https://hub.example.com".
    public let baseUrl: String
    /// The signed-in driver's bearer token. Hub derives the employee from it — never from the client.
    public let sessionToken: String
}

/// True for hosts iOS ATS permits over cleartext: localhost, loopback, .local mDNS, private LAN IPv4.
private func isLocalHost(_ host: String) -> Bool {
    if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
    if host.hasSuffix(".local") { return true }
    if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
    if let match = host.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression),
        match.lowerBound == host.startIndex
    {
        return true
    }
    return false
}

/// Pure resolver — validates raw values into a usable config or throws `HubConfigError`.
public func resolveHubRuntimeConfig(hubUrl: String?, sessionToken: String?) throws -> HubRuntimeConfig {
    guard let hubUrl, !hubUrl.isEmpty else {
        throw HubConfigError(
            "Ops Hub URL is not configured for this build. Set OPS_HUB_URL_<DEV|STAGING|PROD> for "
                + "the APP_ENV this build targets (see .env.example). Refusing to guess a Hub — work stays local.")
    }
    // Plain string parse, mirroring the TS resolver.
    let pattern = #"^(https?)://([^/:?\s]+)"#
    guard let match = hubUrl.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
        match.lowerBound == hubUrl.startIndex
    else {
        throw HubConfigError(
            "Ops Hub URL must be http(s)://host[...] — got \"\(hubUrl)\". Check OPS_HUB_URL_* / APP_ENV.")
    }
    let matched = String(hubUrl[match])
    guard let schemeEnd = matched.range(of: "://") else {
        throw HubConfigError("Ops Hub URL is missing its scheme separator.")
    }
    let scheme = String(matched[..<schemeEnd.lowerBound]).lowercased()
    let host = String(matched[schemeEnd.upperBound...]).lowercased()
    // Block cleartext http:// to a non-local Hub: iOS ATS (NSAllowsLocalNetworking only) silently
    // drops it AND it ships field data in the clear. http is allowed ONLY for localhost / LAN dev.
    if scheme == "http" && !isLocalHost(host) {
        throw HubConfigError(
            "Refusing cleartext http:// to a non-local Hub (\"\(host)\"): iOS App Transport Security "
                + "blocks it and it would send field data unencrypted. Use https:// for staging/prod "
                + "(http:// is permitted only for localhost or a private LAN address in dev).")
    }
    guard let sessionToken, !sessionToken.isEmpty else {
        throw HubConfigError(
            "Missing Hub session token — the driver is not signed in (or the token was lost). "
                + "Sign in again; unsynced work is preserved locally meanwhile.")
    }
    var base = hubUrl
    while base.hasSuffix("/") { base.removeLast() }
    return HubRuntimeConfig(baseUrl: base, sessionToken: sessionToken)
}
