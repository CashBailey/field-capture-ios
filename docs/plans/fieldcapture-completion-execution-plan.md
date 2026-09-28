# Field Capture — Completion Execution Plan

> Status: authoritative completion plan, grounded in a current-state code audit (2026-06-14).
> Target product: `/home/opshub/Desktop/FieldCaptureCompletion.md`.
> Wire contract: `/home/opshub/Desktop/Hub_Mobile.md` and `docs/integration/ops-triad-contract.md`.
> Supersedes the foundation plan at `docs/plans/fieldcapture-foundation-plan.md` for completion sequencing.

---

## 1. Context & current state

**The foundation is largely built and genuinely good.** The hard parts — durable SQLCipher stores, restart recovery, the idempotency-keyed submit pipeline, the ADR-004 sync/upload engines, the auth+clock-gate state machine, the DVIR/JHA workflow runtime, and the capture/hash/upload discipline — exist, are typed, and are unit-tested. The gaps are overwhelmingly **integration, UI surface, and wiring**, not missing core logic.

**The running app is one screen.** `apps/mobile/App.tsx` (~1326 lines) is a single `App` component that boots the runtime, gates on auth/clock, and renders everything (login, outbox summary, assignment detail, sign-out) in one `ScrollView`. The "tabs" are an in-screen `useState<'workflow'|'capture'|'print'>` content switcher (`App.tsx:128`, `:870-890`), not the spec's 5-tab bottom navigation. There is no navigation library installed.

**Capture and sync were originally placeholder seams in the live wiring; most of that has since moved forward.** `wireAppRuntime.ts` now constructs the real `OpsHubSyncTransport`, `TusUploadClient`, `SyncEngine`, and `UploadEngine`, and `CaptureEvidenceScreen` no longer fabricates photo/import bytes: camera and library still images go through `react-native-image-picker` into `CaptureFlow`. Remaining capture gaps are native signature-pad/document-picker paths and on-device proof of the full login→capture→upload→sync loop.

**The REAL Hub is the opshub repo — we build against it, not a mock.** Confirmed present at `/tmp/opshub` with a `Makefile` (`make up` starts the Hub; `make down` stops it; health check on port **8000** at `http://127.0.0.1:8000/api/health`). The mobile boundary is entirely under `/api/v1` — auth (`routers/auth.py`) and sync (`sync/router.py`). All on-device iPhone testing in this plan points the dev build at the locally-running opshub backend.

**Highest-severity finding (blocks everything downstream): the live assignments path is wire-broken against the real Hub.** Three hard parse failures will empty the assignment list whenever the real Hub responds:
- `latest_server_version` — Hub sends a **string** (`== snapshot_hash`); `assignments.ts:78-88 parseLatestServerVersion` throws unless it is a non-negative **integer**.
- `job_type` — Hub sends an **object** `{id,name}`; `assignments.ts:118` parses with `optionalString` and throws on an object.
- `workflow_requirements` — Hub sends `{clock_in_required, required_steps[]}`; `packages/contracts/src/fieldwork/forms.ts:112-122` reads a disjoint key set (`require_pre_trip_dvir` …), so the gate silently resolves to all-false.

These must be fixed before any on-device Hub loop can show a single assignment.

---

## 2. Gap snapshot

| Spec area | Status | Key files |
|---|---|---|
| Auth (login/refresh/logout) + clock gate domain | **Done** | `src/domain/auth.ts`, `src/adapters/auth/HubAuthApiV1.ts`, `SecureStoreTokenStore.ts`, `src/domain/fieldSession.ts`, `src/runtime/appController.ts` |
| V1 ticket submit pipeline (idempotency, drift, outcomes, retry) | **Done** | `src/domain/submitFieldTicket.ts`, `src/adapters/sync/OpsHubV1Client.ts`, `src/runtime/appController.ts` |
| Durable SQLite stores + migrations + encryption honesty | **Done (10 of 18 tables)** | `src/data/migrations.ts`, `src/data/database.ts`, `src/data/Sqlite*Store.ts`, `deviceIdentity.ts` |
| DVIR/JHA workflow state machine + append-only events + gate | **Done (core)** | `src/runtime/fieldWorkflowService.ts`, `packages/contracts/src/fieldwork/forms.ts`, `src/data/SqliteFieldFormStore.ts` |
| Capture flow: SHA-256 at capture, private storage, upload/link/purge | **Done (post-byte pipeline)** | `src/runtime/captureFlow.ts`, `src/runtime/uploadEngine.ts`, `src/data/FileBlobBytesSource.ts`, `packages/contracts/src/sync/sha256.ts` |
| ADR-004 sync transport + tus client (code) | **Done (written, NOT wired)** | `src/adapters/sync/OpsHubSyncTransport.ts`, `TusUploadClient.ts`, `src/runtime/syncEngine.ts` |
| FieldNav/map/routing/AutoPi removal | **Done** | removed in commit `b4e0b36`; zero refs under `apps/mobile` |
| **Assignments wire-contract parse** (`latest_server_version`, `job_type`, `workflow_requirements`, `coordinates`, `geofence_hints`, `disposal_site.location`) | **Partial (hard breaks)** | `src/domain/assignments.ts:78-125`, `src/domain/hubGateway.ts:71-110`, `packages/contracts/src/fieldwork/forms.ts:112-122` |
| Submit error mapping (412/422 dead code; drift swallowed; tus 409) | **Partial** | `OpsHubV1Client.ts:211-315`, `TusUploadClient.ts:143-148` |
| 5-tab navigation shell (Today/SRs/Capture/Sync/More) | **Missing** | `App.tsx` (single screen); no `@react-navigation/*` in `package.json` |
| Today dashboard + priority ladder | **Missing** | scattered in `App.tsx:462-621, 745-749` |
| Assignment inbox + 7 filters + per-SR sync state | **Missing** | `App.tsx:783-821` (chip selector only), `FieldRuntimeScreens.tsx:162` |
| SR detail full layout (assignees, checklist, location, evidence, actions) | **Partial** | `FieldRuntimeScreens.tsx:162-192` |
| Work-start marker (SR lock) | **Partial (client event wired)** | `contracts/triad-contract.json`, `src/runtime/workStartService.ts`, `JobOverviewScreen`; Hub adjudication/down-sync remains |
| Per-assignee signature requirements (owner/helper/trainee/supervisor) | **Missing** | `packages/contracts/src/fieldwork/forms.ts:79,93` (flat `>=1` check) |
| Real signature pad | **Missing** | `FieldRuntimeScreens.tsx:360-369` (comma-separated blob-id TextInput) |
| Ticket capture screen (author/edit drafts; hauling + service modes) | **Partial (hauling UI live)** | `TicketCaptureScreen`, `field_ticket_drafts`; service-work variant/full Hub payload remains |
| Receipt entity/table/screen | **Partial (draft UI live)** | `ReceiptDraft`, `receipt_drafts`, `ReceiptCaptureScreen`; Hub receipt acceptance remains |
| Native capture (camera/import/signature) | **Partial** | Camera/photo-library images use `react-native-image-picker` → `CaptureFlow`; signature-pad/document-picker paths remain. |
| Sync transport go-live (swap placeholder; wire tus; token provider; loop; applyChanges) | **Missing (wiring)** | `wireAppRuntime.ts:99,104,123-130` |
| Location validation (validation-only GPS) | **Partial (client event wired)** | `location_evidence` table + screen + `@react-native-community/geolocation` single-shot capture + `location.evidence` outbox event exist; Hub adjudication remains. |
| 24-hour offline policy + timer + Sync Center | **Partial (baseline wired)** | `offline_policy_state` exists; AppController/SyncEngine update durable last-Hub-contact; graduated gate/retry-one UX remains |
| Remaining append-only audit tables: `print_events`/`form_evidence_events` | **Missing** | print/form audit currently derived from `sync_outbox`; decide whether true tables are required |
| Design system (palette/typography/badges/outdoor mode) | **Missing** | inline hex in `App.tsx`/`FieldRuntimeScreens.tsx`; uses teal `#1f6f8b`, not Field Green `#1F6F3A` |
| EN/ES i18n | **Missing** | no i18n lib, zero Spanish strings |
| Settings + Help + More screens | **Missing** | sign-out inline at `App.tsx:986-1026` |
| Printer (PT-210) | **Partial / deferred** | `Pt210DiagnosticScreen`, `SqlitePrintJobStore` exist; intentionally later-phase |

