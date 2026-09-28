# Field Capture

Field Capture is a pure native iOS field-capture app built with Swift, SwiftUI, Foundation, and
Apple platform frameworks. It supports an oilfield worker's day from sign-in and Hub assignment
through DVIR/JHA, field tickets, evidence capture, offline sync, and PT-210 receipt printing.

The shipping app lives in `apps/native`. The former React Native app under `apps/mobile` and the
TypeScript contracts under `packages/contracts` remain temporarily as read-only parity references;
they are not linked into the native target and require no Metro, CocoaPods, JavaScript runtime, or
third-party Swift package.

## Quick start

Requirements: macOS with Xcode 26 or newer and an iOS Simulator.

```bash
open apps/native/FieldCapture.xcodeproj
```

Select the `FieldCapture` scheme and an iPhone destination, then press Run.

The reusable native core has a standalone Swift Package test suite:

```bash
swift test --package-path apps/native/FieldKit
```

The command-line iOS build gate is:

```bash
xcodebuild \
  -project apps/native/FieldCapture.xcodeproj \
  -scheme FieldCapture \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Configuration

Build settings are the source of truth:

- `FIELD_APP_ENV`: `dev` in Debug and `prod` in Release.
- `OPS_HUB_URL`: the resolved Hub base URL exposed through `Info.plist`.
- `OPS_HUB_URL_LOCAL`: Debug defaults to `http://opshub.local:8000` and can be overridden at
  build time.

Release deliberately has no checked-in production Hub URL. Supply it through the release build
configuration or CI; the app fails visibly instead of silently talking to the wrong server.

## Native architecture

| Layer | Target | Responsibility |
| --- | --- | --- |
| App | `FieldCapture` | SwiftUI shell, screens, navigation state, design system, permissions |
| Runtime | `FieldRuntime` | App controller, workflow services, sync/upload/retry/print runners |
| Domain | `FieldDomain` | Assignments, auth, offline policy, forms, drafts, evidence, sync state |
| Data | `FieldData` | SQLite driver/migrations, durable stores, encrypted-key handling, blob files |
| Adapters | `FieldAdapters` | Hub HTTP, tus uploads, Keychain, camera/photos, GPS, CoreBluetooth PT-210 |
| Contracts | `FieldContracts` | Wire payloads, fieldwork rules, idempotency, sync and printer contracts |

`apps/native/FieldKit/Package.swift` defines the dependency direction. The app has no React Native
bridge and no third-party Swift dependencies.

## Form, function, and style parity

- All 98 exported legacy screen components have SwiftUI equivalents.
- Five driver tabs remain `Day / Jobs / SOPs / Sync / More`, with the same state-driven flows.
- Hub wire keys, operation types, SQL schema/migrations, idempotency rules, retry behavior, and
  no-silent-loss invariants are ported into tested Swift types.
- Camera/photo import uses PhotosUI/UIKit; validation-only GPS uses CoreLocation; Keychain and
  SQLite are direct native integrations; PT-210 uses CoreBluetooth and ESC/POS.
- The original logo and app icon are byte-identical native assets.
- Brand colors, semantic statuses, 28/20/17/15/13 typography scale, spacing, radii, and 56-point
  field actions are centralized under `FieldCapture/Design`.
- System/Light/Dark is reactive and persisted in the same Keychain item as the previous app.
- Typography uses SwiftUI semantic styles so iOS Dynamic Type remains active.

## Upgrade continuity

The native target intentionally keeps:

- bundle identifier `com.example.fieldcapture`;
- marketing version `1.0.1` and the existing URL schemes;
- auth, database-key, and theme Keychain service/account names;
- QuickSQLite's `Documents/fieldcapture.db` location and the existing migration sequence;
- `Documents/captures` blob paths for unuploaded evidence;
- the iOS 16.4 minimum deployment target.

These choices allow an in-place update to see the existing sandbox, session, database, drafts,
outbox, and captured evidence instead of appearing as a second empty app.

## Debug screen gallery

Debug builds can render a screen directly for visual/accessibility inspection without a live Hub:

```bash
xcrun simctl launch booted com.example.fieldcapture \
  -GalleryScreen ThemeScreen
```

Use `-ScreenGallery` to open the browsable gallery. Both routes compile out of Release startup;
Release always mounts the real app shell.

## Repository layout

```text
apps/native/
  FieldCapture.xcodeproj/   native iOS application project
  FieldCapture/             SwiftUI app, screens, resources, privacy manifest
  FieldKit/                Swift Package core and XCTest suites
apps/mobile/               legacy React Native parity reference (not shipped)
packages/contracts/        legacy TypeScript parity reference (not shipped)
docs/                      architecture, ADRs, workflow, integration contracts
```

## Safety invariants

1. Ops Hub is the business source of truth.
2. Unsynced work, photos, signatures, and unacknowledged print events are never silently deleted.
3. JHA/JSA signatures, work-start markers, evidence links, and audit/print events are append-only.
4. Mutations retain optimistic version preconditions and stable idempotency identity.
5. GPS is single-shot field validation only—no maps, routing, background tracking, or telemetry.
6. A database-key mismatch is surfaced; local data is reset only after explicit user confirmation.

See `docs/adr/005-pure-native-swift-migration.md`, `docs/field-day-workflow.md`, and
`docs/integration/ops-triad-contract.md` for the decision and domain contracts.

## Verification limits

CI and Simulator cover the Swift package tests, app compilation, launch, navigation semantics, and
visual/accessibility smoke checks. A physical iPhone remains required for final camera permissions,
real GPS conditions, background behavior, Keychain upgrade migration, and PT-210 BLE/paper output.
