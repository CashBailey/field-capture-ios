# Field Capture — Deployment Pipeline

How the pure Swift app moves from this repository to a worker's iPhone. The active framework
decision is [ADR 005](adr/005-pure-native-swift-migration.md).

## Pipelines

| Pipeline | Where | Secrets | Purpose |
| --- | --- | --- | --- |
| Native CI | GitHub Actions `macos-26` | None | `swift test` plus unsigned Simulator build |
| Legacy parity CI | GitHub Actions Linux | None | Temporary TypeScript behavior oracle |
| Sign/archive/distribute | Xcode / App Store Connect | Owner-held | TestFlight or production delivery |

No certificate, provisioning profile, App Store Connect key, Hub credential, or real field data is
stored in this repository.

## Local release gates

```bash
swift test --package-path apps/native/FieldKit

xcodebuild \
  -project apps/native/FieldCapture.xcodeproj \
  -scheme FieldCapture \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the app in Simulator and exercise sign-in, theme, tabs, a DVIR/JHA path, drafts, and sync state.
Hardware gates on a signed iPhone remain mandatory for camera/photo permissions, real GPS,
background behavior, Keychain/sandbox upgrade continuity, and PT-210 BLE/paper output.

## Release configuration

Release uses `FIELD_APP_ENV=prod` and intentionally leaves `OPS_HUB_URL` unset in source control.
Set the production HTTPS URL in the signed build configuration or a protected CI secret. The app
classifies a missing URL as a visible configuration failure and does not erase local work.

Before archiving, verify:

- bundle ID is `com.example.fieldcapture`;
- marketing/build versions are valid for App Store Connect;
- signing team and profile are correct;
- production Hub URL is present and reachable;
- camera, photo, location, local-network, Bluetooth, and Face ID usage text is correct;
- `PrivacyInfo.xcprivacy`, the app icon, and branded launch screen are in the built product;
- an upgrade install sees the previous Keychain session, `Documents/fieldcapture.db`, and captures.

## Archive and distribute

1. Open `apps/native/FieldCapture.xcodeproj`.
2. Select the `FieldCapture` scheme and Any iOS Device.
3. Choose Product → Archive.
4. Validate the archive in Organizer.
5. Distribute to TestFlight first, then the chosen App Store, Unlisted App, or Apple Business
   Manager channel.

Every Swift, resource, privacy, permission, entitlement, configuration, or package change ships as
a new iOS binary. There is no Metro, JavaScript bundle, CocoaPods step, or OTA update channel.

## Network posture

Ops Hub is self-hosted. Production should use public-trust HTTPS on a stable DNS name routed to
the office/VPN endpoint. Debug defaults to `http://opshub.local:8000`; local networking is allowed
for development, but screens never hard-code or display backend URLs outside protected diagnostics.
