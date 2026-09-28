# Field Capture native port — conventions

Goal: pure Swift/SwiftUI port of the bare React Native app in `apps/mobile` (+ `packages/contracts`).
Same form and function: same behavior, same wire formats, same SQL schema, same user-facing labels.

Status: the native app/core port is complete and is the primary build. The TypeScript tree remains
read-only as a parity oracle until rollout acceptance.

## Module map

| Swift target | Source of truth (TypeScript) |
|---|---|
| `FieldKit/Sources/FieldContracts` | `packages/contracts/src` |
| `FieldKit/Sources/FieldDomain` | `apps/mobile/src/domain` |
| `FieldKit/Sources/FieldData` | `apps/mobile/src/data` (+ `src/config`, `src/platform` where pure) |
| `FieldKit/Sources/FieldRuntime` | `apps/mobile/src/runtime` |
| App target `FieldCapture/` | `apps/mobile/src/adapters`, `src/design`, `src/screens`, `App.tsx` |

Tests: vitest/jest specs port to XCTest under `FieldKit/Tests/<Target>Tests`, keeping test
names and vectors.

## Rules

- One Swift file per TS file, same base name (`syncOutbox.ts` → `SyncOutbox.swift`).
- Preserve identifier names. TS discriminated unions → Swift enums with associated values
  (discriminant string → case name). TS interfaces used polymorphically → protocols; plain data
  shapes → structs.
- JSON wire format is law: explicit `CodingKeys` matching the TS/Hub field names byte-for-byte
  (e.g. `quantity_bbl`). Never `convertToSnakeCase`.
- Time: epoch-ms `number` → `Int64` (keep `*AtMs` names); ISO-8601 strings stay `String`
  (keep `*Utc` names). Where TS calls `Date.now()`, inject a `now: () -> Int64` (or reuse the
  existing clock parameter the TS already has).
- UUID/randomness: inject, mirroring `src/platform/random.ts`.
- Binary: `Uint8Array` → `Data`. `sha256` → CryptoKit.
- SQLite: system `libsqlite3` (`import SQLite3`) behind a thin driver mirroring `sqlDriver.ts`'s
  API. Same schema, same SQL text, same migration steps/order.
- Async: `Promise` → `async throws` (or `async` returning result enums, matching the TS shape —
  if the TS resolves to a status object instead of throwing, the Swift returns an enum and does
  not throw). Synchronous TS store APIs stay synchronous.
- Swift language mode 5 (already set in Package.swift). No third-party dependencies, ever.
- Comments: keep the TS file's explanatory header comments (translated, not attributed).
- Never modify anything under `apps/mobile` or `packages/contracts`.

## Verify

From `apps/native/FieldKit`: `swift build && swift test` must be green before you finish.
App target code must compile via:
`xcodebuild -project apps/native/FieldCapture.xcodeproj -scheme FieldCapture -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build`
