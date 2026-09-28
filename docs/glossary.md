# Field Capture — Glossary

Plain-language definitions of the terms that show up across these docs. Entries marked
_(confirm)_ are our current best understanding and should be checked with someone who does the
actual field work.

## Field work & safety

- **Pre-trip checklist** — An inspection the worker does at the **start of the day**, before
  driving, to confirm the vehicle/equipment is safe to operate. _(confirm)_
- **Post-trip checklist** — The matching inspection at the **end of the day**, after driving.
  _(confirm)_
- **SR (Service Request)** — A unit of assigned work — essentially a job/work order for a
  specific customer or site. A worker may handle several in a day. _(confirm exact meaning)_
- **Evolution** — One discrete task or operation within the work. A safety analysis (JSA/JHA)
  is done before each one. _(term from the owner; confirm exact scope)_
- **JSA (Job Safety Analysis) / JHA (Job Hazard Analysis)** — A short safety document filled
  out _before_ starting a task: it lists the steps, the hazards, and how each hazard will be
  controlled. The two names are largely interchangeable; a company uses one or the other.
  Usually signed.
- **Field ticket** — The record of work performed on site (what was done, quantities, time).
  Often the basis for billing the customer. Edited as a draft, then **locked once submitted**.
- **Work-start marker** — Timestamped evidence that work actually began, so records can't be
  back-dated. Append-only.
- **Signature** — A captured signature on a JSA/JHA or ticket. Stored append-only as evidence —
  never overwritten.
- **Disposal ticket / receipt** — A record (often with a photo) for disposed material, e.g.
  waste or produced water taken to a disposal site. _(confirm)_

## The systems (the "Field" family)

- **Ops Hub** — The central server and the **single source of truth**. Self-hosted
  (FastAPI + React). It orders all changes and keeps the audit trail.
- **Field Capture** — _This project._ The offline-first phone app field workers use.
- **Field Time** — A Raspberry Pi NFC time clock (workers tap to clock in/out). Shares Mobile's
  sync rules.

## Locations (oilfield)

- **Lease / lease area** — A tract of land the company has rights to operate on; contains wells
  and access roads.
- **Well / well location** — A specific wellsite; the destination for much of the work.
- **Gate** — A gate on a lease road; matters for site access.
- **Yard** — A company yard/base where equipment and vehicles are kept.
- **Disposal (site)** — A facility where waste / produced water is taken.

## Sync & data

- **Offline-first** — The app fully works with no signal: it saves everything locally and syncs
  when a connection returns.
- **Source of truth / authority** — The one place that decides what's "true." Here that's always
  Ops Hub; the phone holds copies and pending changes.
- **Outbox** — The phone's durable queue of changes waiting to go to the Hub, in order; survives
  app restarts.
- **Command vs. event** — A _command_ is a request to change something (the Hub may accept or
  reject it); an _event_ is a recorded fact that already happened (e.g., a signature) and can't
  be changed.
- **Idempotency key** — A unique stamp on each change so that if it's sent twice (e.g., after a
  dropped connection), the Hub applies it only once.
- **Change token** — A marker the Hub gives so the phone can ask "what's changed since X?" and
  pull only the new updates.
- **Optimistic concurrency (base_version / If-Match)** — Before editing, the phone says which
  version it's changing; if someone already changed it, the Hub rejects the stale edit instead
  of silently overwriting.
- **Append-only** — Records you can add to but never edit or delete (safety signatures,
  work-start markers, print events, audit) — so evidence can't be altered.
- **Authority epoch** — A version number for "who is the authority." If the system ever moves
  authority (e.g., to a cloud server), the epoch increments so there are never two writers at
  once.
- **tus upload (resumable upload)** — A way to upload big files (like photos) in chunks that can
  resume after a dropped connection instead of starting over.

## Build & app plumbing

- **Bare React Native** — React Native app code with the native iOS project owned directly by
  the repo instead of generated at build time.
- **Xcode workspace** — The iOS project entry point, `apps/mobile/ios/FieldCapture.xcworkspace`.
- **Metro** — React Native's local JavaScript bundler used for Debug builds and Fast Refresh.
- **Native module** — A Swift/Objective-C or platform package bridge that exposes phone hardware or
  system services to the React Native app.
- **ADR (Architecture Decision Record)** — A short document capturing one significant decision
  and why — see [adr/](adr/).
- **Slice** — One independently reviewable, testable chunk of the build plan (Slice 0–7) — see
  the [foundation plan](plans/fieldcapture-foundation-plan.md).
- **Resource budget: conservative vs. comfortable tier** — Limits on storage/memory the app
  obeys. _Conservative_ is the safe default for modest phones; _comfortable_ unlocks more on
  capable devices.

## Printer

- **PT-210** — The first target printer: a 58 mm, handheld, battery-powered, **Bluetooth thermal
  receipt printer** (not a label printer, not a Brother).
- **Thermal (receipt) printer** — Prints by heating heat-sensitive paper (like a store receipt);
  no ink, prints to a paper roll.
- **ESC/POS** — A common command language receipt printers understand; whether the PT-210
  supports it is still unverified.

> Printer support in the code is a **placeholder** for now — see
> [printer-pt210.md](printer-pt210.md).
