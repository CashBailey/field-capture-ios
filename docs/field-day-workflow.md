# Field Capture — A Field Day (DRAFT)

> **Status: DRAFT — not yet confirmed by an actual driver/field worker.** This is the owner's
> best understanding of the daily flow, written down so the app's records line up with real
> work. Treat it as a sketch to confirm, _not_ settled requirements. Terms are defined in
> [glossary.md](glossary.md).

## The shape of a day

1. **Pre-trip checklist (start of day).** Before driving, the worker inspects the
   vehicle/equipment and records the **pre-trip checklist**.

2. **The jobs — a series of Service Requests (SRs).** Through the day the worker handles a
   number of SRs. For **each evolution** (each task/operation within the work):
   - Complete a **JSA/JHA** safety analysis _before_ starting the task.
   - Do the work.
   - Record the **field ticket** for the work done.
   - Print the ticket/receipt — _(printer is a placeholder for now)_.

3. **Post-trip checklist (end of day).** After the day's driving, the worker completes the
   **post-trip checklist**.

## What this means for the app (preliminary)

- The app must capture, at minimum: **pre-trip checklist**, **JSA/JHA** (per evolution),
  **field tickets**, and the **post-trip checklist** — plus photos/signatures attached to them.
- Safety records (checklists, JSA/JHA, signatures) are **append-only evidence** — added, never
  edited or deleted.
- Field tickets are the **work / billing record** — editable as a draft, **locked once
  submitted**.
- Everything must work **offline** and sync to the Hub later; nothing is lost without signal.
- **Printing is an output**, not a source of truth — and is a placeholder for now.

These line up with the existing contracts in `packages/contracts/` (append-only signatures,
field-ticket draft→submit immutability, durable print-job queue).

## To confirm with an actual driver

- Is **SR** the right unit of work? Does one SR contain multiple **evolutions**, and what
  exactly counts as an evolution?
- Is **JSA/JHA** done once per SR, or genuinely before _every_ task?
- What's actually **on** the pre-trip and post-trip checklists?
- What gets **printed**, and when — per ticket, per SR, or end of day?
- Are **disposal / receipt photos** part of this flow, and where do they attach?
- Does clocking in/out (Field Time) bracket this day, or is that fully separate?

## Implemented runtime (2026-06-10 field-runtime slice)

The workflow above now has a tested, hardware-free runtime:

- **DVIR/JHA forms** (`FieldWorkflowService`, contracts `fieldwork/forms.ts`): pre-trip DVIR,
  per-SR JHA/JSA, post-trip DVIR. Drafts persist in SQLite (`field_forms`, migration v5);
  completion is validated (all items answered, defects need notes + a safe-to-operate
  certification, signatures required); completed forms enqueue as append-only
  `dvir.submit` / `jhajsa.submit` evidence events through the durable sync outbox. Once
  enqueued a form is frozen; needs-review/rejected outcomes are preserved with Hub's verbatim
  reason and do NOT satisfy their workflow step.
- **Required-step gating**: Hub config (`require_pre_trip_dvir`, `require_jha_per_sr`,
  `require_post_trip_dvir`) gates ticket submission via `checkTicketSubmitAllowed` — the app
  blocks with the exact missing steps; Hub still re-validates every submit.
- **Photos/signatures** (`CaptureFlow`): camera/import/signature-pad capture for
  field-ticket/disposal/receipt photos and signatures; SHA-256 anchored at capture; bytes
  stored under the app's private documents directory via `FileBlobBytesSource`; bytes are
  purgeable only after upload + attachment-link both commit on Hub.
- **Clock gate**: every field action (drafts, completion, form submit, capture, ticket
  submit) is non-actionable while the TimeClock clock gate is locked, with the reason
  surfaced.
- **Printing** stays an output artifact: durable queue + print events synced to Hub; the
  PT-210 prints over iOS BLE GATT (CoreBluetooth), with real printer verification remaining
  hardware-manual (see docs/printer-pt210.md).
- **Screens** (`apps/mobile/src/screens/FieldRuntimeScreens.tsx`): the app shell now exposes
  assignment detail, Workflow, Capture, and Print panels. Assignment detail renders Hub's
  richer active-job context when present (customer, lease, well(s), material, disposal, vehicle,
  job type, workflow requirements, snapshot hash/version) and shows clean `unknown` states for
  legacy/minimal assignment payloads. The runtime panels render locked states, validation errors,
  frozen/accepted/rejected/needs-review form states, explicit capture labels (`upload pending`,
  `uploading`, `uploaded`, `linked`, `failed`, `needs-review`), local capture preservation, and
  print hardware-not-available failures while calling the existing runtimes.
- **Rich assignment metadata**: workflow requirements are read from normalized assignment
  metadata first and legacy `snapshot.workflow_requirements` second.

Still open with the driver: the questions above.
