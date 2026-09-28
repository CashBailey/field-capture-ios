# `apps/mobile/src` — module layout

Target layout from `docs/architecture/fieldcapture-foundation.md`. Folders are created **as
slices need them**, not all up front — only what a slice actually implements appears here.

```
src/
  config/      # PRESENT: build-time config (env → Ops Hub URL, Slice 0) + typed Hub runtime
               # config (hubConfig.ts — fails loud on a missing URL/session token).
  adapters/    # seams to the outside world.
    printer/   # PT-210 printer seam: Pt210PrinterTransport over the native FieldPrinter module.
    sync/      # PRESENT: OpsHubV1Client — the real v1 Hub client (session-status /
               # assignments / submit) — plus OpsHubSyncTransport + TusUploadClient: the real
               # ADR 004 `SyncTransport` engine (/sync/commands, /sync/changes, tus uploads).
    auth/      # PRESENT: HubAuthApiV1 (login/refresh/logout routes) + KeychainTokenStore
               # (session in the device keychain).
  domain/      # PRESENT: pure use-case logic — no React / SDK / HTTP / DB. hubGateway
               # types+interfaces+errors, clock gate + assignment refresh (fieldSession),
               # submit path (submitFieldTicket), auth use-cases (login/refresh/logout).
               # `Volatile*` stores here are TEST SEAMS; production stores live in data/.
               # Shared cross-client invariants stay in packages/contracts.
  data/        # PRESENT: durable SQLite store (SQLCipher in real builds) behind a SqlDriver
               # seam — SqliteAssignmentStore, SqliteTicketEvidenceStore (the outbox table),
               # DeviceIdentity (device id + local_seq), migrations, keychain-held DB key.
  runtime/     # PRESENT: AppController composition root, restart-recovery sweep, background
               # RetryEngine (full-jitter backoff; never auto-retries blocked/frozen work).
  features/    # screens/hooks; depend only on domain interfaces. (later — App.tsx hosts the
               # single field-session screen meanwhile)
```

Rule (architecture doc): React screens never import Hub clients or raw DB tables directly — they
call thin controllers/hooks that depend only on domain interfaces.

The pure-TypeScript domain contracts live in `packages/contracts` (`@fieldcapture/contracts`)
and are consumed here as a workspace package — e.g. `adapters/printer` implements
`printer.PrinterTransport`.
