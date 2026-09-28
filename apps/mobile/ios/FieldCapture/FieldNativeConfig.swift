import Foundation
import React

@objc(FieldNativeConfig)
class FieldNativeConfig: NSObject, RCTBridgeModule {
  static func moduleName() -> String! {
    "FieldNativeConfig"
  }

  static func requiresMainQueueSetup() -> Bool {
    false
  }

  @objc
  func constantsToExport() -> [AnyHashable: Any]! {
    let info = Bundle.main.infoDictionary ?? [:]
    return [
      "appEnv": info["FIELD_APP_ENV"] as? String ?? "dev",
      "hubUrl": info["OPS_HUB_URL"] as? String ?? "",
      "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
    ]
  }
}
