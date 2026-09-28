# Deep-research prompt 3 — Field Capture offline sync protocol & conflict policy

Paste into GPT deep research. Self-contained.

```text
You are a distributed-systems engineer specializing in offline-first mobile sync. Research and DECIDE the sync protocol and conflict-resolution policy between an offline mobile app and a central authoritative server, then justify it with cited evidence.

PROJECT CONTEXT:
System "Field" has three main nodes:

1. Ops Hub:
   - Central FastAPI server
   - React/Vite frontend
   - SQLite or relational database
   - Self-hosted on an office Windows PC
   - Single source of truth

2. Field Time:
   - Raspberry Pi NFC time-clock
   - Also a sync client
   - Uses local queue, idempotency keys, dependency ordering, and retry/backoff behavior

3. Field Capture:
   - Offline-first phone app for drivers, dispatchers, and managers
   - Runs on personal phones, many low-end Android devices
   - Caches role-scoped data
   - Submits field work and syncs later

A future cloud server may sit above the office server, with the office server acting as a local cache/redundancy node.

The owner's primary architectural fear is race conditions and conflicting authority across:
- Phone
- Mobile app
- Ops Hub
- Field Time
- Other devices
- Office server
- Future cloud server

Core rule:
Field Capture should cache data and submit updates, but it must not create conflicting authority. Ops Hub remains the hub and source of truth.

DATA AND WORKFLOW CONSTRAINTS:
1. Service Requests:
   - Each SR has one owner
   - Each SR may have optional assistants
   - Before work starts, a dispatcher may reassign or edit an SR
   - After work starts, ownership is locked or controlled for accountability, ticket integrity, and safety integrity

2. Work-start events:
   Work may be considered started when any of these occur:
   - JHA/JSA signed
   - Driver marks arrived/started
   - Time/location/work event submitted
   - Field ticket started
   - Photo/document uploaded
   - Other configured work-start marker

3. JHA/JSA safety signatures:
   - Append-only
   - Multiple signers per SR
   - Legally/safety sensitive
   - Must never be lost
   - Must never be silently overwritten

4. Field tickets:
   - Created in the field
   - May be offline
   - May include structured fields and photos
   - Must be retry-safe
   - Must avoid duplicates from flaky network retries

5. Photos and document uploads:
   - Field-ticket photos
   - Disposal-ticket photos
   - Receipt photos
   - Signature images if applicable
   - Uploads may be large and must handle poor cellular signal

6. Printed receipts:
   - Local print-job queue exists on the phone
   - Printed tickets are output artifacts
   - Hub is truth, not the printed paper
   - Print events should be logged locally and later synced to Hub

7. Cached reference data:
   - Employees
   - Permissions
   - NFC card validity
   - Revocations
   - Employee fired/inactive status
   - Job/SR assignment references
   This data flows from Hub to Mobile and must be invalidated quickly when employee/card status changes.

8. Connectivity:
   - Rural/oilfield connectivity is intermittent
   - Users may have poor/no signal
   - Sync must tolerate duplicate sends, partial sends, app restarts, and retries

DECISION REQUIRED:
Recommend a concrete sync and conflict model covering:

1. Sync transport/pattern:
   Evaluate:
   - REST pull/push with change tokens
   - Server sync log / oplog
   - Client event log
   - CRDTs
   - Off-the-shelf sync engines such as PowerSync, ElectricSQL, WatermelonDB sync, Couchbase Lite/Sync Gateway, Replicache, or others
   - Custom sync

   Evaluate fit for:
   - Self-hosted backend
   - Windows PC server
   - SQLite or relational database
   - Low-end phones
   - Solo developer
   - Future cloud/office split

2. Conflict policy per data type:
   Decide which data should use:
   - Server-authoritative reject
   - Append-only merge
   - Last-write-wins
   - Manual conflict review
   - CRDT-style merge
   - Immutable event log

   Explicitly map the SR "locked after work starts" rule to a concrete conflict strategy.

3. Identity of writes:
   Recommend:
   - Client-generated UUIDs
   - Idempotency keys
   - Dependency ordering
   - Local monotonic sequence numbers
   - Server-assigned sequence numbers
   - Content hashes
   - Retry/backoff behavior
   - How to prevent duplicate submissions over flaky links

   Align with the sibling Field Time device, which already uses sync-queue idempotency keys, dependency ordering, and retry backoff.

4. Photo/document upload sync:
   Include:
   - Resumable uploads
   - Content hashes
   - Duplicate detection
   - Retry-safe object/file sync
   - Upload session IDs
   - Chunking vs whole-file upload
   - Server confirmation before local purge
   - Handling partial upload failure
   - Handling duplicate images from retries
   - Linking uploaded files to SR/field-ticket records

5. Reference-data invalidation:
   Recommend:
   - Fast push mechanism, possibly MQTT if already used in system
   - Pull fallback
   - Sync tokens
   - Revocation snapshots
   - Safe offline behavior
   - Fail-open vs fail-closed policies for permission/card checks

6. Future cloud-aware design:
   Ensure the model still works if:
   - Cloud becomes primary
   - Office server becomes local cache/edge node
   - Mobile clients sometimes talk to cloud
   - Office devices sometimes talk to local server
   - Sync must avoid split-brain authority

DELIVERABLE:
Provide:

1. Recommended sync architecture with labeled data flow.

2. Specific recommendation:
   - Build custom
   - Adopt named open-source sync engine
   - Hybrid approach
   Include reasons tied to self-hosted backend, low-end phones, and solo-dev constraints.

3. Per-data-type conflict-resolution table covering:
   - SR header
   - SR assignment/owner
   - SR assistant list
   - Work-start marker
   - JHA/JSA signatures
   - Field ticket structured data
   - Photos/documents
   - Print jobs
   - Reference data
   - Employee/card revocations
   - Mobile settings
   - Logs/audit events

4. Concrete handling of the SR lock invariant:
   - How server enforces "before work starts editable, after work starts locked"
   - What happens when an offline client submits a stale edit
   - What happens when a dispatcher reassigns while a driver is offline
   - What happens when a driver starts work offline
   - What requires manual review

5. Idempotency and duplicate-prevention design:
   - Key format
   - Server storage
   - Retry behavior
   - Dependency handling
   - Event ordering
   - Duplicate photo detection using content hashes

6. Offline safety rules:
   - What can be allowed offline
   - What must wait for Hub
   - What becomes read-only offline
   - How revoked/inactive employees/cards behave offline
   - How expired cached permissions behave

7. Failure modes:
   - Race conditions
   - Duplicate uploads
   - Stale SR edits
   - Revoked user continues offline
   - Partial photo upload
   - Conflicting dispatcher/driver changes
   - Office/cloud split-brain later
   - How the design prevents or contains each

Rules:
- Hub remains source of truth.
- Mobile must not independently decide final authority.
- Append-only safety signatures must not be overwritten.
- Unsynced photos and print records must not be silently deleted.
- Prefer authoritative sync-engine docs, distributed-systems papers/writeups, and CRDT literature.
- Prefer sources from 2022-2026.
- State confidence and key assumptions.
```
