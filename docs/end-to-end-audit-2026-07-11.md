# End-to-end code and product audit — 2026-07-11

## Verdict

The native runtime is materially safer and its automated quality gates are green, but the iOS app
is **not release-ready**. Two UI truthfulness defects remain release blockers:

1. The guided pre-trip, post-trip, and JHA screens do not carry the worker's entered answers into
   the durable form. The submitted domain builders still manufacture a one-item "Brakes: OK" DVIR
   and a canned H2S JHA.
2. Job SOP, job detail, emergency, and stop-work panels are reachable from the production shell
   with sample data and missing callbacks. A worker can see fictitious safety/contact information
   or receive success-like feedback for an action that was not sent anywhere.

Those paths must be wired to authoritative assignment/form data or hidden before release. The
audit fixes below deliberately avoid inventing product behavior or silently deleting existing
parity surfaces.

## Scope

- Native Swift package and SwiftUI app: 43,112 lines across 184 Swift files.
- Contracts, domain rules, SQLite persistence, auth/Keychain, sync, uploads, evidence, printer,
  background runners, composition, and app lifecycle.
- SwiftUI visual system, navigation/state ownership, accessibility, dynamic type, copy, and
  production-vs-gallery fixture boundaries.
- Legacy React Native and TypeScript contract implementation as a behavior/parity oracle.
- CI, formatting, tests, sanitizers, strict concurrency, and Debug/Release simulator builds.

## Improvements made

### Correctness, durability, and security

- Serialized the entire SQLite connection and transaction boundary with a recursive lock. A
  concurrent write can no longer join another caller's transaction and be rolled back with it.
- Made down-sync application and its transaction throwing. A malformed or unapplied page no
  longer advances the frontier. Duplicate Hub command results now produce a typed retryable error
  instead of trapping in `Dictionary(uniqueKeysWithValues:)`.
- Made `SystemSqliteDriver.transaction` join an enclosing transaction instead of issuing a nested
  `BEGIN IMMEDIATE` (which SQLite rejects). The production pull path wraps the change ledger's own
  transactional `record` in the sync-engine transaction seam, so every pull carrying at least one
  change previously failed with a `SqlError` and could never apply. Joining preserves the caller's
  error identity and rolls inner writes back with the outer transaction; concurrent writers from
  other threads still cannot join, because the connection lock is held for the whole outer
  transaction. Covered by a driver join/rollback test and the two sync-engine rollback tests.
- Pinned authenticated tus `HEAD`/`PATCH` requests to the configured Hub origin before resolving a
  bearer token. Public cleartext and credential-bearing URLs fail closed; local HTTP remains
  available only for explicit development hosts.
- Rejected short blob reads and non-exact PATCH offsets so an upload cannot spin forever while
  retaining its retryable bytes and durable state.
- Added true compare-and-swap session replacement at the Keychain boundary. Stale refresh,
  rejection, expiry, and logout work cannot overwrite a newer login or resurrect a logout.
- Keychain system errors and malformed database/session data are surfaced rather than treated as
  "missing." Session saves now update-or-add without a destructive delete window.
- Persisted print payload bytes in SQLite alongside durable print jobs, including restart tests.
- Invalidated the PT-210 connection cache on teardown, delegate disconnects, and transport errors.
- Made the offline-contact timestamp a single atomic monotonic SQLite upsert.
- Made CoreLocation timeout/cancellation resolve the one-shot request exactly once and reject a
  concurrent request instead of replacing its continuation.
- Added per-ticket single-flight submission, preventing concurrent taps from allocating two
  idempotency identities.
- Fixed JHA review so submission occurs only after the confirmation action and cannot be repeated
  while in flight.

### Concurrency and maintainability

- Locked polling, retry, volatile evidence, and lifecycle state that Thread Sanitizer proved was
  racy.
- Removed the remaining production strict-concurrency warnings without suppressing diagnostics.
- Applied one parity-aware Swift format to all native sources, tests, and app files.
- Added a strict Swift formatting gate to native CI.
- Replaced async-context test locks with small synchronous critical sections so the test suite is
  ready for Swift 6 checking.

### UI quality

- Changed warning-badge text from amber-on-white (2.15:1) to the existing saddle-brown token
  (5.84:1).
- Allowed primary buttons and status badges to grow vertically and wrap at accessibility sizes.
- Preserved the existing coherent theme tokens, 48-point minimum touch targets, plain-language
  offline states, text-plus-symbol status treatment, and stable accessibility identifiers.

## Verification

| Gate | Result |
| --- | --- |
| `swift test --package-path apps/native/FieldKit` | 709 passed |
| `swift test --sanitize=thread` | 709 passed; zero Thread Sanitizer reports |
| Swift strict-concurrency build | passed; no production warnings |
| strict `swift-format` lint | passed for sources, tests, and app |
| iOS generic Simulator Debug build | passed |
| iOS generic Simulator Release build | passed |
| legacy TypeScript typecheck | passed |
| legacy Jest | 60 suites / 591 tests passed; 1 suite / 5 tests skipped |
| contract Vitest | 15 files / 154 tests passed |
| legacy Prettier | passed |
| legacy iOS bundle | passed |
| legacy ESLint | 0 errors; 73 existing warnings |
| `git diff --check` | passed |