---

## 3. Sequenced delivery plan

Phase numbering follows the spec (0–10), each adapted to the audited reality and to **iPhone-first testing against the local opshub Hub**. Hub-side prerequisites are called out explicitly; mobile work that does not depend on them proceeds in parallel.

> Build/test loop assumption for every phase: an **Xcode dev build** (`npm run ios` / Xcode Run — SQLCipher/native modules require a real native build), `APP_ENV=dev` with `OPS_HUB_URL_DEV` pointed at the LAN IP of the machine running `make up` in `/tmp/opshub` (port 8000). Validation gates (Section 7) run green before each phase is called done.

### Phase 0 — Scope lock & design cleanup
**Goal:** prevent FieldNav/printer from re-creeping; document the offline policy and iPhone-first plan.
**Tasks:**
- Add a one-line scope statement to `README.md` ("Field capture app. Not navigation. GPS validation only.") — the audit found this sentence absent.
- Re-add FieldNav / Map tiles / Routing / AutoPi / Telemetry to the **"Deferred but tracked"** section of `docs/integration/ops-triad-contract.md` (currently they were deleted outright in `b4e0b36`, leaving the deferral untracked and recurrence-prone since ADR-005 isolation guardrails are gone).
- Commit a 24-hour offline-policy design note and an iPhone-first on-device test checklist; move PT-210 to a later testing checklist.
- Add a guard jest test asserting `apps/mobile` has no dependency on `maplibre`/`react-native-maps` and no import of any nav/map/tile module.

**New packages:** none.
**Acceptance:** every repo doc agrees Field Capture is field capture, not navigation; the nav-stays-out guard test passes.
**Dependencies:** none.

### Phase 1 — iPhone on-device smoke test
**Goal:** run the current app on the iPhone via a dev build and confirm it persists local state.
**Tasks:**
- Configure the Xcode dev-build path; confirm the app's bundle version (`CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist` + Xcode build settings) and the `APP_ENV`/`OPS_HUB_URL_*` env wiring resolve.
- Install the iPhone dev build; confirm app opens, SQLCipher DB initializes (`src/data/database.ts` PRAGMA key + cipher_version), login screen renders, local test data persists, app survives restart, and no printer feature blocks startup.

**New packages:** none (uses existing `react-native-quick-sqlite`, `react-native-keychain`).
**Acceptance:** Field Capture opens and persists local state on the iPhone across a restart.
**Dependencies:** none Hub-side.

### Phase 2 — Hub login & session gate (against local opshub)
**Goal:** prove field work locks/unlocks from real Hub truth.
**Tasks:**
- Point `OPS_HUB_URL_DEV` at the LAN address of the machine running `make up`; verify health at `/api/health`.
- Exercise the live auth client (`HubAuthApiV1` → `POST /api/v1/auth/login|refresh|logout`) and `getSessionStatus` (`OpsHubV1Client.ts:149-162` → `GET /api/v1/sync/session-status`) end-to-end on device.
- **Consume `server_time` and the `since` alias** from `SessionStatusOut` (currently dropped) for clock-skew handling.
- Split the boot-failed phase (`App.tsx:22-25,63-100`) into distinct **Hub-unreachable** (`HubConfigError`) vs **Database-error** vs the existing key-mismatch reset — never auto-wipe.
- Add discrete splash phases + logo (Loading local database / Checking Hub config / Checking saved session / Checking unsynced work / Recovering in-flight evidence) by threading a progress callback through `wireAppRuntime`.
- Add Hub-environment display (dev/staging/prod, informational for v1) + read-only Hub URL + offline-explanation copy to the sign-in form (`App.tsx:1029-1110`).

**New packages:** none.
**Acceptance:** the app proves locked vs unlocked from Hub `clocked_in`; logout preserves unsynced evidence (already tested); boot failures distinguish Hub vs DB.
**Dependencies (Hub):** opshub running locally; `/auth/*` and `/sync/session-status` serving from TimeClock truth (present in `sync/router.py`).

