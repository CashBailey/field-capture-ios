# @fieldcapture/contracts

Pure-TypeScript domain contracts for Field Capture. **No Expo, no native, no hardware** — runs
anywhere Node + Vitest run, so it is CI-safe and folds into the iOS app later (Slice 0).

## Scope (foundation slices)

| Area                                                                              | Files            | ADR |
| --------------------------------------------------------------------------------- | ---------------- | --- |
| Printer abstraction + PT-210 profile + durable print-job queue                    | `src/printer/`   | 003 |
| Sync envelopes, change token, idempotency key, tus/upload + print-event contracts | `src/sync/`      | 004 |
| Field-work model + SR-lock and append-only-signature rules                        | `src/fieldwork/` | 004 |
| Resource budgets and protected-work eviction rules                                | `src/budget/`    | 002 |

## Guarantees proven by tests

- **No print job is silently discarded.** A job is removable only once `syncedAt` is set
  (printed **and** synced to Hub). Unprinted, printed-but-unsynced, failed, and canceled jobs
  are all protected; `purge()` skips them and `remove()` throws on them.
  (`test/print-job-queue.test.ts`)
- PT-210 profile keeps every unverified protocol field as `"unknown"` until the hardware spike;
  transport placeholders throw `NotImplementedError`. (`test/pt210-profile.test.ts`)
- SR lock invariant + append-only JHA/JSA signatures + ticket draft/submit immutability.
  (`test/fieldwork.test.ts`)
- Idempotency key format + change-token ordering. (`test/idempotency.test.ts`)
- Resource budgets never silently evict protected field, safety, print, or sync work.
  (`test/budget.test.ts`)

## Commands

```bash
npm install
npm test        # vitest run  (32 tests, no hardware)
npm run typecheck
```

## Not here yet

No Hub, no native printer module, and no UI. This package keeps only Mobile-owned contracts and
pure rules that can be verified without a device.