The debug screen gallery was smoke-checked in light mode and dark mode at an accessibility text
size. This does not replace physical-device checks for camera permission, real GPS behavior,
background transitions, Keychain upgrade migration, or PT-210 BLE/paper output.

## Open findings

### P0 — release blockers

1. **Safety-form answers are discarded before durable submission.**

   `PreTripFlow` keeps only aggregate counts, `PostTripFlow` does not retain the section result,
   and `JhaFlow` keeps signatures but not the entered job/site, emergency, PPE, hazard, step, or
   stop-work values. The domain builders then emit canned records in
   `FieldKit/Sources/FieldDomain/FieldForms.swift` (`jhaJsaForm`, `preTripDvirForm`, and
   `postTripDvirForm`). A signed record can therefore contradict what the worker entered.

   Required fix: define complete draft payloads for each wizard, own them above each route,
   persist drafts during navigation, and build the immutable submitted record only from those
   payloads. Add UI-to-SQLite restart tests and assertions for defects, hazards, controls, PPE,
   steps, remarks, and signatures.

   Parity note: this is inherited legacy behavior, not a port regression. The React Native app
   builds the identical canned records in `apps/mobile/src/screens/FieldRuntimeScreens.tsx`
   (`dvirForm` emits the same one-item "Brakes: OK" DVIR; `jhaForm` emits a single canned hazard).
   The native port reproduces it byte-for-byte per the same-function mandate; fixing it is a
   product change requiring sign-off, to be applied to whichever stack ships.

2. **Production navigation exposes sample safety/job data and no-op actions.**

   `AppShell.subJobPanel` constructs `JobDetailsScreen`, `JobSopsScreen`,
   `EmergencyInfoScreen`, and `StopWorkScreen` without authoritative data or action callbacks.
   Those views fall back to `sampleSops`, `sampleEmergency`, and other fixtures. Stop-work report
   and emergency call actions can therefore do nothing while changing local feedback.

   Required fix: move fixtures behind `#if DEBUG` gallery entry points. Production initializers
   should require real values and callbacks, or render an explicit unavailable state with no
   actionable control.

   Parity note: also inherited. The React Native screens document "realistic sample fallbacks
   fill any absent prop" as a deliberate convention (GUI Master §20; see `SAMPLE_SOPS` fallback in
   `apps/mobile/src/screens/JobScreens.tsx` and equivalents in `SopExtraScreens.tsx` /
   `FieldTicketScreens.tsx`). The native port mirrors that convention; gating fixtures behind
   `#if DEBUG` is a behavior change requiring the same sign-off.

### P1 — high priority

3. **Admin mode is not protected.** `AdminFlow` intentionally accepts any four-character PIN and
   the More screen shows Admin Mode by default. Gate it with a Hub role/capability and a real
   server-validated or device-managed credential; otherwise hide it in Release.

4. **Some settings/actions overstate what happened.** Account sets "Request sent to the office"
   even when no callback is wired. Text Size, High Contrast, and Reduce Motion are local toggles
   that do not alter the app environment. Do not show success until an operation succeeds; either
   wire these settings globally and persist them or label/hide them as unavailable.

5. **Persistence APIs still encode fatal or hidden failure.** Several SQLite stores use `try!`
   because their protocols are nonthrowing. Separately, some enqueue closures catch an error and
   allow later local state to record success. Disk-full/corrupt-database behavior can therefore
   crash or create a reference to a missing outbox row. Make store/enqueue seams throwing and
   commit dependent state in the same transaction.

   Progress: store `list()` seams are now throwing, and `PrintQueueScreen` reads through a
   refresh state that surfaces a read failure as an inline notice instead of crashing or
   rendering silently empty. Remaining `try!` call sites and enqueue closures are still open.

6. **Corrupt durable rows are not safely surfaced.** Corrupt-list APIs have no production
   consumer, and some unknown enum values default to active states such as `.queued`. Quarantine
   corrupt work, include it in Sync Center, and never reinterpret unknown persisted values as work
   that may be resent or reprinted.

### P2 — important follow-up

7. Blob purge is not crash-idempotent: bytes are deleted before the row is stamped, while a missing
   file is treated as failure. Blob filename sanitization is also non-injective. Make missing-file
   deletion successful and migrate new captures to collision-resistant names without orphaning
   existing files.
8. Diagnostic redaction is shallow and logs have no retention bound. Recursively redact structured
   values, strip URL queries from error text, and cap/age stored logs.
9. The largest SwiftUI files are 1,100–1,944 lines and duplicate layout helpers. Split screens by
   state owner/feature, centralize the repeated `FlowLayout`, and move synchronous SQLite reads out
   of view bodies. Preserve parity while doing so; an immediate low-risk cleanup is about 1,700
   lines, while deleting the legacy stack should wait for explicit migration sign-off.
10. There is no XCUITest target for the production shell. Add a small release-smoke suite covering
    sign-in, offline restart, form draft restoration, JHA confirmation, double-tap submission,
    failed sync, and the absence of gallery/sample data in Release.

## Architecture assessment

The dependency direction is sound: contracts → domain → data/adapters → runtime composition → UI.
Typed state transitions, idempotency identity, restart recovery, dependency planning, stale-token
handling, append-only evidence, and upload/link-before-purge rules are strong. The highest risk is
not the core architecture; it is the gap between presentational SwiftUI wizards and the durable
domain records they claim to submit.
