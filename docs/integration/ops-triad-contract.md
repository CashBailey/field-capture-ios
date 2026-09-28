# Field Triad Integration Contract — Mobile-facing slice

## Goal

OpsHub is the authority. TimeClock and FieldCapture are offline-first clients.

TimeClock proves yard presence with NFC + selected CHECK_IN/CHECK_OUT + photo evidence.
FieldCapture consumes Hub truth: a driver can open the app, but **field work is locked until Hub
shows an open TimeClock clock-in**.

This document records the **Mobile-facing** portion of the contract as implemented in this repo
(first real integration slice). The OpsHub (`opshub`) and TimeClock repos hold the
server/terminal portions.

## System boundaries

| System          | Role                                                                                                                                                       |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **OpsHub**    | Authority for employees, credentials, clock status, dispatch assignments, mobile field-ticket acceptance, audit, attachments.                              |
| **TimeClock**   | Local-first NFC terminal; creates the punches Hub reports as clock status.                                                                                 |
| **FieldCapture** | _This repo._ Offline-first worker app: views assigned SRs, follows the locked workflow, captures field evidence, submits tickets, preserves unsynced work. |

Mobile UX gating is **not** authority. Hub still rejects invalid submissions (it re-checks
clock-in, assignment, and snapshot freshness on every submit).

## Mobile auth model

Mobile endpoints use driver user auth:

```text
Authorization: Bearer <session_token>
Idempotency-Key: <gtr:device:seq:uuid>     (on POST /api/v1/sync/submit; also in the body)
```

Hub derives `employee_id` from the token. The client is never trusted to submit `driver_id`,
`created_by`, `status`, `verified`, or prices.

**Where the values come from (this repo):**

- **Hub base URL** — baked at build time via native iOS build settings / `Info.plist`
  (`APP_ENV` selects `OPS_HUB_URL_DEV|STAGING|PROD`; see `FieldNativeConfig` and
  `apps/mobile/src/config/env.ts`). Read at runtime by `apps/mobile/src/config/env.ts` -> validated by
  `apps/mobile/src/config/hubConfig.ts` (`resolveHubRuntimeConfig` / `getHubRuntimeConfig`).
- **Session token** — produced by the auth slice (`apps/mobile/src/domain/auth.ts`,
  `apps/mobile/src/adapters/auth/`) and stored through the secure-token seam. Lower-level
  callers can still pass a token to `getHubRuntimeConfig({ sessionToken })` for tests/tools.
- **Missing Hub URL throws a typed `HubConfigError`; missing token resolves to auth-needed at
  the controller/domain boundary.** The app fails visibly and keeps work local. It never guesses
  a Hub and never fakes a sync.

## Routes consumed by Mobile

Client: `apps/mobile/src/adapters/sync/OpsHubV1Client.ts`.

### 1. Session status (the clock gate)

```text
GET /api/v1/sync/session-status
```

Response (200):

```json
{
  "clocked_in": true,
  "clocked_in_since": "2026-06-09T12:00:00Z",
  "source": "timeclock",
  "employee_id": "employee-id",
  "assignments_available": true
}
```

Rules:

- Returns only the **current logged-in driver's** status (no roster).
- `clocked_in` is **required** (boolean). A malformed body is a `HubResponseError` — the gate
  stays locked rather than guessing.
- Mobile mapping (`apps/mobile/src/domain/fieldSession.ts` → `evaluateClockGate`):

| Hub answer                            | Field-work gate                                                           |
| ------------------------------------- | ------------------------------------------------------------------------- |
| `clocked_in: true`                    | `unlocked` (with `clockedInSince`, `source`)                              |
| `clocked_in: false`                   | `locked` / `not-clocked-in`                                               |
| network failure                       | `locked` / `hub-unreachable` — **never assumes a clock-in while offline** |
| 401 / 403                             | `locked` / `auth-failed`                                                  |
| 5xx / non-JSON / missing `clocked_in` | `locked` / `bad-hub-response` — malformed is never "probably clocked in"  |

Locked means the app still opens, but field steps/actions are **non-actionable**. Hub's submit
guard remains authoritative regardless of what the app shows.

### 2. Signed-in user profile

```text
GET /api/v1/me
```

Response (200):

```json
{
  "id": "user-id",
  "username": "driver.username",
  "email": "driver@example.com",
  "display_name": "Driver Name",
  "title": "Driver",
  "department": "Operations",
  "roles": ["driver"],
  "access_profile": "driver",
  "language": "en"
}
```

