# Deep-research prompt 1 — Field Capture storage & memory budget

Paste into GPT deep research. Self-contained.

```text
You are a senior mobile architect. Research and DECIDE a concrete storage, memory, and cellular-data budget for a field-operations mobile app, then justify it with cited evidence.

PROJECT CONTEXT:
"Field Capture" is the field app in an oilfield-services system.

The larger system has:
- Ops Hub: central FastAPI/React server, self-hosted on an office Windows PC, source of truth
- Field Time: Raspberry Pi NFC time-clock
- Field Capture: phone app for drivers, dispatchers, and managers

Ops Hub is the single source of truth. Field Capture is offline-first. It caches only role-scoped data. A driver gets driver-relevant data, not the whole company database. The app submits updates and syncs when connectivity returns.

Workers use their own personal phones. Many may be low-end or budget Android phones.

Field Capture must hold:
- Service Requests
- Field tickets
- JHA/JSA safety documents and signatures
- Cached employee/permission/reference data
- Captured field-ticket photos
- Captured disposal-ticket/receipt photos
- Durable offline print-job queue
- Generated receipt/ticket render data for a handheld thermal printer

PRINTER/PRINT-JOB DETAIL:
The owner purchased a PT-210 58 mm portable handheld thermal receipt printer, Amazon ASIN B0CL4853RB.

Field Capture must print field tickets and JHA/JSA confirmation receipts directly from inside the app. Print jobs must be queued durably on-device so they survive app restart and can print offline, then sync status to Ops Hub later.

Each queued print job may include:
- Metadata
- ESC/POS byte stream if supported
- Rendered 58 mm bitmap if needed
- Signature bitmap if included
- Status/error/retry data

This print queue and rendered receipt/ticket data must be included in the storage budget.

DECISION REQUIRED:
Define concrete resource budgets the app must stay within:

1. Max total on-disk app/cache budget.
2. Suggested storage split across:
   - Structured data / SQLite
   - Photos/images
   - Print-job queue and rendered receipt/ticket payloads
   - App binary/install size
   - Logs/diagnostics
3. Max RAM working-set target:
   - Foreground interactive use
   - Camera/photo capture
   - Background sync
   - Print job rendering/printing
4. Max cellular data usage:
   - Per sync cycle
   - Per normal workday
   - Emergency/high-use day
5. Recommended cleanup thresholds:
   - Warning level
   - Soft cleanup level
   - Hard cap level

RESEARCH AND ANSWER:
1. Realistic hardware floor in 2024-2026 for low-end/budget Android phones likely to be used by blue-collar field workers:
   - RAM
   - Total storage
   - Typical free storage
   - CPU constraints
   - Android version support
   Cite real device specs and market/share data where possible.

2. OS limits and practical behavior:
   - Android per-app storage norms
   - iOS per-app storage norms
   - Android low-memory-killer behavior
   - iOS jetsam/background memory behavior
   - Working-set sizes that create practical background-kill risk

3. Comparable offline-first field/logistics apps:
   - Cache-size practices
   - Offline sync storage
   - Photo handling
   - Any published engineering limits or recommendations

4. Photo storage realities:
   - Bytes per compressed field-ticket photo
   - Recommended capture resolution for OCR-readable but small images
   - JPEG/WebP/HEIC tradeoffs
   - Whether to keep original images, compressed images, or both
   - When originals can be purged after Hub sync

5. Print-job queue sizing:
   - Realistic bytes per queued thermal print job
   - ESC/POS text payload size
   - Rendered 58 mm bitmap payload size
   - Signature bitmap size
   - How many unprinted or unsynced jobs to retain
   - How long to keep printed jobs locally before they sync to Hub and can be purged

DELIVERABLE:
Provide:

1. A recommended budget table with two tiers:
   - Conservative tier for low-end phones
   - Comfortable tier for better phones

2. Recommended numbers for:
   - Total app/cache storage
   - SQLite/structured data
   - Photos/images
   - Print-job queue/rendered ticket payloads
   - Logs/diagnostics
   - Foreground RAM target
   - Background RAM target
   - Daily cellular data target

3. Rationale for every number, tied to cited evidence.

4. Eviction strategy:
   - What gets deleted first
   - What must never be silently deleted
   - How to handle unprinted/unsynced print jobs
   - How to handle unsynced photos
   - How to handle old logs

5. Red flags:
   - What breaks if the budget is exceeded
   - User-facing symptoms
   - Sync risks
   - Storage exhaustion risks
   - Background-kill risks

Rules:
- Unprinted/unsynced print jobs are high-value records and must not be silently evicted before they sync to Ops Hub.
- Unsynced field-ticket photos must not be silently evicted before Hub confirms receipt.
- Ops Hub is the source of truth.
- The phone is an offline client, not an independent authority.
- Prefer primary sources: Android docs, Apple docs, device spec sheets, and engineering writeups.
- Prefer sources from 2023-2026.
- State confidence level for each recommendation.
```
