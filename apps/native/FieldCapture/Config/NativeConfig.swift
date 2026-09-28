// Port of src/config/nativeConfig.ts + env.ts — build-time config from Info.plist
// (FIELD_APP_ENV / OPS_HUB_URL are stamped in by Xcode build settings, same as the RN app).
import Foundation

enum AppEnv: String {
    case dev, staging, prod
}

private func optionalString(_ value: Any?) -> String? {
    guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
}

private func appEnvFrom(_ value: Any?) -> AppEnv {
    if let s = value as? String, let env = AppEnv(rawValue: s), env != .dev { return env }
    return .dev
}

let nativeAppEnv: AppEnv = appEnvFrom(Bundle.main.object(forInfoDictionaryKey: "FIELD_APP_ENV"))

/// Which Ops Hub environment this build targets (dev | staging | prod).
let appEnv: AppEnv = nativeAppEnv

/// Base URL of the Ops Hub for this build, or nil if unconfigured.
let hubUrl: String? = optionalString(Bundle.main.object(forInfoDictionaryKey: "OPS_HUB_URL"))

/// App version for the More screen (CFBundleShortVersionString).
let nativeAppVersion: String? = optionalString(
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