Rules:

- Returns only the **current logged-in user's** profile.
- Mobile fetches it immediately after login or refresh and stores it with the secure auth session.
- More/Profile displays Hub-provided name, role, department, `employee_id`, phone, yard, truck,
  and trailer when present. Missing optional values display as "Not provided by Hub".
- Profile fetch failures never block authentication; the app keeps the token and shows honest
  missing-value fallbacks.

### 3. Assignment pull

```text
GET /api/v1/sync/assignments
```

Returns only active SRs assigned to the logged-in driver, with frozen snapshots and a
Hub-computed `snapshot_hash`:

```json
{
  "assignments": [
    {
      "service_request_id": "sr-id",
      "snapshot_hash": "hash",
      "latest_server_version": 42,
      "customer": { "customer_id": "cust-1", "name": "ACME Oil" },
      "lease": { "lease_id": "lease-1", "name": "North Lease" },
      "wells": [
        {
          "well_id": "well-12",
          "lease_id": "lease-1",
          "name": "Well 12H"
        }
      ],
      "material": { "name": "Produced water" },
      "disposal_site": {
        "site_id": "disp-1",
        "name": "SWD 8"
      },
      "vehicle": { "vehicle_id": "truck-7", "label": "Truck 7" },
      "job_type": "water-haul",
      "workflow_requirements": {
        "require_pre_trip_dvir": true,
        "require_jha_per_sr": true,
        "require_post_trip_dvir": false
      },
      "snapshot": { "...frozen SR snapshot..." }
    }
  ]
}
```

(A bare top-level array is also accepted.) `service_request_id` and `snapshot_hash` are
**required** per entry — an entry without a hash is rejected (`HubResponseError`) because drift
detection on submit depends on it. The richer fields are optional and backward compatible:
Mobile normalizes them for UI and workflow gating while preserving the raw `snapshot` unchanged
for legacy behavior.

Mobile pulls assignments **only when the gate is unlocked** (`refreshFieldSession`), persists
`snapshot_hash`, `latest_server_version`, normalized rich metadata, and the raw `snapshot` in
SQLite, and keeps the previously-cached set if a refresh fails. The app shell displays
customer/lease/well/material/disposal/vehicle/job fields when present, clean `unknown` states
when absent, and snapshot hash/version drift markers. Workflow requirements are read from
normalized `workflow_requirements` first and legacy `snapshot.workflow_requirements` second; Hub
remains authoritative and can still reject submit.

### 4. Minimal field-ticket submit

```text
POST /api/v1/sync/submit
```

```json
{
  "idempotency_key": "gtr:device-instance:7:uuid",
  "service_request_id": "sr-id",
  "snapshot_hash": "hash",
  "ticket_no": "12345",
  "quantity_bbl": 120,
  "disposal_ticket_no": "D-123"
}
```

Idempotency keys use the contracts helper `sync.buildIdempotencyKey()` —
`gtr:<device_instance_id>:<local_seq>:<op_uuid>`, the same scheme as TimeClock. Retries reuse the
**same** key, so Hub can never double-create a ticket.

Hub behavior (server-side contract):

- derive driver from token; verify the SR belongs to the driver
- check `is_clocked_in(employee_id)` — the authoritative clock gate
- dedupe by `(driver_employee_id, idempotency_key)`
- stamp `capture_source="mobile"`, create the ticket pending verification
- flag snapshot drift instead of silently accepting stale context

**Success body Mobile requires (2xx):**

```json
{
  "accepted": true,
  "ticket_id": "ft-id",
  "field_ticket_id": "legacy-or-compat-ft-id",
  "status": "accepted",
  "duplicate": false,
  "snapshot_drift": false
}
```

`accepted: true` is mandatory — a 2xx without it (captive portal, proxy garbage) is treated as a
**transient** failure, never success. Mobile accepts either `ticket_id` or `field_ticket_id` as
the Hub ticket identifier. `duplicate: true` (or `reason_code: "duplicate"`) marks an idempotent
replay of an earlier accept and is equally durable. `snapshot_drift` is preserved; if true, Mobile
routes the evidence to review instead of treating the body as durable success.

**Legacy compatibility:** current Mobile also accepts older Hub success bodies shaped like:

```json
{
  "field_ticket_id": "ft-id",
  "status": "created",
  "duplicate": false,
  "snapshot_drift": false
}
```

