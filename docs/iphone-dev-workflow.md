# iPhone development workflow — SwiftUI + Xcode

Field Capture is a pure native iOS app. Xcode builds the checked-in project directly; Node, Metro,
CocoaPods, Expo, and EAS are not part of the native development loop.

## One-time setup

Install Xcode 26 or newer, open the project, select your Apple development team if using a physical
device, and choose the shared `FieldCapture` scheme:

```bash
open apps/native/FieldCapture.xcodeproj
```

The app targets iOS 16.4 and uses only the local `apps/native/FieldKit` Swift package.

## Simulator loop

Press Run in Xcode, or build from the shell:

```bash
xcodebuild \
  -project apps/native/FieldCapture.xcodeproj \
  -scheme FieldCapture \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Debug resolves `OPS_HUB_URL` from `OPS_HUB_URL_LOCAL`, defaulting to
`http://opshub.local:8000`. Override it without editing the project:

```bash
xcodebuild \
  -project apps/native/FieldCapture.xcodeproj \
  -scheme FieldCapture \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  OPS_HUB_URL_LOCAL=http://127.0.0.1:8000 \
  build
```

For visual inspection without Hub credentials, launch the Debug gallery:

```bash
xcrun simctl launch booted com.example.fieldcapture -ScreenGallery
xcrun simctl launch booted com.example.fieldcapture -GalleryScreen JobsListScreen
```

## Swift package loop

```bash
swift test --package-path apps/native/FieldKit
swift test --package-path apps/native/FieldKit --filter SqlDriverTests
```

The package covers contracts, domain rules, SQLite stores/migrations, auth/Hub transports,
idempotency, recovery, sync/retry/upload, capture, and printer behavior.

## Physical iPhone loop

1. Connect the iPhone or enable wireless debugging.
2. Open `apps/native/FieldCapture.xcodeproj`.
3. Select the `FieldCapture` scheme and phone.
4. Configure the signing team if requested.
5. Ensure the phone can reach the configured Hub.
6. Press Run.

Use a real device to validate camera/library permissions, single-shot GPS, data protection after
lock/unlock, lifecycle/background behavior, upgrade continuity, and PT-210 discovery/reconnect/
printing. Simulator success does not prove those hardware paths.

## Native runtime inventory

- App entry: `FieldCapture/FieldCaptureApp.swift`
- Bundle ID: `com.example.fieldcapture`
- UI: SwiftUI
- HTTP: URLSession
- Tokens/settings/database key: Security.framework Keychain
- Database: SQLite3, existing `Documents/fieldcapture.db`
- Evidence bytes: protected `Documents/captures`
- Camera/photo import: UIKit + PhotosUI
- Validation GPS: CoreLocation, one foreground fix only
- Printer: CoreBluetooth PT-210 GATT + ESC/POS

Any code or resource edit requires a rebuild. SwiftUI previews and the Debug screen gallery shorten
the UI loop; no native code hot reload exists.
