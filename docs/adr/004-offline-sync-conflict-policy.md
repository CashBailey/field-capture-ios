# ADR 004 — Offline Sync and Conflict Policy

## Status

Accepted (foundation phase). Contracts only in the foundation; full engine is later slices.

## Context

Ops Hub is the single source of truth (self-hosted FastAPI on a Windows PC). Field Capture
is offline-first on low-end iPhones with intermittent oilfield connectivity. Field Time (Pi
clock) is a sibling sync client already using sync-queue idempotency keys, dependency
ordering, and retry/backoff. The owner's primary fear is race conditions / conflicting
authority across phone, mobile, Hub, Time, office server, and a future cloud server. Hard
invariants exist (SR lock after work starts; append-only safety signatures) that are
coordination/invariant problems, not free-merge problems — so CRDT-style auto-merge is the
wrong core model.

## Decision

**Hybrid custom architecture, server-authoritative for business data:**

- Local SQLite is the on-device read source + outbox queue + local blob store + print queue.
- Mobile submits **commands and immutable events** with strong write identity; it does **not**
  sync arbitrary row state upward. Hub validates transactionally and accepts / rejects / flags
  for manual review. Conflict resolution lives in exactly one place: Hub.
- Down-sync via a **server-issued monotonic change token** `<authority_epoch, commit_seq>` —
  the server defines the version frontier, never client timestamps.
- Optimistic concurrency via `base_version` / `If-Match`; `428` on missing precondition, `412`
  on stale.
- Photos/documents via **tus-style resumable uploads**; blob dedupe by content hash; separate
  append-only attachment-link command; local copy purged only after Hub confirms upload **and**
  link commit.
- Append-only records for JHA/JSA signatures, work-start evidence, print events, audit logs.
- **CRDTs are not the core business conflict model** (at most narrow non-authoritative UI state).

Per-data-type conflict policy:

| Data type | Policy |
|---|---|
| SR header | Server-authoritative reject w/ version precondition; editable only while unlocked |
| SR owner / assignment | Server-authoritative reject; dispatch roles only; before lock only |
| SR assistants | Server-authoritative replace before lock; controlled after lock |
| Work-start marker | Immutable event; first accepted authorized event locks the SR on Hub |
| JHA/JSA signatures | Append-only; never overwrite/delete |
| Field ticket draft | Client-generated ID, versioned edits, immutable after submit except correction workflow |
| Photos / documents | Immutable blobs + append-only attachment links |
| Print jobs | Output-artifact events, not source of truth |
| Reference data | Hub → Mobile only |
| Revocations / firings / permissions | Hub authoritative; fast invalidation hint + pull fallback; fail-closed when stale |
| Mobile settings | LWW allowed only for non-authoritative local prefs |

Write identity (consistent with Field Time): client-generated UUIDs (UUIDv7), idempotency
keys (`gtr:<device_instance_id>:<local_seq>:<op_uuid>`), local sequence numbers, dependency
ordering, retry/backoff with jitter, durable outbox, server-stored idempotency ledger.

SR lock invariant enforced as a **Hub transaction**, not a client convention. Stale offline
edits are rejected (not auto-merged) with a fresh snapshot. Offline work-start captured under
a since-changed assignment is **preserved as evidence, SR frozen, flagged for manual review** —
the phone never retroactively wins authority, but evidence is never discarded.

Future cloud: **one writer per `authority_epoch`**; cutover increments the epoch; non-lease
edge nodes are read/relay-only. No active-active office/cloud writers.

## Consequences

- Foundation ships **contracts/types only** (Slice 3 + 4): outbox model, idempotency key
  model, command/event envelopes, change-token contract, resumable-upload contract,
  print-event sync contract, SR lock rules, signature append-only model, ticket draft model,
  photo attachment model, print job model. **No full Hub or sync engine yet.**
- Hub will later need tables: `change_log`, `idempotency_ledger`, `audit_events`,
  `upload_sessions`, `attachments`.
- Mobile must implement durable persistent-queue semantics like Field Time.

## Rejected alternatives

- **CRDT-first** — auto-merge can't enforce exclusive ownership / lock / no-silent-overwrite.
- **ElectricSQL** — read-path only, no write sync, assumes Postgres; still leaves the hard
  layer to build.
- **PowerSync** — strong if Field later standardizes on Postgres/MySQL/SQL Server; today too
  big an operational step for a solo dev on Windows; doesn't remove domain conflict policy.
- **WatermelonDB sync** — usable as local DB, but its push-fails-on-remote-change model and no
  conflict listing don't fit SR lock rules; not the governing conflict model.
- **Replicache** — good protocol ideas (ordered mutations, version cookies) but maintenance
  mode + web-first; borrow ideas, don't adopt.
- **Couchbase Lite + Sync Gateway** — LWW default is wrong for ownership/safety; too much stack.

## Implementation impact

- Slice 3: sync foundation contracts. Slice 4: field-work data model contracts.
- Printer (Slice 1) print events conform to the print-event sync contract.
- Resource budget (ADR 002) protects unsynced outbox items, photos, print records.

## Open questions

- Backend DB final choice (SQLite vs Postgres) affects later off-the-shelf options.
- Regulated retention for signatures/attachments → formal Hub retention policy.
- Exact manual-review triggers and TTLs are business decisions.

## Source report references

- `research/reports/03-sync-conflict-report.md` (primary)