This path is compatibility only. Mobile maps it to accepted only when `field_ticket_id` is present,
`status` is `accepted`, `created`, or `submitted`, and `snapshot_drift` is not true.
`snapshot_drift: true` maps to **needs review** even on 2xx.

**Status → Mobile outcome mapping** (`OpsHubV1Client.submitFieldTicket` →
`apps/mobile/src/domain/submitFieldTicket.ts`):

| Hub response                                               | Outcome               | Local evidence              | User-visible state                         |
| ---------------------------------------------------------- | --------------------- | --------------------------- | ------------------------------------------ |
| 2xx `accepted:true`                                        | accepted              | `accepted` (durable)        | done                                       |
| 2xx `accepted+duplicate`                                   | accepted (replay)     | `accepted`                  | done                                       |
| legacy 2xx `field_ticket_id` + success `status` + no drift | accepted              | `accepted`                  | done                                       |
| legacy 2xx `snapshot_drift:true`                           | rejected/needs-review | frozen `needs-review`       | **needs review**                           |
| 403 (e.g. `not_clocked_in`)                                | rejected/blocked      | kept `pending`              | **blocked** — retry after the driver acts  |
| 409 (`in_progress` replay race)                            | rejected/blocked      | kept `pending`              | **blocked** — retry later                  |
| 412 (`stale_version` / snapshot drift)                     | rejected/needs-review | frozen `needs-review`       | **needs review** — manual resolution       |
| 422 (idempotency payload mismatch)                         | rejected/needs-review | frozen `needs-review`       | **needs review**                           |
| other 4xx                                                  | rejected/needs-review | frozen `needs-review`       | **needs review** (status + code preserved) |
| 401                                                        | auth-failed           | kept `pending`              | **sign in again**; work preserved          |
| 429 / 5xx                                                  | transient             | kept `pending` (attempts+1) | retry later                                |
| network failure                                            | transient             | kept `pending` (attempts+1) | retry later                                |

`rejection_code` / `reason_code` and `detail` from the Hub body are preserved verbatim on the
local evidence (`lastRejectionCode`) and in the returned result — rejection detail is never lost.

**Durability rule:** local work is marked durable **only** on `accepted` (including
duplicate-accepted). Every other outcome preserves the local evidence.

**Client robustness:**

- Every request is **time-bounded AND aborted** (default 15 s, configurable). RN's fetch has no
  default timeout, so without the bound a black-holed connection would hang a submit forever. A
  timeout (or a caller-provided `AbortSignal` — user cancellation) fires the request's
  `AbortController`, tearing the socket down instead of leaving it draining battery; a race
  backstop bounds even a fetch that ignores its signal. Cancellation never cancels the WORK:
  the outcome maps to the transient arm, evidence returns to `pending` (never stuck in-flight),
  and the retry reuses the same idempotency key. (`HubFetch` carries `signal`;
  `boundedAbortableFetch` is shared by every Hub-facing adapter.)
- A **concurrent submit with the same idempotency key** (e.g. a double-tap) never fires a second
  network call: the second caller gets `pending-retry` / `already-in-flight` while the first
  call lands the real outcome.

## Locked-clock behavior (summary)

1. App opens regardless of clock state — opening is never gated.
2. `evaluateClockGate` asks Hub; anything other than a verified `clocked_in: true` →
   **locked** (`not-clocked-in` / `hub-unreachable` / `auth-failed`, reason surfaced to the user).
3. Locked → assignments are not pulled; field steps/actions are non-actionable.
4. Even when the app believes it is unlocked, Hub re-checks clock-in on submit; a 403 maps to a
   user-visible **blocked** state with the evidence kept locally for retry.

## Reliability layer (durable store + outbox + retry + auth slices)

Local storage is now **durable**: `SqliteAssignmentStore`, `SqliteFieldTicketDraftStore`, and
`SqliteTicketEvidenceStore` (`apps/mobile/src/data/`) persist assignments (+ snapshot hashes),
pre-submit field-ticket drafts, submit evidence (idempotency keys, status, rejection
code/detail/http-status/timestamps, retry metadata), and the device's write identity (device id +
monotonic `local_seq`) in SQLite. SQLCipher is not assumed; if a native SQLCipher build is added,
the durability verdict must be _verified_ at open (`PRAGMA cipher_version`) and surfaced. Until
then the app reports plain SQLite honestly. The `Volatile*` stores remain as test seams only.

