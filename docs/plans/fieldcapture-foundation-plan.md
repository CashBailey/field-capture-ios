# Field Capture — Foundation Implementation Plan

Task-based, TDD-oriented. Safe slices. Each slice is independently reviewable and must not break
the never-silently-lose-work invariants. CI must never require the physical PT-210.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `(gate)` blocks later work.

## Active Mobile Scope

- [x] Monorepo with `apps/mobile` and `packages/contracts`.
- [x] Bare React Native iOS app with an Xcode-owned workspace and native module seams.
- [x] Hub v1 session/assignment/submit client with bounded requests.
- [x] Durable SQLite stores, restart recovery, idempotent retry, and auth seams.
- [x] Full sync/upload engine contracts and client-side runtime seams.
- [x] DVIR/JHA workflow runtime and append-only evidence events.
- [x] Capture flow for photos/signatures/documents with hash and upload/link discipline.
- [x] PT-210 printer abstraction, durable queue, iOS BLE GATT printer module (CoreBluetooth), and
      diagnostic screen.
- [x] React Native app shell over Assignment, Workflow, Capture, Print, and PT-210 diagnostic
      panels.

## Deferred

- [~] Production camera/photo-library and validation-only GPS native adapters.
- [ ] Document-picker and native PNG signature export adapters.
- [ ] Hub-side `/sync/commands`, `/sync/changes`, `/sync/uploads`, tus sessions, and field-event
      handlers.
- [ ] Store distribution and deployment ceremony.

## Validation Gates

Run from the repo root:

```bash
npm run typecheck
npm test
npm run lint
npm run format:check
npm run bundle:check
```