### Phase 3 — Assignment inbox & SR detail (UNBLOCKS the loop)
**Goal:** a worker sees today's real assigned work pulled from opshub.
**Tasks (wire-contract fixes first — these are gating):**
1. ✅ **DONE** **`latest_server_version`**: `HubAssignment.latestServerVersion` now `string` (tolerates a legacy number). Verified against real Hub. *(Highest-severity wire break.)*
2. ✅ **DONE** **`job_type`**: parsed as `AssignmentNamedRef` via `parseNamedRef`. Verified against real Hub (`{id,name:"Vacuum Haul"}`).
3. ✅ **DONE** **`workflow_requirements`**: re-modelled to `{clockInRequired, requiredSteps[]}` in contracts `forms.ts`; gate uses `requiredSteps.includes(...)`. Tolerates legacy boolean keys.
4. ✅ **DONE** Consume `coordinates` (validation-only `{primary,wells[]}`) and `geofence_hints` `{radiusM,required,source}` as first-class typed fields. NOTE: real Hub sends `source:""` and null well lat/lon → optional-geo parsing is fully tolerant (drops, never throws).
5. ✅ **DONE** `AssignmentDetails` extended with `requestNo`, typed `status` (full `ServiceRequestStatus` union, tolerant), `trailer`. New fields persist via `rich_json`; round-trip test added.
> **Verification:** captured a verbatim `GET /sync/assignments` payload from local opshub into `apps/mobile/__tests__/fixtures/real-hub-assignments.json` and pinned the parse with `real-hub-assignments.test.ts` (the OLD parser threw on fields 1+2, emptying the list). KNOWN follow-up: `parseWell` falls back to the well id for `name` when the Hub omits `name` (real wells carry only `well_no`) — map `well_no`→name in the detail UI task.
**Then UI:**
- Build `AssignmentInboxScreen` (card list) with the 7 filters: Today / Active / On hold / Completed locally / Needs sync / Needs review / All cached. Active/On hold/Completed derive from `status`; Needs sync/Needs review join per-SR to outbox/blob state (add a per-SR lookup — `outboxSummary` is global today).
- Enrich `AssignmentDetailScreen` (`FieldRuntimeScreens.tsx:162-192`) to the spec-7.6 layout: assignees header, request_no + status badge, per-step `[Complete]/[Missing]` checklist, Location Validation section, Evidence summary, Actions row. Compose existing `FieldWorkflowScreen`/`CaptureEvidenceScreen` rather than re-implement.
- Surface Hub-reported snapshot drift on the inbox/detail read path (today drift is submit-time only).
- New optional fields persist automatically via `rich_json` (`SqliteAssignmentStore.ts:42`); add a round-trip test.

**New packages:** none for fields/filters (nav shell tracked in Section 4a).
**Acceptance:** on device against opshub, the worker opens the app and sees the real assigned SRs with correct fields; cached assignments show offline.
**Dependencies (Hub):** `GET /api/v1/sync/assignments` (present). **Owner/helper/trainee with explicit role tagging is a Hub-side add** (the contract `ServiceRequest` has only `ownerRef`+`assistantRefs`, no helper-vs-trainee role) — do not infer roles client-side; gate the assignee-header sub-task on it.

### Phase 4 — Pre-trip & JHA/JSA (safety workflow)
**Goal:** required safety steps gate ticket submit; signatures are real and per-assignee.
**Tasks:**
- ✅ **PARTIAL DONE** Wire the **work-start marker** (spec 7.9): added `work.start` to the sync op catalog, added a deliberate Job Overview "Start Work" action, builds a contract `WorkStartEvent` with Hub `employee_id`/timestamp/local event id, and enqueues it append-only through `SyncEngine.enqueue`. Remaining: location-evidence embedding, assignment-hash/required-step metadata if Hub accepts those fields, and Hub down-sync of the derived SR lock/review state.
- Model and enforce **per-assignee signature requirements**: extend the JHA/DVIR contract to carry signer identity + role (owner/trainee/helper/supervisor) + working-participant flag + Hub-supplied `requireSupervisorSignature`; replace the flat `signatureBlobIds.length >= 1` check.
- Flesh out DVIR fields (Hub-configured checklist replacing the hardcoded `brakes` item, odometer, trailer, notes, safe-to-operate toggle required on defects, defect note + photo) and JHA fields (task/evolution, hazards+controls editing, PPE checklist, stop-work acknowledgement, location).
- Enforce the unsafe-vehicle rule (`defectsCertifiedSafe=false` blocks field work / raises a Hub review flag — captured today but never consumed).
- Submit forms through the sync outbox; show accepted/rejected/needs-review.

**New packages:** `@react-native-community/geolocation` (single-shot GPS evidence on safety forms — see Phase 7); signature pad (Section 4d).
**Acceptance:** a worker cannot submit a ticket until required safety steps are complete, and the JHA proves *who* signed by role.
**Dependencies (Hub):** per-assignee signature config in the assignment/session payload; **work-start event adjudication** (lock SR, needs-review escalation, competing-work-start correlation) — the phone never wins authority locally; DVIR checklist/PPE templates so the client renders Hub-configured items.

### Phase 5 — Ticket & receipt capture
**Goal:** a worker can author a complete ticket + receipt package for an SR.
**Tasks:**
- Build a **TicketCaptureScreen** bound to `draftStore.save()/get()/delete()` (today `draftStore` is read-only in the UI — `App.tsx:385` — only tests write drafts; this is the single biggest functional gap blocking the 7.10 loop). Default fields from the cached assignment.
- Expand `FieldTicketDraft` (`src/domain/fieldTicketDraft.ts`) and the `field_ticket_drafts` migration to full hauling fields (customer/lease/wells/material/disposalSite/disposalTicketNo/truck/trailer/driver/notes) and add a discriminated `mode` with a **service-work** variant (description, start/end time, workers present, equipment, notes) and a digital-vs-paper/hybrid discriminator.
- Add the **Receipt entity**: `ReceiptDraft` model + `receipt_drafts` table + `SqliteReceiptDraftStore` (type Disposal/Fuel/Parts/Other, linked SR, linked ticket, vendor, receiptNo, amount, notes, optional location evidence) + a ReceiptCaptureScreen; link receipt photos via `parent_type='receipt'`.
- Add per-ticket lifecycle + lock-after-submit UX + Hub rejection-reason + snapshot-drift display (outcome data already on `TicketEvidence`; today only aggregate counts shown).
- **Correct the submit error mapping** (`OpsHubV1Client.ts:258-315`): remove dead 412/422 arms (real Hub only returns 201/403/409), fix the 409 comment (it is the workflow guard "not clocked in", not idempotency), and **surface `snapshot_drift` on accepted (201) submits** instead of swallowing it.

**New packages:** `react-native-vision-camera` (or `react-native-image-picker` camera), `react-native-image-picker`, a React Native document picker (e.g. `@react-native-documents/picker`) (Section 4d).
**Acceptance:** a worker creates, edits, submits, and locks a real ticket against opshub and sees the Hub outcome per ticket.
**Dependencies (Hub):** decide whether to widen `POST /api/v1/sync/submit` (allowlist is currently `ticket_no/quantity_bbl/disposal_ticket_no`) or route the full ticket via the `/sync/commands` envelope; **must preserve `snapshot_hash` echo for drift detection**. Receipt acceptance via `/sync/commands` (or `POST /mobile/receipt-events`).