The durable outbox projection is stored separately from UI state on the evidence row:
`id`, `type`, `payload_json`, `idempotency_key`, `outbox_status`, `attempts`, `last_detail`,
`last_http_status`, `last_rejection_code`, `created_at`, and `updated_at`. `outbox_status` is
`pending`, `in-flight`, `retry`, `blocked`, `failed`, `accepted`, or `needs-review`. `blocked`
is the projection for 403/409 user-action-gated rows that remain pending with rejection detail;
`failed` is reserved for terminal rejected evidence. The domain still uses the tested contracts
state machine internally; the projection is what screens and diagnostics can read without
interpreting envelopes.

On top of that store:

- **Restart recovery** (`src/runtime/restartRecovery.ts`): on boot, orphaned `in-flight`
  evidence is swept back to `pending` (same idempotency key — Hub dedupes); terminal rows stay
  frozen. Runs before the retry engine and before any submit (`AppController.start()`).
- **Background retry engine** (`src/runtime/retryEngine.ts`): full-jitter exponential backoff
  (contracts `sync/backoff.ts`); auto-retries ONLY transient failures (network / 5xx / 429).
  Blocked 403/409 rows wait for the user; 412/422 stay frozen for review; a 401 pauses the
  engine until re-auth (`resumeAfterAuth`).
- **Auth slice** (`src/domain/auth.ts`, `src/adapters/auth/`): login / keychain token storage /
  refresh-on-expiry / logout against `POST /api/v1/auth/{login,refresh,logout}`. Logout clears
  the token only — unsynced evidence is preserved. A 2xx login without an explicit
  `session_token` is transient, never "signed in".

## Full sync engine (ADR 004 — `/sync/commands` + `/sync/changes`)

Implemented by `OpsHubSyncTransport` (`apps/mobile/src/adapters/sync/OpsHubSyncTransport.ts`,
the real `sync.SyncTransport`) driven by `SyncEngine` (`apps/mobile/src/runtime/syncEngine.ts`)
over the durable generic outbox (`sync_outbox` + `committed_ops`, migration v4). The V1 routes
above remain served and `OpsHubV1Client` stays exported as compatibility; the V1 adapter is
NOT deleted. `PlaceholderSyncTransport` also remains (a seam that refuses rather than fakes,
for anything not yet wired to the real transport).

### 4. Command/event batch submit

```text
POST /api/v1/sync/commands
```

```json
{
  "operations": [
    {
      "op_id": "uuid",
      "kind": "command",
      "type": "ticket.submit",
      "idempotency_key": "gtr:device-instance:7:uuid",
      "local_seq": 7,
      "depends_on": ["parent-op-id"],
      "precondition": { "base_version": 3 },
      "payload": { "...domain payload..." }
    }
  ]
}
```

`precondition` is present only for mutable-edit commands (412 on stale, 428 when required but
missing); append-only events never carry one. Response (200):

```json
{
  "results": [
    {
      "op_id": "a",
      "outcome": "accepted",
      "token": { "authority_epoch": 1, "commit_seq": 42 }
    },
    {
      "op_id": "b",
      "outcome": "rejected",
      "rejection_code": "stale_version",
      "detail": "...",
      "latest": {}
    },
    {
      "op_id": "c",
      "outcome": "needs-review",
      "review_reason": "assignment_changed"
    }
  ]
}
```

Engine rules (all tested):

- Dispatch is **dependency-ordered** (`sync.planDispatch`, `local_seq` order): a child ships only
  after every parent committed; a dead parent or dependency cycle surfaces the child as
  `blocked` for review — never dispatched, never dropped.
- Items go **in-flight before the network is touched**; every outcome folds through the
  contracts state machine. `accepted` records the committed change token; `rejected` freezes
  terminally with `rejection_code`/`detail` verbatim; `needs-review` freezes with the
  `review_reason`. Frozen items are never auto-resubmitted.
- A transport throw (network / 5xx / malformed response) is **transient for the whole batch**:
  items return to `pending` with full-jitter backoff and the SAME envelope — Hub's idempotency
  ledger makes the replay safe (duplicate replays land `accepted`). A 401/403 returns items to
  pending WITHOUT a backoff stamp and reports `authRequired` — due the moment re-auth lands.
