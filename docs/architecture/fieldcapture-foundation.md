# Field Capture — Architecture Foundation

This document is the durable map of Field Capture's architecture. It binds the research reports
to the active ADRs and implementation plan.

## System context

```
            ┌──────────────────────────────────────────────┐
            │ Ops Hub  (source of truth)                 │
            │ FastAPI + React/Vite, self-hosted Windows PC │
            │ change_log · idempotency_ledger · audit      │
            │ upload_sessions · attachments                  │
            └───────▲───────────────▲────────────────────────┘
                    │ commands/events│ tus uploads
        ┌───────────┴───┐   ┌────────┴───────┐
        │ Field Time    │   │ Field Capture   │
        │ Pi NFC clock  │   │ phone app      │
        │ sibling sync  │   │ offline-first  │
        └───────────────┘   └────────────────┘
```

- **Hub is the only authority.** Mobile and Time are offline-first clients that submit
  commands + immutable events and pull server-ordered changes. No active-active writers.
- **Mobile and Time share one sync contract** (UUIDs, idempotency keys, local sequence,
  dependency ordering, retry/backoff, durable outbox).

## Decisions at a glance

| ADR                    | Decision                                                                                                                            |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 001 Framework / deploy | Bare React Native with an Xcode-owned iOS workspace. Native modules provide iPhone hardware access; React Native remains the app layer. |
| 002 Resource budget    | Conservative tier is the default contract; comfortable unlocks on capable devices. Never silently evict unsynced/unprinted records. |
| 003 PT-210 spike       | iOS BLE (CoreBluetooth) GATT is the chosen, proven PT-210 transport via the native `FieldPrinter` module.                            |
| 004 Sync / conflict    | Hybrid custom, server-authoritative commands/events; optimistic concurrency; tus uploads; append-only safety records. No CRDT core. |

## Data authority and isolation

The protected persistence domain:

- **Field-work / safety domain (non-disposable):** `tickets.db`, `forms.db`, `sync-queue.db`,
  immutable signature/photo blobs, print-job queue. Protected from silent eviction until
  Hub-acknowledged (ADR 002). Append-only for signatures, work-start evidence, print events.

## Module layout

```
src/
  domain/            # pure types + use-case interfaces (no React/SDK/HTTP/DB)
    printer/
    sync/
    fieldwork/
  data/              # repositories, persistence, manifest parsing
  runtime/           # orchestration, state machines, queues
  adapters/
    printer/         # native printer seam; iOS support depends on verified PT-210 transport
    hubSync/
    device/          # native camera/photo-library and validation-only GPS adapters
  features/          # screens/hooks (depend on domain interfaces only)
    jobs/
    tickets/
```

Rule: React screens never import Hub clients or raw DB tables directly. Screens call thin
controllers/hooks that depend only on domain interfaces.

## Cross-cutting invariants

1. **Hub is source of truth.** Printing and local caches are outputs/derivations.
2. **Never silently lose work.** Unsynced photos, unprinted/unsynced print jobs, unaccepted
   mutations, and safety signatures survive until Hub acknowledges them.
3. **Append-only for evidence.** JHA/JSA signatures, work-start markers, print events, audit.
4. **Optimistic concurrency.** Mutable business edits carry `base_version`/`If-Match`; Hub
   rejects stale, never auto-merges authority.
5. **One writer per authority epoch.** Future cloud cutover increments the epoch.
6. **Conservative budget by default.** Comfortable tier only after runtime capability checks.
7. **Native access stays behind seams.** Camera, GPS, Keychain, SQLite, files, future NFC, and
   printer access live behind adapters so screens do not depend directly on native APIs.
8. **Printer is a seam.** All printing flows through `PrinterService`/`PrinterTransport`;
   no screen-to-printer code; PT-210 iOS BLE support stays behind `FieldPrinter`.

## What is intentionally NOT decided here

- Backend database final choice (SQLite vs Postgres) — affects later off-the-shelf sync options.
- Apple Business Manager availability, Hub DNS/TLS strategy, VPN vs LAN reachability.
- Any secrets, certificates, Apple/Google credentials, or real employee/customer data — none
  are committed to this repo.

## Reading order

1. This document.
2. ADRs 001-004.
3. `docs/printer-pt210.md`.
4. `docs/plans/fieldcapture-foundation-plan.md`.
5. `research/reports/`.
