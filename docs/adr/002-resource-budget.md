# ADR 002 — Resource Budget

## Status

Accepted (foundation phase).

## Context

Drivers use personal BYOD iPhones, many low-end. The realistic 2024-2026 floor is
**4 GB RAM / 64 GB storage** (e.g. older / entry-level iPhones still in field use). iOS does
not give a simple "safe per-app allowance," so the app must impose its own quotas and
make purgeability explicit by data class. The app holds structured data, photos (field +
disposal/receipt), a durable print-job queue with rendered payloads, and logs. Exceeding budget
causes capture failures, stuck sync, SQLite disk-full behavior, and iOS jetsam terminations
(the OS kills the app under memory pressure when it exceeds its footprint).

## Decision

**Conservative tier is the default support contract. Comfortable tier unlocks only after
runtime checks.**

Conservative tier (default):

| Item                                | Budget    |
| ----------------------------------- | --------- |
| Total on-disk app/cache hard cap    | 1.5 GB    |
| SQLite / structured data            | 64 MB     |
| Photos / images                     | 384 MB    |
| Print-job queue / rendered payloads | 32 MB     |
| App binary / install target         | 120 MB    |
| Logs / diagnostics                  | 16 MB     |
| Foreground interactive RAM          | 120 MB    |
| Camera / photo RAM                  | 200 MB    |
| Background sync RAM                 | 60 MB     |
| Print rendering / printing RAM      | 80 MB     |
| Cellular per sync cycle             | 1 MB      |
| Normal cellular day                 | 15 MB/day |
| Emergency / high-use day cap        | 60 MB/day |

Comfortable tier:

| Item                                | Budget     |
| ----------------------------------- | ---------- |
| Total on-disk app/cache hard cap    | 3.0 GB     |
| SQLite / structured data            | 128 MB     |
| Photos / images                     | 1.0 GB     |
| Print-job queue / rendered payloads | 64 MB      |
| App binary / install target         | 160 MB     |
| Logs / diagnostics                  | 32 MB      |
| Foreground interactive RAM          | 180 MB     |
| Camera / photo RAM                  | 280 MB     |
| Background sync RAM                 | 90 MB      |
| Print rendering / printing RAM      | 120 MB     |
| Cellular per sync cycle             | 2 MB       |
| Normal cellular day                 | 30 MB/day  |
| Emergency / high-use day cap        | 120 MB/day |

Comfortable tier requires ALL of: RAM ≥ 6 GB, storage ≥ 128 GB, device not flagged as
memory-constrained by iOS runtime checks, free storage ≥ 10 GB.

Cleanup thresholds (warning → soft cleanup → hard cap) per tier as in the budget report.

**Never silently evict before Hub acknowledgment:**

- unsynced field-ticket photos
- unsynced disposal/receipt photos
- unprinted print jobs
- printed-but-unsynced print records
- offline mutations not accepted by Ops Hub
- signatures / safety records not accepted by Ops Hub

Eviction order (safe → protected): logs/diagnostics → temp transcode files → regenerable
thumbnails/cache → (never) the protected list above.

## Consequences

- A `BudgetMonitor` + budget constants module is needed (Slice 2), with category accounting
  and threshold actions (warn, soft-purge regenerable caches, hard-cap blocks new
  non-durable writes).
- Photos normalized to a single canonical ~1600px-long-edge JPEG (~0.75 MB avg); raw capture
  deleted after normalize; full local copy purged 7d conservative / 14d comfortable post-Hub-ack.
- Media sync serialized (one transcode/upload at a time conservative; two comfortable) to
  bound RAM.
- Print queue cheap: 32 MB holds 200+ jobs; durability/replay is the goal, not space.

## Rejected alternatives

- **Comfortable tier as default** — breaks on the 4 GB/64 GB BYOD iPhone floor.
- **Storing both originals and compressed photos** — doubles the dominant storage class with
  no current legal/evidentiary requirement.
- **Parallel multi-photo upload** — media-in-memory-twice risk on low-end devices.
- **Relying on OS cache management** — iOS expects the app to bound its own cache.

## Implementation impact

- Slice 2 implements budget constants, `BudgetMonitor`, cache categories, cleanup rules, and
  never-silently-delete protections with tests.
- Sync (Slice 3) and printer (Slice 1) must mark their durable records as protected.

## Open questions

- Exact per-photo average bytes are engineering estimates; validate against Texas pilot work.
- Legal retention requirements for signature images / attachments (affects purge timing).

## Source report references

- `research/reports/01-resource-budget-report.md` (primary)