- A malformed results entry fails the WHOLE call loudly (`HubResponseError`) — a guessed outcome
  can never mark work durable. A missing per-op result reschedules only that op.
- **Restart recovery**: orphaned in-flight outbox rows sweep back to pending on boot
  (`SyncEngine.recoverOnStartup`), before any push.

### 5. Authoritative change pull

```text
GET /api/v1/sync/changes?after_epoch=<E>&after_seq=<S>
```

Response (200): `{ "token": { "authority_epoch": 1, "commit_seq": 58 }, "changes": [ ... ] }`

- Mobile pulls strictly **after the stored frontier** (`sync_frontier`, single row; the zero
  token `<0,0>` before the first pull). The next token is validated (`advanceFrontier` —
  server-issued, monotonic, higher epoch always wins) **before** any change touches a local
  store; the frontier persists **after** apply, so appliers must be idempotent (a crash between
  the two replays the page).
- **Stale token** (Hub compacted its change log past our frontier): `410` with optional
  `{"reset_to": {"authority_epoch": E, "commit_seq": S}}` → `sync.StaleChangeTokenError`. The
  engine resets the frontier (Hub's `reset_to`, else the zero token) and re-pulls once in the
  same pass — never silently treated as an empty page.

### 6. Tus-style resumable uploads (photos / signatures / documents)

```text
POST /api/v1/sync/uploads          → open (or dedupe) an upload session
HEAD  <upload_url>                 → durable offset (Upload-Offset) + Upload-Sha256 once complete
PATCH <upload_url> + chunk         → 204 with the new Upload-Offset; final PATCH carries Upload-Sha256
```

Open request: `{ "blob_id", "sha256", "byte_length", "mime_type", "idempotency_key" }`.
Responses: `{ "result": "already-present", "blob_id" }` (content-hash dedupe — durably uploaded
without sending a byte) or `{ "result": "new-session", "upload_session_id", "upload_url" }`.

Lifecycle (contracts `sync.advanceBlob`, driven by `UploadEngine` over the durable
`blob_records` table):

`local-only → uploading → uploaded → linked` (+ `upload-expired` for a dead session / hash
mismatch — bytes kept, fresh session restarts from the durable local copy).

- **Capture**: photos (field-ticket / disposal / receipt) and signatures register with their
  SHA-256, byte length, parent record (`parent_type`/`parent_id`/`attachment_kind`) and a
  client-generated `attachment_id`. Registration is idempotent on blobId; a duplicate
  `attachment_id` bound to a different blob throws.
- **Resume**: the server's HEAD offset is the truth (ahead OR behind local bookkeeping); the
  acknowledged offset persists after EVERY chunk, so an interrupted upload resumes mid-file.
  A 404/410 session is gone → `upload-expired`, restart clean.
- **Hash verification**: the upload confirms ONLY when the server-computed whole-file sha256
  matches the local capture hash; a mismatch abandons the session and never confirms.
- **Link command**: a separate append-only `attachment.link` command (own idempotency key,
  `depends_on` the parent's op when given) goes through the durable sync outbox. A rejected or
  needs-review link leaves the blob preserved on-device for review.
- **Purge gate (THE invariant)**: local bytes are deleted ONLY when `sync.isBlobPurgeable` —
  upload confirmed AND link commit confirmed. The record survives with `purged_at` as proof.

### 7. Accepted-evidence pruning (ADR 002 byte budgets)

`sync.planEvidencePrune` (pure planner) + `pruneAcceptedTicketEvidence` /
`pruneAcceptedSyncOutbox` (`apps/mobile/src/data/evidencePruning.ts`):

- Only `accepted` rows past the **retention window** are ever candidates, and only while the
  table's total bytes exceed the **size threshold**; oldest acceptance frees first, stopping at
  the budget. `minKeepAccepted` can pin the N most recent accepted rows.
- NEVER pruned, regardless of pressure: `pending`, `in-flight`, `retry`, `blocked`, `failed`,
  `needs-review`, accepted rows with no outcome stamp, corrupt rows (their envelope no longer
  parses — evidence of damage), and rows carrying an external protection reason (an attachment
  not yet uploaded+linked, an unprinted record, an unacknowledged print event). Pressure beyond
  the eligible rows is reported as a shortfall, not forced.
- Full-engine outbox rows prune **into the `committed_ops` ledger**, so a dependent enqueued
  after its parent was pruned still resolves as satisfied (`planDispatch(committedOpIds)`) —
  pruning can never turn a satisfied dependency into a dead one. The store guard
  (`pruneAcceptedToLedger`) throws on any non-accepted state, making unsafe pruning
  unrepresentable.

## Field-evidence operation types (over `/sync/commands`)

The field-runtime slice adds three append-only `kind: "event"` operation types to the envelope
protocol (all use the standard idempotency keys, dependency ordering, and outcome mapping
above — Hub must store them append-only and answer accepted / rejected / needs-review):

| `type`          | Payload                                                                                                                                | Emitted by                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `dvir.submit`   | a completed `DvirForm` (pre- or post-trip: vehicle, inspection items, defect notes, safe-to-operate certification, signature blob ids) | `FieldWorkflowService.submitForm` |
| `jhajsa.submit` | a completed `JhaForm` (SR, hazards + mitigations, signature blob ids)                                                                  | `FieldWorkflowService.submitForm` |
| `print.event`   | a `PrintEvent` (`printJobId`, `queued`/`printed`/`failed`/`canceled`, `occurred_at`)                                                   | `PrintRuntime`                    |

Client-side rules (tested):

- Forms are FROZEN once enqueued; a needs-review/rejected outcome preserves the record with
  Hub's verbatim reason and stops satisfying its workflow step.
- Hub-configured required steps (`require_pre_trip_dvir`, `require_jha_per_sr`,
  `require_post_trip_dvir` in the session/assignment config) gate ticket submission on the
  device (`checkTicketSubmitAllowed`); Hub remains authoritative on submit.
- A print job becomes removable from the durable queue ONLY after it is terminal (printed /
  failed / canceled) AND its terminal `print.event` was ACCEPTED by Hub.
- Signatures and photos attach through the upload + `attachment.link` flow above; DVIR/JHA
  signatures use `parentType: "jhajsa"` (or the form's id as parent) and are append-only.
- Every field action (form drafts/completion/submit, capture, ticket submit) is locked while
  the clock gate is locked.
- React Native screens now sit over the tested runtimes: DVIR/JHA forms, capture evidence, and
  print queue/status. They display durable local state, Hub outcomes, retry state, and
  hardware-unavailable placeholders without deleting unsynced evidence or mutating safety records
  from print paths.
- The PT-210 binding path is present behind a `FieldPrinter` native module seam. It supports
  discover, connect, write ESC/POS bytes, status, reconnect, and disconnect for the diagnostic
  path once a platform module is present. The JS binding validates the native module shape,
  time-bounds native calls, and surfaces native failures as explicit diagnostic/domain codes.
  Missing native support remains an explicit `printer-not-implemented` failure, never a print
  success.

## Deferred but tracked

- PT-210 real-hardware verification (ADR 003): the iOS BLE CoreBluetooth binding, diagnostic,
  durable queue, and sync rules are implemented. A physical
  PT-210 still must prove paper output, reconnect-after-sleep/restart, low-battery/failure cases,
  and QR/barcode support before production rollout.
- remaining document-picker/native PNG signature adapters over `CaptureFlow`; the production
  `FileBlobBytesSource` already persists captured bytes under the app's private documents
  directory via `react-native-fs`, while tests use fake/in-memory byte sources
- wiring the full sync engine into `AppController`/`wireAppRuntime` once Hub ships the
  `/sync/commands` + `/sync/changes` + `/sync/uploads` routes (the V1 path stays the production
  submit path until then); Hub-side handling of `dvir.submit` / `jhajsa.submit` /
  `print.event` ships with those routes
- store distribution / deployment ceremony (Slice 7)
- **FieldNav / navigation — explicitly out of scope for Mobile v1.** Turn-by-turn navigation,
  route optimization, offline map-tile downloads, AutoPi integration, vehicle telemetry, and
  fleet GPS tracking are **deferred and must stay out** of `apps/mobile`. The full streaming
  location/map/routing/AutoPi stack was removed in commit `b4e0b36`; the ADR-005 isolation
  guardrail went with it, so a jest guard test (`apps/mobile/__tests__/nav-stays-out.test.ts`)
  now enforces no `maplibre`/`react-native-maps`/router-as-map dependency and no
  nav/map/tile/routing imports under `apps/mobile`. The ONLY sanctioned GPS use is the Phase-7
  **validation-only** `LocationEvidence` model (single-shot native geolocation, no
  streaming, no map render) — proving where an action happened, not navigating to it.