### Phase 6 — Native capture adapters
**Goal:** photos and signatures are real artifacts, not placeholder IDs.
**Tasks:**
- Add a `react-native-vision-camera` adapter (`src/adapters/device/`), a `react-native-image-picker`/`@react-native-documents/picker` import adapter, and an RN-0.85/React-19-compatible signature pad producing PNG bytes. Feed all three through the existing `CaptureFlow` seam (it already hashes + persists real bytes via `FileBlobBytesSource`); replace synthetic bytes at `FieldRuntimeScreens.tsx:591`.
- Add preview + retake UI (spec 7.11), per-blob upload progress (`bytesAcked/byteLength`), and iOS permission strings (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`) directly in the native `Info.plist` (+ Xcode build settings) — a native change requiring a fresh dev build + version bump.
- Optional: native SHA-256 fast path (a React Native crypto/SHA-256 module) and ranged chunk reads for multi-MB media (current `FileBlobBytesSource` reads the whole file per chunk).

**New packages:** `react-native-vision-camera` (or `react-native-image-picker` camera), `react-native-image-picker`, a React Native document picker (e.g. `@react-native-documents/picker`), a signature pad (e.g. `react-native-signature-canvas` + `react-native-webview`, or a Skia pad) — **verify RN-0.85/React-19 support per `AGENTS.md` before pinning**.
**Acceptance:** captured photos/signatures are real bytes with correct SHA-256, previewable and retakeable. (Note: end-to-end upload also requires Section 4e to be wired.)
**Dependencies (Hub):** live tus upload endpoints (Phase shared with Section 4e).

### Phase 7 — Location validation (validation-only GPS)
**Goal:** prove where an action happened without becoming FieldNav.
**Tasks:**
- Define a **validation-only** `LocationEvidence` DTO under `packages/contracts/src/fieldwork` (NOT a revived nav/location package): `{ id, srId, placeKind: yard|disposal-site|well-site|other, evidenceType, gps?: {lat,lon,accuracyM,timestampMs}, notes?, state, createdAt }` with the 8 validation states (not-captured/captured/verified/outside-expected-area/unverified/rejected/gps-unavailable/manual-only). Single-shot only — no streaming, no `LocationProvider`, no map render.
- Add `location_evidence` table + `SqliteLocationEvidenceStore` (append-only, preserve-until-acked, non-evictable).
- Add `@react-native-community/geolocation` single-shot `getCurrentPosition` (no `watchPosition`), accuracy display, GPS-unavailable/manual-only fallback, and location permission strings (native `Info.plist`).
- ✅ **PARTIAL DONE** Build `LocationValidationScreen` (manual place select, known-place flow, unknown-well "Save as Unverified Location Evidence", office-verification result). Remaining: embed location evidence into pre-trip/JHA and the work-start event once Hub accepts those references.
- ✅ **CLIENT DONE** Wire location evidence through the sync outbox as immutable `location.evidence` events. Remaining: Hub adjudication/down-sync of accepted/rejected/needs-review location outcomes.

**New packages:** `@react-native-community/geolocation`.
**Acceptance:** GPS evidence captures, labels unverified correctly, syncs to Hub; no route/map/navigation UI appears.
**Dependencies (Hub):** `GET /mobile/location-places`, `POST /mobile/location-evidence` (or `/sync/commands` op) — coordinate shape with Hub.

### Phase 8 — Offline policy & Sync Center
**Goal:** offline behavior is trustworthy and visible.
**Tasks:**
- ✅ **DONE (client baseline)** Persist a **durable last-successful-Hub-contact** timestamp (updated on successful login/session-status/check-gate and V2 sync push/pull). Required across restarts so the 24h clock cannot be evaded by restarting.
- ✅ **PARTIAL DONE** Add an `offline_policy_state` table + a pure offline-policy domain module (online / offline-under-24h / offline-over-24h, elapsed, remaining). `AppRuntime` now carries `offlinePolicyStore`; graduated gate behavior remains deferred for on-device validation.
- **Graduate the clock gate** (`fieldSession.ts:43-45`): unreachable Hub within 24h keeps capture/continue-work allowed; over 24h blocks new work and labels captures "Offline over-limit evidence / Requires office review" (route to needs-review with a distinct sub-reason). Do not relax the clock-in gate.
- Build the **Sync Center** screen (spec 7.15) aggregating Drafts/Commands/Uploads/Print events/Accepted/Needs-review/Rejected/Failed queues with plain-language labels (Saved on this phone / Waiting to sync / Sent to Hub / Accepted by Hub / Needs office review / Rejected by Hub), retry-all/retry-one, view-reason, last-Hub-contact, copy-diagnostic, and an expandable developer-only technical section (raw 409/snapshot-drift codes confined there). Add a `diagnostic_logs` table to back the export.
- Add the reconnect summary (Accepted/Needs review/Rejected/Still pending) from `PushReport` counts.

**New packages:** none.
**Acceptance:** a worker sees exactly what is saved, synced, failed, and needs review; the 24h block survives restart; offline-timer-policy unit tests pass.
**Dependencies (Hub):** real reachability signal (depends on Section 4e go-live; until then the timer never resets); `GET /mobile/offline-policy` to seed the window (else a hardcoded client constant).

### Phase 9 — Printer support (later)
**Goal:** direct printing only if hardware allows; never block iPhone testing.
**Tasks:** keep PT-210 behind More / a sub-route (queue + diagnostic already exist — `SqlitePrintJobStore`, `Pt210DiagnosticScreen`); if the printer is unavailable show "Printer not available on this device yet — your ticket data is saved in Ops Hub." Run the iOS PT-210 diagnostic over BLE (CoreBluetooth), confirm ESC/POS + direct-print, build ticket/JHA print layouts, sync print events. Add a dedicated `print_events` durable record (today derived from `sync_outbox`).
**New packages:** none new beyond existing printer scaffold.
**Acceptance:** a field ticket prints directly from the iPhone over BLE; CI never requires the physical PT-210.
**Dependencies:** none Hub-blocking; intentionally last.

### Phase 10 — Beta hardening & distribution
**Goal:** developer test → internal beta.
**Tasks:** crash/error-reporting path, diagnostics screen, TestFlight, staging + production Hub configs, release checklist, driver quick-start + office troubleshooting guides, one full field pilot. Keep no-secrets CI separate from the owner-gated Xcode Archive build/sign/distribute.
**New packages:** none required (Sentry optional).
**Acceptance:** stable iPhone deployment with one completed field pilot against a staging Hub.
**Dependencies:** all of Phases 2–8 green; staging opshub.

---

## 4. Cross-cutting workstreams

### (a) Navigation refactor → 5-tab shell
Install a nav stack (`@react-navigation/native` + `bottom-tabs` + `native-stack` + `react-native-screens` + `react-native-safe-area-context`) — **verify RN-0.85/React-19 support per `AGENTS.md` first**; extend jest `transformIgnorePatterns`. Mount the navigator only after the boot state machine reaches `ready` (`App.tsx:101-107`), preserving boot-failed/key-mismatch as a pre-nav gate. Decompose `FieldSessionScreen` (`App.tsx:120-1114`) into Today / SRs / Capture / Sync / More, lifting shared state (runtime, fieldGate, activeServiceRequestId, auth flags) into a context provider. Rework `__tests__/app-shell.test.tsx` (1930 lines, tightly coupled to the flat layout and the inner `accessibilityRole="tab"` toggles) with navigator-mounting render helpers; disambiguate the duplicate "tab" accessibility nodes. **Risk:** this is the largest refactor surface and touches the carefully-bounded auth/gate state machine — sequence it after the Phase-3 wire fixes and coordinate with the uncommitted working-tree drift in `App.tsx`/`FieldRuntimeScreens.tsx`/`app-shell.test.tsx`.

> **2026-06-15 — synthesized design decision (from the `phase3-ui-design` multi-agent workflow; 6 ground-truth maps + 3 proposals + 2 judges):**
> - **Nav package: `@react-navigation`** (`@react-navigation/native` + `@react-navigation/bottom-tabs` + `@react-navigation/native-stack` give bottom-tabs + native-stack directly). Adoption = mount a `NavigationContainer` with a bottom-tab navigator of 5 routes, install `@react-navigation/native` + `@react-navigation/bottom-tabs` + `@react-navigation/native-stack` + native peers (`react-native-screens`, `react-native-safe-area-context`, gesture-handler/reanimated as needed) via npm, run `pod install`, bump the iOS bundle version (native change → fresh Xcode dev build). **This step needs an on-device dev build, so it is owner-gated** — do NOT add the native deps / mount the navigator headlessly.
> - **Build order (de-risked for headless work):** build the Phase-3 SCREENS + logic as PURE, jest-verifiable units that run in the existing single-screen app FIRST, then wire the `@react-navigation` shell last. Status: ✅ pure inbox logic done (`src/domain/assignmentInbox.ts` — per-SR sync rollup + 7 filters). NEXT: `AssignmentInboxScreen` (card list + filter chips, react-test-renderer tests) → enrich `AssignmentDetailScreen` to the 7.6 layout (requestNo, status badge, per-step checklist, sync-state badge) → reusable `StatusBadge` (text+icon, spec 8.6). THEN the `@react-navigation` shell (owner-gated).
> - **Boot machine + clock gate stay UNTOUCHED** (mount nav only after `ready`); per-SR sync state derives from `ticket_evidence.envelope.payload.serviceRequestId` (+ form/blob rows) — no schema change required, an indexed column is the clean later optimization. Surfacing needs-review/snapshot-drift on the inbox/detail read path is DISPLAY-ONLY (never auto-refetch/auto-wipe) — both judges grafted this.

### (b) Design system + outdoor mode + status badges
Add `src/design/theme.ts` with the spec-8.2 palette (Field Green `#1F6F3A` — replacing the current teal `#1f6f8b`, Safety Amber `#F59E0B`, Error Red `#B42318`, Info Blue `#2563EB`, Field Sand `#F5EFE3`, etc.) and the spec-8.3 type scale (title 26–30, body 16–18 — current inline sizes max at 24, below the field-readable bar). Replace duplicated inline hex/fontSize in `App.tsx:1193-1325` and `FieldRuntimeScreens.tsx:940-1019`. Build a reusable `StatusBadge` (text + line icon, never color-alone) for all spec-8.6 statuses; add `react-native-vector-icons` line icons; add a Normal/Outdoor/Dark display mode driven through the theme; adopt full-width 56–64px field action buttons (48×48 min) and a Card layout. **Risk:** churns string/snapshot-based tests that assert exact English labels — coordinate with (c).

### (c) EN/ES i18n
Add an i18n runtime (`i18next` + `react-i18next` or `@lingui`) + `react-native-localize` for default locale; build EN + plain-Spanish catalogs for all static labels and the spec-8.8 driver actions; replace hardcoded literals across `App.tsx`/`FieldRuntimeScreens.tsx`; add a persisted language setting in More. Scope ES to static labels first — translation must not block core workflow.

### (d) Native capture adapters
See Phase 6. Single seam (`CaptureFlow`) already exists; the work is the device adapters (`react-native-vision-camera`/`react-native-image-picker`/`@react-native-documents/picker` + signature pad) + permissions + preview/retake. Native modules require a fresh Xcode dev build.

### (e) Sync-engine go-live: `PlaceholderSyncTransport` → real ADR-004 + tus against opshub
> **2026-06-15 de-risking (verified live against opshub):** the V2 wire CONTRACTS are sound — unlike assignments, `OpsHubSyncTransport` parses the real Hub verbatim. Confirmed live: `POST /sync/commands` returns HTTP **200** `{results:[{op_id,outcome,token:{authority_epoch,commit_seq}}]}` (accepted) / `{...,rejection_code,detail}` (rejected); `GET /sync/changes` returns `{token:{authority_epoch,commit_seq}, changes:[{authority_epoch,commit_seq,op_id,entity_type,entity_id,change_type,payload,created_at}]}`; a `field.note` event advances `commit_seq`. Pinned in `apps/mobile/__tests__/real-hub-sync-v2.test.ts` + fixture. **So the remaining 4e work below is WIRING, not contract fixes** — and item 4 (`applyChanges`) now has the real change-row shape to key on (`(authority_epoch, commit_seq)`).

> **2026-06-15 — 4e prerequisites DONE headlessly (items 1–4); the flip (5–7) is owner-gated for the on-device pass.** Each prereq is built + tested + gate-green WITHOUT changing live behavior (`PlaceholderSyncTransport` stays in production), so the go-live flip is minimal wiring of tested code, not new untested integration.

The real `OpsHubSyncTransport` and `TusUploadClient` are written and unit-tested. Prerequisites (done) + the go-live flip (`wireAppRuntime.ts`, owner-gated):
1. ✅ **DONE** `OpsHubSyncTransport` now accepts an optional **per-call `tokenProvider`** (async; falls back to `config.sessionToken`); at go-live pass `AppController.getSession`'s single-flight refresh. Tested.
2. ✅ **DONE** `createTusFetch` (`adapters/sync/tusFetchAdapter.ts`) maps RN `fetch`→`TusHttpResponse` (`headers.get`→`header()`, Uint8Array body, `AbortSignal`). Tested standalone + through a real `TusUploadClient` probe. (Go-live: replace the throwing tus stubs at `wireAppRuntime` with `new TusUploadClient({ tokenProvider, fetchFn: createTusFetch() })`.)
3. ✅ **DONE** tus PATCH 409 disambiguated — `TusOffsetConflictError` (resumable) vs `TusHashMismatchError` (fatal→engine expires), keyed on `Upload-Sha256`.
4. ✅ **DONE** idempotent `applyChanges` — durable `sync_changes` ledger (migration v11) keyed on `(authority_epoch, commit_seq)`; wired as `applyChanges` in `wireAppRuntime` (records every change before the frontier advances; per-entity application layers on top later).
5. ⏳ **OWNER-GATED (on-device flip)** Return `SyncEngine` from `AppRuntime`; call `recoverOnStartup()` after DB open and before first push (boot-ordering invariant).
6. ⏳ **OWNER-GATED (on-device flip)** Add a **gated background loop** (AppState/connectivity-gated, not naive `setInterval`) driving `syncOnce()` + `uploadEngine.processOnce()/purgeOnce()`, with a V2 **auth-pause/resume handoff** consuming `PushReport.authRequired` (mirroring the V1 `RetryEngine`/`resumeAfterAuth`).
7. ✅ **DONE** (adapted) Integration test composing the REAL stack against a fake Hub — `apps/mobile/__tests__/sync-integration.test.ts`: `OpsHubSyncTransport`(+tokenProvider)→`SyncEngine`→idempotent ledger (push folds the accepted token with a fresh per-request bearer; re-delivered change page records once), and `createTusFetch`→`TusUploadClient` full multi-chunk upload (server hash on the final chunk). Drives the components directly rather than through `wireAppRuntime` (the swap at 5–6 is the on-device flip).

> **Net: items 1–4 + 7 done headlessly; only the live FLIP (5–6) — swap `PlaceholderSyncTransport`→`OpsHubSyncTransport` and the tus stubs→`TusUploadClient` in `wireAppRuntime`, return `SyncEngine`, add the gated loop — remains, and it changes live sync behavior so it is owner-gated for the on-device pass. The flip is now ~a dozen lines wiring already-tested pieces.**
**Dependencies (Hub):** live `POST /sync/commands`, `GET /sync/changes`, `POST /sync/uploads` + tus `HEAD/PATCH`, and append-only adjudication of `dvir.submit`/`jhajsa.submit`/`print.event`/`attachment.link`. **This is the gating Hub prerequisite for Phases 6–8 end-to-end.**

### (f) 24-hour offline policy + Sync Center
See Phase 8. Durable last-Hub-contact + `offline_policy_state` + graduated gate + Sync Center + `diagnostic_logs`. Honest persistence is the core requirement (a restart must not reset the offline clock).

### (g) Local SQLite schema additions/migrations
Add (transactional, versioned, `PRAGMA user_version`-gated, following the existing v3 table-rebuild pattern for new CHECK columns):
- `location_evidence` (Phase 7), `receipt_drafts` (Phase 5), `offline_policy_state` (Phase 8), `diagnostic_logs` (Phase 8).
- Decide and document `sync_changes` (real applied-changes ledger vs frontier-token-only), and `form_evidence_events`/`print_events` (true append-only audit tables vs derived-from-`sync_outbox`).
- Add a schema-mapping note (`src/data/README.md`): which spec-section-10 tables map to which physical tables, and that `auth_session_metadata` (SecureStore) and `hub_config_cache` (build env) deliberately live outside SQLite — so the 10-vs-18 delta is intentional and auditable.

---

## 5. Explicitly DEFERRED / TO REMOVE

**Out of scope for Mobile v1 (keep out — re-list in the triad contract's "Deferred but tracked"):** FieldNav, turn-by-turn navigation, route optimization, map tile downloads, AutoPi integration, vehicle telemetry, fleet GPS tracking.

**Removal status — already done.** Commit `b4e0b36` deleted the entire navigation/map/routing/AutoPi/telemetry stack: `src/adapters/location/{AutoPiLocationProvider,PhoneLocationProvider}.ts`, `src/adapters/map/MapLibreRouteAdapter.tsx`, `src/runtime/navRuntime.ts`, `src/data/TilePackageFileStore.ts`, `packages/contracts/src/{location,nav,mappackage}`, ADRs 005/006, and all nav/map tests. The current tree has no maplibre/react-native-maps/nav/tile/routing dependency; `@react-native-community/geolocation` is intentionally allowed only for validation-only single-shot GPS evidence and is guarded by `nav-stays-out.test.ts`.

**The only "convert to validation-only" item** is the *new* `LocationEvidence` DTO (Phase 7) — it is a fresh single-shot GPS-evidence model, **not** a revival of the deleted streaming `LocationProvider` stack. Do not re-add any mapping/tile dependency.

**Outstanding cleanup (documentation, not code):** the deferral itself is currently **untracked** because the deferred-scope list was deleted rather than retained — Phase 0 closes this. The ADR-005 "nav is disposable / no field-store reference" isolation invariant is gone, so the guard test in Phase 0 is what prevents silent re-introduction.

---

## 6. Immediate next steps (this week)

Smallest path to a real end-to-end loop on the iPhone against the **local** opshub Hub:

1. **Start the real Hub.** In `/tmp/opshub`: `make up`; confirm `curl --noproxy '*' -fsS http://127.0.0.1:8000/api/health`. Note the host machine's LAN IP.
2. **Point the dev build at it.** Set `APP_ENV=dev` and `OPS_HUB_URL_DEV=http://<LAN-IP>:8000`; rebuild the iPhone Xcode dev build.
3. **Fix the three gating assignment wire-breaks** (Phase 3 tasks 1–3) — without these, sign-in succeeds but the assignment list is empty against the real Hub:
   - `latest_server_version` string parse (`assignments.ts:78-88`, `hubGateway.ts:107`),
   - `job_type` object parse (`assignments.ts:118`),
   - `workflow_requirements` shape (`packages/contracts/src/fieldwork/forms.ts:112-122`).
4. **Sign in and pull real assignments.** Verify `HubAuthApiV1` login + `getSessionStatus` + `getAssignments` against opshub; confirm assignments render in the existing (single-screen) UI and survive a restart.
5. **Submit one real ticket.** Use the existing V1 submit path (`OpsHubV1Client` → `POST /api/v1/sync/submit`) for an assigned SR with a clocked-in driver; confirm a 201 accepted outcome and that the local evidence marks durable only on accept. (A throwaway draft can be seeded to exercise this before the TicketCaptureScreen lands in Phase 5.)
6. **Run the validation gates** (Section 7) green, then commit on a branch.

Result: login → session gate → real assignments → real ticket submit, fully against the local real backend — the spine the rest of the phases hang off.

---

## 7. Validation gates

Run from the repo root before every phase is called done (workspace-wired in `package.json`):

```bash
npm run typecheck     # tsc --noEmit
npm test              # jest
npm run lint          # eslint .
npm run format:check  # prettier --check .
npm run bundle:check  # export ios (iOS-only)
```

Rules:
- **CI must never require the physical PT-210.** Printer paths are tested through the durable queue + diagnostic abstraction (`SqlitePrintJobStore`, `Pt210DiagnosticScreen`) and mocks only; the physical printer is an owner-driven manual checklist (Phase 9 / spec 14.5), never a CI gate.
- **No-secrets CI** stays separate from the owner-gated Xcode Archive build/sign/distribute (JS ships in the iOS binary — no OTA); store/build credentials are not committed.
- Every new durable table and capture path must carry a test asserting the never-silently-lose-work invariant (preserve-until-acked, non-evictable) — extend eviction/purge protections to `receipt_drafts` and `location_evidence` as they are added.
- The Phase-0 guard test (no `maplibre`/`react-native-maps`, no nav/map/tile imports) runs in CI to keep FieldNav out.

---

## 8. Progress log

### 2026-06-15 — Baseline reset + Phase 3 wire-contract fixes (this session)
- **Baseline decision.** The working tree carried ~1800 lines of broken, uncommitted prior-session drift (App.tsx +1064, FieldRuntimeScreens +476, a new `app-shell.test.tsx`) — **43 typecheck errors**, and it was an *expansion of the flat single-screen* `FieldSessionScreen`, not the Section-4a nav refactor. The committed HEAD (`b4e0b36`) was fully green (typecheck + 295 tests). **Built forward from green HEAD.** The drift is preserved and recoverable three ways: branch `wip-drift-backup-2026-06-15`, `git stash@{0}`, and `/tmp/wip-drift-2026-06-15.patch` (3089 lines). Revisit before deleting those.
- **Real Hub is live.** opshub `make up` on `:8000` with a LAN-reachable HTTP URL. Seed has driver users but **no assigned SRs** — seeded SRs are all `requested`/unassigned. To verify assignments, one seed SR was assigned to a seed driver directly in the local dev DB as a reversible fixture. `/auth/login`, `/sync/session-status` (incl. `server_time`), `/sync/assignments` all confirmed.
- **Phase 3 tasks 1–5 complete + verified** against the real payload (see Phase 3 block). Commits on branch `feat/phase3-assignment-wire-fixes`: docs plan, wire-break fix, real-Hub fixture test, typed-field extensions. All 5 gates green (typecheck, 302 tests, lint, prettier, iOS export).
- **Gotchas found via the real payload** (would have been missed by hand-written fixtures): `latest_server_version` is the string snapshot hash; `job_type` is `{id,name}`; `geofence_hints.source` is `""` and well `lat`/`lon` are `null` for an SR with no coordinates — all optional-geo parsing must tolerate empties.
- **Additional slices completed this session (all 5 gates green, branch `feat/phase3-assignment-wire-fixes`, 324 tests):**
  - **Phase 2 (partial):** consume `server_time` + the `since` alias from session-status (`HubSessionStatus.serverTime?`, `clockedInSince` falls back to `since`). Still TODO: split boot-failure states (Hub-unreachable vs DB-error) — deferred (touches App.tsx, coordinate with nav shell).
  - **Phase 5 (partial):** corrected submit error mapping — surface `snapshot_drift` on accepted 201 (was swallowed), fix the 409 mapping (real Hub 409 = workflow guard, not idempotency; default code `workflow_blocked`), 412/422 reframed as defensive. Verified live: 201/duplicate/403/409/201+drift.
  - **Phase 0:** `nav-stays-out.test.ts` guard (allows `@react-navigation` + `@react-native-community/geolocation`, forbids the FieldNav map/tile/routing/AutoPi stack) + README scope line + triad-contract "Deferred but tracked" re-add.
  - **Section 4e (de-risk + fix):** V2 sync transport (`/sync/commands`, `/sync/changes`) verified wire-correct against the real Hub (fixture + test) — remaining 4e is wiring, not contract fixes. Fixed the tus PATCH 409 ambiguity: `TusOffsetConflictError` (resumable) vs `TusHashMismatchError` (fatal → engine expires), keyed on `Upload-Sha256`.
  - **Phase 8 (core):** pure `evaluateOfflinePolicy` state machine + `offlineAllowsNewWork` + `OFFLINE_OVER_LIMIT_REVIEW_REASON`, AND the durable `offline_policy_state` store (migration v8 + `SqliteOfflinePolicyStore`, monotonic-forward; real restart test proves the clock can't reset). Wiring (graduated gate, Sync Center, last-contact updates) still TODO.
  - **Phase 3 UI (built, headless-verified):** pure `assignmentInbox` logic (per-SR sync rollup + 7 filters); `AssignmentInboxScreen` (card list + 7 filter chips with counts, controlled selection); enriched `AssignmentDetailScreen` header (SR request_no + status badge + optional display-only sync-state surface + trailer). All via react-test-renderer.
  - **Phase 5 UI (built):** `TicketCaptureScreen` makes the durable ticket-draft store WRITE-LIVE (was write-dead) + `ReceiptCaptureScreen` + `ReceiptDraft` model/migration-v9/`SqliteReceiptDraftStore` (the ticket+receipt package, 7.10). Author/edit one draft per SR, fields map 1:1 to the V1 submit payload; validation + clock-gate enforced; receipt round-trip survives restart.
  - **Phase 8 UI (built):** `summarizeSyncCenter` + `SyncCenterScreen` (spec 7.15 plain-language buckets — never shows un-accepted work as synced; a 403/409 block reads "waiting on you", not "synced").
  - **Workstream (b) started:** `src/design/theme.ts` (spec-8.2 palette / 8.3 type scale, Field Green replaces teal) + dep-free `StatusBadge` (8.6, text+symbol never color-alone), adopted in the inbox card + 7.6 detail.
  - **Phase 5 model:** `FieldTicketDraft` widened additively with hauling fields (truck/trailer/driver/notes) + `captureMethod` (migration v10; V1 submit path unchanged).
  - **Section 4e prerequisites (items 1–4 + 7) DONE headlessly** (none flips live behavior — `PlaceholderSyncTransport` stays in production): per-call `tokenProvider`; `createTusFetch`; tus 409 disambiguation; idempotent `applyChanges` via the durable `sync_changes` ledger (v11); and an integration test composing the real transport+engine+ledger+tus against a fake Hub. Go-live flip = minimal wiring of tested code.
  - **Phase 4:** unsafe-vehicle rule enforced (`defectsCertifiedSafe=false` pre-trip DVIR blocks field work + escalates to review, ahead of the step gate — was captured, now consumed).
  - **Phase 2:** boot-failure classifier (`classifyBootFailure` — reset ONLY on DB key mismatch, never auto-wipe) wired into App.tsx's pre-nav gate.
  - **ALL FIVE TAB CONTENTS BUILT + tested** (so the nav shell is pure mounting): **Today** (`TodayScreen` priority ladder), **SRs** (`AssignmentInboxScreen` + `AssignmentDetailScreen`), **Capture** (existing `CaptureEvidenceScreen`), **Sync** (`SyncCenterScreen`), **More** (`MoreScreen` settings/about). Plus `TicketCaptureScreen`/`ReceiptCaptureScreen` and `LocationValidationScreen`.
  - **Phase 8 diagnostics:** `diagnostic_logs` store (v12) + secret-free `buildDiagnosticReport` (backs Sync Center / More copy-diagnostic).
  - **Phase 7 data layer + UI (headless):** validation-only `LocationEvidence` DTO + 8 states + pure haversine `classifyLocationEvidence` (never fabricates `verified`); `location_evidence` table (v13) + append-only non-evictable store; `LocationValidationScreen` driving an injected single-shot GPS seam. Only the Hub-coordinated sync-wire op shape remains.

### 2026-06-23 — iOS repo native GPS capture wiring
- **Validation gate repaired on macOS:** the contracts Vitest runner could not start because the Rolldown darwin-arm64 optional binding was absent from this checkout. Added the explicit optional binding for the contracts workspace; contracts tests now run locally on the iOS repo.
- **Phase 7 native GPS seam wired:** installed `@react-native-community/geolocation`, added a validation-only `captureValidationGps()` adapter that requests foreground permission and calls one-shot `getCurrentPosition` (no background task, no `watchPosition`, no geofencing, no map dependency), and injected it into `LocationValidationScreen`.
- **Phase 7 location sync client marker wired:** added `location.evidence` to the generated sync op list, added `LocationEvidenceSyncService`, wired it into the production runtime after Location panel saves, and tightened `location_evidence` to append-only so duplicate ids cannot overwrite prior evidence.
- **Phase 8 offline-policy baseline wired:** `AppController` now records durable last-Hub-contact on successful login/session-status/check-gate, `SyncEngine` records contacts after successful `/sync/commands` and `/sync/changes` exchanges, `wireAppRuntime` passes the `SqliteOfflinePolicyStore`, and the Sync/More surfaces read the persisted timestamp. The over-24h graduated gate remains intentionally separate.
- **Phase 6 photo/import seam wired:** installed `react-native-image-picker`, added `captureEvidenceImage()` for camera and photo-library still images, removed the synthetic-byte path from `CaptureEvidenceScreen`, and injected the real adapter from `App.tsx`. Cancel/permission-denied records nothing and reports "Capture canceled or unavailable" instead of inventing evidence.
- **Phase 6 signature seam wired:** `CaptureEvidenceScreen` now reuses the shared drawn `SignatureField` and persists the serialized-vector bytes through `CaptureFlow.captureSignature`; unsigned signatures save nothing and show a warning instead of fabricating an attachment. Signature records use `application/octet-stream`, matching the DVIR/JHA vector artifact path.
- **Phase 4 work-start client marker wired:** added `work.start` to the generated sync op list, preserved Hub `employee_id` on the unlocked field gate, added `WorkStartService`, wired it into the production runtime, and surfaced a Job Overview Start Work action/status. The phone queues immutable evidence only; Hub still owns authorization, competing-event correlation, SR-lock derivation, and any needs-review outcome.
- **Native runtime/version kept honest:** added the geolocation and image-picker permission strings (field-work-validation copy) directly to the tracked iOS `Info.plist`, ran `pod install` so `RNCGeolocation`/`react-native-image-picker` are in `Podfile.lock`, and bumped the iOS bundle version to `1.0.1` (`CFBundleShortVersionString` / Xcode build settings).
- **Verified:** typecheck, the new location/image adapter tests, `nav-stays-out`, `field-runtime-screens`, and `plutil -lint` pass. Full-suite verification follows after this slice.

- **Owner-gated (needs an on-device dev build — NOT done headlessly):** the `@react-navigation` 5-tab nav shell (native deps + `pod install` + version bump — mounts the built screens), remaining native capture (Phase 6 — document-picker/native PNG signature export where the Hub contract accepts it), PT-210 (Phase 9), the **4e go-live FLIP** (items 5–6: swap PlaceholderSyncTransport→OpsHubSyncTransport + tus stubs→TusUploadClient, return SyncEngine, gated background loop — changes live sync behavior), and the full on-device login→…→sync loop.
- **Phase 8 graduated gate wired conservatively:** a Hub-unreachable refresh keeps work actionable only when the current app session already had a Hub-proven unlocked gate and the durable last-Hub-contact window is still within limit. Cold offline startup does not invent a clock-in; over-limit locks new work with a driver-readable reconnect message.
- **Ticket handoff cleaned up:** JHA Complete now opens the write-live `TicketCaptureScreen` directly instead of a presentational field-ticket wizard that could reach a draft-missing dead end. The old `fieldticket` work panel and local `FieldTicketFlow` wrapper were removed, with a truth-in-UI guard to prevent reintroduction.
- **Remaining headless options (lower-value / deferred):** per-assignee signature roles + Hub-configured DVIR/JHA checklists (model redesign + Hub-config dependency); EN/ES i18n (churns label tests); `react-native-vector-icons` in StatusBadge (native dep → on-device); the breaking `FieldTicketDraft` service-work variant (on-device UX validation).
- **Pre-auth SOP access wired:** the sign-in screen now exposes "View SOPs", reusing the same single-list SOP browser/reader as the authenticated SOP tab so required safety procedures are readable before login without a Hub session. Future Hub-hosted unauthenticated SOP sync can replace the local/offline fallback without changing the entry point.
