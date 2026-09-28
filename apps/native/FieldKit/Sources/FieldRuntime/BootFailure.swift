// Port of src/runtime/bootFailure.ts — Boot-failure classification (Phase 2). When startup throws,
// the app must tell the worker WHICH kind of failure it was and — critically — must NEVER
// auto-wipe local data. Only a database KEY mismatch (the key in the keychain no longer opens the
// encrypted store) may offer a destructive local reset, and only behind an explicit confirm. A
// missing Hub URL (`HubConfigError`) or any other database/unknown error keeps the local data
// untouched and offers no reset.
//
// Pure + typed so the rule is unit-tested; the App target is a thin consumer in the PRE-nav boot
// gate.
import Foundation
import FieldData

public enum BootFailureReason: String, Equatable, Sendable {
    case hubConfig = "hub-config"
    case dbKeyMismatch = "db-key-mismatch"
    case dbError = "db-error"
    case unknown
}

public struct BootFailure: Equatable, Sendable {
    public var reason: BootFailureReason
    /// Only a key mismatch may offer a destructive local reset — never auto-wipe on anything else.
    public var canReset: Bool
    /// Worker-facing, plain-language explanation.
    public var message: String
    /// The underlying error message, preserved for the diagnostic/developer section.
    public var detail: String
}

private func detailOf(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
    return String(describing: error)
}

public func classifyBootFailure(_ error: Error) -> BootFailure {
    let detail = detailOf(error)
    if error is DatabaseKeyMismatchError {
        return BootFailure(
            reason: .dbKeyMismatch, canReset: true,
            message: "This phone\u{2019}s secure database key changed, so the saved local data can\u{2019}t be opened. "
                + "Resetting clears local data on THIS phone — any unsynced work would be lost.",
            detail: detail)
    }
    if error is HubConfigError {
        return BootFailure(
            reason: .hubConfig, canReset: false,
            message: "This build has no Ops Hub address configured. Reinstall the correct build — your local "
                + "data on this phone is safe and untouched.",
            detail: detail)
    }
    // Any other startup error (DB open/migration/disk, or unexpected). Never auto-wipe; the local
    // data is left exactly as it is for recovery/support.
    return BootFailure(
        reason: .unknown, canReset: false,
        message: "Field Capture could not start. Your local data on this phone is preserved and untouched — "
            + "please retry, and contact the office if it keeps failing.",
        detail: detail)
}
