# ADR 005 — Pure Native Swift Migration

## Status

Accepted on 2026-07-11. Supersedes ADR 001's React Native runtime decision.

## Context

Field Capture is iOS-only and depends on platform capabilities that were already native seams:
Keychain, SQLite, protected files, foreground camera/photo import, single-shot validation GPS, app
lifecycle handling, and direct CoreBluetooth PT-210 printing. The React Native implementation also
accumulated two parallel UI layers: polished presentational screens and separately wired runtime
screens. The requested direction is a pure native app without changing driver-facing form,
business behavior, Hub contracts, offline durability, or brand style.

## Decision

Ship `apps/native/FieldCapture.xcodeproj` as the application and `apps/native/FieldKit` as its
dependency-free Swift core.

- SwiftUI owns the app shell, screens, state-driven flows, accessibility, and design system.
- Foundation and Apple frameworks own HTTP, Keychain, SQLite, filesystem, Photos/UI camera,
  CoreLocation, lifecycle, and CoreBluetooth integrations.
- The five-layer package preserves contract/domain/data/adapter/runtime boundaries.
- JSON wire keys, SQL schema, migrations, evidence lifecycles, and idempotency rules remain
  byte/behavior compatible and are covered by XCTest.
- The production bundle ID, Keychain names, database/capture locations, URL schemes, app version,
  and iOS 16.4 minimum are preserved for in-place upgrade continuity.
- `apps/mobile` and `packages/contracts` remain temporary parity oracles until native rollout is
  accepted; they are not part of the native product or build.

## Consequences

- App development no longer requires Node, Metro, CocoaPods, a JavaScript bundle, or a bridge.
- Native code changes require a normal Xcode rebuild; there is no Fast Refresh or OTA JS path.
- CI runs both the native XCTest/build gates and the legacy parity suite during the transition.
- App Store packaging must include the native privacy manifest and a configured Release Hub URL.
- Simulator verification cannot replace physical-device checks for camera, GPS, background policy,
  Keychain/sandbox upgrade continuity, and PT-210 BLE/paper output.

## Rejected alternatives

- **Keep React Native for UI** — conflicts with the requested pure native runtime and retains bridge,
  dependency, and dual-style complexity.
- **Rewrite domain behavior opportunistically during the port** — raises data-loss and wire-contract
  risk. Product-flow corrections should be isolated follow-up changes after parity is proven.
- **Install a new bundle ID beside the old app** — loses automatic access to the existing sandbox
  and app-scoped Keychain items, making offline work appear missing.
