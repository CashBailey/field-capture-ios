# ADR 001 - Framework and Deployment

## Status

Superseded on 2026-07-11 by
[ADR 005 — Pure Native Swift Migration](005-pure-native-swift-migration.md).

At the time of this revision, this ADR replaced the earlier Expo prebuild/dev-client decision with a
native iOS/Xcode-owned app shell while React Native remained for shared UI, domain, tests, and
iteration loop.

## Context

Field Capture is the field app for the Field system:

- Ops Hub: self-hosted FastAPI/React source of truth on an office Windows PC.
- Field Time: Raspberry Pi NFC clock.
- Field Capture: driver/dispatcher/manager phone app.

Constraints remain offline-first field work, camera/photo evidence, JHA/JSA signatures, secure
local storage, validation-only GPS, background-capable sync, future NFC, and PT-210 thermal
printing where the phone hardware and printer protocol allow it. The owner is currently focused on
the iPhone/Xcode workflow and wants more direct hardware control than the Expo runtime provides,
without throwing away the React Native code and TypeScript test surface already built.

## Decision

Use **bare React Native with an Xcode-owned iOS workspace** as the product direction.

- The iOS app is built and run from `apps/mobile/ios/FieldCapture.xcworkspace`.
- React Native and TypeScript remain the app layer for screens, field-work orchestration,
  offline sync, storage abstractions, and tests.
- Expo is no longer the app runtime, launcher, build system, config system, or OTA update system.
  Metro is still used for local debug bundling and Fast Refresh.
- Native hardware access is provided through React Native native modules and native packages:
  Keychain, SQLite, filesystem, camera/photo library, geolocation, and future NFC/Bluetooth/printer
  modules.
- Build-time config is owned by native iOS settings and `Info.plist`, surfaced to JavaScript
  through the `FieldNativeConfig` bridge.
- Full Swift/SwiftUI rewrites are rejected for broad app UI. They remain available for narrow
  hardware surfaces or system integrations that are better implemented natively.

This gives the project the intended "best of both worlds":

- Native Xcode control over signing, entitlements, Info.plist, permissions, device capabilities,
  frameworks, and App Store/TestFlight builds.
- React Native speed for most product UI and business logic.
- A clear path to custom Swift/Objective-C modules when iPhone hardware access is the deciding
  factor.

## Deployment

- **iOS:** Xcode archive/TestFlight first. App Store, Unlisted App, or Apple Business Manager Custom
  App distribution can be chosen later based on company account availability.
- **Android:** Out of scope. Field Capture is an iOS-only app; there is no Android build target and
  the former Android printer scaffold has been removed.
- **Updates:** No Expo OTA. JavaScript bundle updates ship with normal iOS binary releases unless
  a future non-Expo OTA mechanism is explicitly adopted and reviewed against Apple policy.

## Consequences

- More direct access to iPhone hardware and system capabilities than Expo dev-client allows.
- Xcode is now the source of truth for iOS native build behavior, so local CocoaPods and simulator
  validation are part of normal development.
- The app keeps one React Native/TypeScript codebase for the majority of UI and business logic.
- Native changes require rebuilding the iOS app. JavaScript/TypeScript changes can still use Metro
  and Fast Refresh in Debug.
- SQLCipher is not assumed. The app must report plain SQLite honestly until a native SQLCipher
  build is added and verified.
- PT-210 iOS printing over BLE GATT (CoreBluetooth) is proven working, implemented in the native
  Swift printer module and bridged into the React Native app. This framework decision provided the
  native access that made that transport possible.
- CI and headless tests must not require a physical printer, camera, NFC tag, or GPS signal.

## Rejected alternatives

- **Expo dev-client / EAS as product runtime** - good ergonomics, but too indirect for the desired
  native iPhone/Xcode control and hardware exploration.
- **Expo Go as runtime** - cannot load the custom native modules needed for secure storage,
  database behavior, printer work, and future hardware integrations.
- **Full native Swift rewrite** - technically strong for hardware, but too expensive for a solo
  maintainer across mostly shared business UI and workflow logic.
- **Flutter** - viable, but switching would discard the existing React Native/TypeScript app and
  test surface, and the PT-210 BLE printing path is already proven on the chosen stack.

## Implementation impact

- `apps/mobile` is a bare React Native app, not an Expo app.
- `apps/mobile/ios/FieldCapture.xcworkspace` is the iOS entry point for Xcode.
- Native dependencies are installed through npm and CocoaPods, not Homebrew and not Expo install.
- Product configuration moves from Expo config to native build settings and `Info.plist`.
- The current React Native native package set covers:
  - Keychain secure token/key storage.
  - Quick SQLite persistence.
  - Filesystem-backed evidence blobs.
  - Camera/photo-library still image capture.
  - Foreground one-shot geolocation for validation-only evidence.
- Remaining hardware work should add narrow native modules behind existing domain seams rather than
  leaking native APIs into screens.

## Open questions

- Does the company operate Apple Business Manager, or should distribution start with TestFlight and
  later use Unlisted App distribution?
- Is there a stable DNS name and public-trust TLS plan for Ops Hub, or must the app support a
  managed private CA/VPN path?
- Beyond the proven BLE GATT transport, are there additional PT-210 firmware quirks to harden the
  CoreBluetooth printer module against?

## Source report references

- `research/reports/02-framework-deployment-report.md` (original framework/deployment research)
- `research/reports/01-resource-budget-report.md` (low-end device budget)
- `research/reports/03-sync-conflict-report.md` (offline-first client behavior)
