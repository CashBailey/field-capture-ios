# Field Sync Protocol and Conflict Policy Recommendation

## Decision

I recommend a **hybrid custom architecture**:

**Use a custom server-authoritative sync protocol for business data, plus a server-side change log for down-sync, plus `tus` resumable uploads for photos/documents.** Mobile should be **offline-first for reads and draft capture**, but **not multi-master for authoritative business state**. Ops Hub remains the only authority that can finalize mutable operational truth such as SR ownership, lock state, permissions, revocations, and accepted record versions. This recommendation fits the stated constraints better than CRDTs or a full off-the-shelf mobile sync stack because Field has hard invariants, safety-sensitive append-only records, intermittent connectivity, low-end Android devices, a self-hosted FastAPI backend, and a solo-developer operational budget. Android’s own offline-first guidance recommends a local on-device source of truth for reads, queued or lazy writes, and WorkManager-backed retry for persistent background draining; HTTP conditional requests and idempotency keys provide the right building blocks to stop lost updates and duplicate submissions; and `tus` is expressly designed for resumable uploads on unreliable mobile networks. citeturn32view0turn32view1turn32view2turn33view0turn33view1turn33view2turn33view4turn36view1turn14view0

The core design choice is this: **mobile does not sync arbitrary row state upward**. Instead, mobile submits **commands and immutable events** with strong write identity. Hub validates those commands against current authoritative state inside a transaction, either commits them and emits downstream changes, or rejects/flags them. That keeps conflict resolution in one place: Hub. Replicache, WatermelonDB, and PowerSync all reinforce parts of this pattern in different ways: ordered atomic mutation processing, explicit push/pull contracts, client queues, and server-authoritative checkpoints. citeturn28view0turn28view1turn28view3turn22view0turn22view1turn21view0

My confidence is **high** on the architectural direction and **medium-high** on the exact operational thresholds such as cache TTLs and manual-review triggers. Those thresholds depend on business preference more than protocol theory.

## Why the alternatives do not fit as well

A **CRDT-first design is the wrong primary model** for Field. CRDTs are built to merge concurrent changes automatically across replicas without requiring a central server. That is powerful for collaborative editing, but Field’s hardest problems are not “merge everything”; they are “do not allow conflicting authority,” “do not silently overwrite safety evidence,” and “enforce exclusive ownership and lock rules.” Those are coordination and invariant problems, not free-merge problems. Inference: because Field requires Hub to reject or freeze some concurrent updates rather than merge them, CRDTs should be limited, at most, to narrow non-authoritative UI state, not core SR workflow. citeturn24search0turn24search3turn24search7turn30view0

**Electric** is a strong read-path technology, but it is not the right primary answer here. Electric syncs data **out of Postgres**, exposes sync as a shape log over HTTP, and explicitly says it **does not do write-path sync**. It tells you to handle writes through your own API and keep Electric on the read path. That is already close to a custom design, and it also assumes Postgres as the backend database. For Field, that means you would still need to build the entire authoritative write/conflict layer yourself, while also standardizing on Postgres and operating an extra sync service. citeturn29view0turn29view1turn29view2turn29view3

**PowerSync** is the strongest off-the-shelf candidate if Field later standardizes on Postgres/MySQL/SQL Server and wants richer role-scoped local SQLite sync. It supports self-hosting, syncs source-database data into a local SQLite database on the client, and keeps a client upload queue. But it still requires a separate service, CDC/logical-replication style database integration, and its docs require that write endpoints apply changes **synchronously and authoritatively** because otherwise checkpoint consistency breaks. That means PowerSync does not remove the need for core domain conflict policy. It helps the transport and local cache problem, but not the hardest business-rule problem. For a solo developer running on a Windows office PC today, that is a bigger operational step than a focused custom protocol. PowerSync becomes more attractive later if Field adopts a replication-friendly relational backend and wants generalized downstream sync without writing its own change-feed machinery. citeturn21view0turn21view1turn21view2turn31view0turn31view1turn31view2turn31view3

**WatermelonDB** is useful as a local database in React Native, and it is performance-oriented on lower-end devices, but its own sync model requires you to build `pullChanges` and `pushChanges`, call synchronization yourself, and return all changes since the last pull. Its limitations page also says that if a record changes remotely between pull and push, the push just fails, and it does not provide a built-in conflict-listing mechanism. That is acceptable for some apps, but it is not the cleanest fit for Field’s SR-lock and stale-offline-write rules. Watermelon can still be used as the local database if the mobile app is React Native, but **not as the governing conflict model**. citeturn25search1turn22view0turn22view1turn22view2

**Replicache** offers excellent protocol ideas: ordered mutations, atomic update of mutation state, pull cookies/global versions, and explicit patch-based sync. But Replicache is a **client-side framework with a bring-your-own-backend model**, and the project is now in **maintenance mode**. It is also web-first in its center of gravity. I would borrow its mutation-ordering and version-token ideas, not adopt it as the mobile sync foundation for Field. citeturn9search1turn28view0turn28view1turn28view2turn28view3turn28view4

**Couchbase Lite + Sync Gateway** is production-grade and supports bi-directional edge/cloud sync, supported Windows Server environments, and conflict resolution machinery. The downside is that it brings an entire document-store sync stack and, in current Sync Gateway releases, defaults to automatic **Last Write Wins** conflict resolution for many distributed scenarios. That is a poor default for SR ownership, safety signatures, and lock invariants unless you reshape the whole application around Couchbase’s document model and custom sync functions. It is more stack change than Field needs. citeturn29view4turn30view0turn30view1turn30view2turn30view3

## Recommended architecture and data flow

The right model for Field is **local-first reads plus authoritative command processing**.

```text
Field Capture
  - local SQLite cache
  - outbox queue
  - local blob store
  - local print queue
        |  POST /sync/commands   (idempotent command/event batch)
        |  GET  /sync/changes?since=<authority_epoch,commit_seq>
        |  POST /uploads/sessions
        |  tus HEAD/PATCH upload URL
        v
Ops Hub
  - auth + permission checks
  - command handler
  - transactional business-rule validator
  - domain tables
  - append-only audit/event tables
  - change_log(commit_seq)
  - idempotency_ledger
  - upload_sessions + blob metadata
  - attachment links
        ^
        |  optional invalidation hints
        |  MQTT or WebSocket, plus pull fallback
Field Time
  - same queue envelope pattern as Mobile
  - narrower command/event surface
```

On the phone, the **local SQLite database is the app’s read source**, which matches Android’s offline-first guidance: repositories read directly from local storage, writes are asynchronous, and queued work is persisted and retried using WorkManager-backed scheduling with chaining and exponential backoff. That is exactly what Field needs on low-end Android devices with intermittent oilfield connectivity. citeturn32view0turn32view1turn32view2turn32view3

On the wire, use **two channels**:

1. **Business sync channel** over HTTPS:
   - `POST /sync/commands`
   - `GET /sync/changes?since=<token>`
   - `GET /sync/reference?since=<token>`

2. **Binary upload channel** using `tus`:
   - `POST /uploads/sessions`
   - `HEAD/PATCH` upload URL
   - `POST /attachments/link`

For mutable business entities, require **preconditions**. Use either HTTP `If-Match` with ETags or an equivalent explicit `base_version` in the command payload. The point is the same: Hub only applies an edit if the client proves it edited the version it actually fetched. If the precondition is missing, return `428 Precondition Required`; if stale, return `412 Precondition Failed`. That is the cleanest way to prevent lost updates and race-condition overwrites on SR headers, assignments, and field-ticket draft edits. citeturn33view0turn33view1turn33view2turn33view3

For down-sync, use a **server-issued monotonic change token**, not client timestamps as the authority signal. Replicache’s global version/cookie model and Watermelon’s server timestamp model both support the same lesson: the server must define the version frontier that clients pull from. In Field, implement this as `token = <authority_epoch, commit_seq>`, where `commit_seq` is a monotonically increasing server commit number assigned when Hub successfully commits a transaction. Clients never declare global order. Hub does. citeturn28view1turn28view3turn22view0turn22view1

## Conflict policy by data type

The governing rule is simple:

**Authoritative mutable state uses server-authoritative reject with optimistic concurrency.  
Safety evidence uses append-only merge or immutable event logs.  
Low-risk per-device preferences may use LWW.  
No core authority-bearing data uses generic CRDT merge.**

| Data type | Chosen policy | Hub behavior |
|---|---|---|
| SR header | Server-authoritative reject | Editable only while SR is unlocked. Requires `If-Match` or `base_version`. Missing precondition: reject. Stale precondition: reject and return fresh snapshot. |
| SR assignment / owner | Server-authoritative reject | Only dispatch-capable server roles may change it. Allowed only before lock. After lock: reject. |
| SR assistant list | Server-authoritative replace before lock | Hub owns the canonical set. Before lock, accept replace/update with precondition. After lock: reject except explicit manager review workflow. |
| Work-start marker | Immutable event log with derived lock state | Every work-start submission becomes an append-only event. The first accepted authorized event sets `work_started_at`, `locked_at`, and `locked_by_event_id`. Later work-start markers append as evidence only. |
| JHA/JSA signatures | Append-only merge | Never overwrite or delete silently. Each signature is its own immutable row/event. |
| Field ticket structured data | Create by immutable client ID, then server-authoritative patch while draft | Ticket creation uses client-generated `ticket_id`. Draft edits require precondition/version. Once finalized/submitted, the ticket becomes immutable except by corrective amendment workflow. |
| Photos / documents | Immutable blobs plus append-only attachment links | Blob storage dedupes by content hash; links are separate records. No in-place overwrite. |
| Print jobs | Append-only event log | Printed artifacts are not truth; only local and server print events are logged. |
| Reference data | Server-written snapshot replication | Mobile caches read-only subsets and only Hub writes them. |
| Employee/card revocations | Server-authoritative snapshot + invalidation | Hub pushes invalidation hints and clients pull fresh snapshots. Privileged offline operations fail closed when this cache is stale. |
| Mobile settings | Last-write-wins per user-device | Safe only for non-authoritative preferences such as UI defaults, printer preference, or local layout. Scope is per device unless explicitly shared. |
| Logs / audit events | Immutable append-only event log | Never edited in place. |

This table encodes the evidence-backed split between optimistic concurrency for mutable authoritative records, append-only handling for evidentiary records, persistent queued writes for offline operation, and client-local databases for responsive reads. citeturn33view0turn33view1turn33view2turn32view0turn32view2turn28view0turn21view0

## SR lock invariant and offline safety

Implement the SR lock invariant as a **server transaction**, not as a client-side convention. When Hub accepts a work-start event for an eligible SR, the same transaction should:

- insert the immutable work-start event,
- check whether the SR is already locked,
- if not locked and actor is currently authorized, set `work_started_at`, `locked_at`, and `locked_by_event_id`,
- append the resulting entity changes to `change_log`,
- store the idempotent response.

That pattern matches the atomic ordered mutation requirement called out in Replicache and the consistency requirement that authoritative write processing and mutation/version advancement occur together. citeturn28view0turn28view3turn21view0

**If an offline client submits a stale SR edit**, Hub should reject it, not auto-merge it. The response should include the latest authoritative row version and a machine-readable error such as `stale_version`, `locked_sr`, or `assignment_changed`. This is exactly the problem `If-Match` and `412 Precondition Failed` were designed to solve. Mobile should then mark the local draft as conflicted, pull the latest snapshot, and invite the user either to reapply the edit manually or abandon it. citeturn33view0turn33view2turn33view3

**If a dispatcher reassigns an SR while a driver is offline**, the dispatcher’s change becomes authoritative as soon as Hub commits it, because Hub is the source of truth. If the driver later uploads an offline work-start event that was captured under the old assignment, I recommend this conservative rule: **preserve the event as evidence, freeze the SR, and flag manual review if the actor is no longer the current authorized owner/assistant at sync time**. The phone does not get to “win” and retroactively restore ownership, but the evidence is not discarded either. This is the safest containment model for legal/safety integrity and avoids silent loss. That recommendation is an inference from the system’s stated authority rule and from the fact that automatic timestamp-based winners, like LWW systems, resolve rather than prevent conflicting authority. citeturn30view0turn30view1turn24search0

**If a driver starts work offline and later syncs while still being the current authorized assignee**, Hub accepts the work-start event, locks the SR, emits downstream invalidations, and all other mutable SR edits afterward require manager review or a formal exception path. The mobile UI may show a local “started pending sync” badge immediately, but that badge is **provisional** until Hub ACKs it.

Manual review should be required for these cases:

- offline work-start arrives after Hub already accepted a reassignment,
- two different actors submit competing work-start evidence for the same SR,
- JHA/JSA signature arrives from a user who is inactive/revoked by the time Hub validates it,
- an offline field-ticket finalization or other safety-sensitive submission references a stale assignment or stale lock state,
- any command depends on a parent object that never committed.

For offline safety, I recommend the following concrete rule set:

| Offline rule | Recommendation |
|---|---|
| Allowed offline | Read cached role-scoped data, draft field tickets, capture photos/docs, queue print events, queue work-start/JHA submissions as pending if auth snapshot is still valid |
| Must wait for Hub | SR reassignment, owner edits, assistant edits after lock, approvals/final closes, payroll/billing-sensitive finalization, all admin/permission changes |
| Read-only offline | Any SR already known locally as started/locked; any authoritative object whose required permission snapshot is expired |
| Revoked/inactive employee/card | If locally known revoked/inactive, block immediately. If revocation snapshot is stale, fail closed for privileged actions and allow cached reads only |
| Expired cached permissions | Degrade to least privilege. No authority-conferring or destructive actions until refresh |

These rules are consistent with Android offline-first guidance on queued/lazy writes and with the requirement that mobile remain usable without becoming an independent authority. citeturn32view0turn32view2

## Idempotency and binary sync

Use **both client-generated IDs and idempotency keys**.

Every logical mobile write should carry:

- a **stable entity ID** for creates, such as UUIDv7 for `ticket_id`, `attachment_id`, `work_event_id`,
- a stable **operation ID** for the logical command,
- an `Idempotency-Key` header,
- the client’s monotonic `local_seq`,
- optional `depends_on` operation IDs,
- a `base_version` or `If-Match` precondition for mutable edits.

A concrete key format that aligns well with Field Time is:

```text
gtr:<device_instance_id>:<local_seq>:<op_uuid>
```

The server should persist an `idempotency_ledger` table with at least:

```text
idempotency_key
actor_id
endpoint
request_hash
first_seen_at
status
response_json
committed_change_seq
expires_at
```

Stripe’s idempotency model is the right behavioral reference: the server stores the first result for a key and returns that same result on retries. The IETF draft also supports pairing the key with a request fingerprint so the same key cannot be reused with a different payload. If the same key arrives while the first request is still in progress, respond as a conflict; if the key is reused with a different payload, reject it as semantic misuse. citeturn33view4turn34view0

Retry policy should mirror Field Time:

- retry on network failure, timeout, `429`, and temporary `5xx`,
- use **exponential backoff with jitter**,
- process queue items in `local_seq` order unless dependency graph allows parallelism,
- stop retrying permanently rejected semantic errors and mark them as user-resolvable conflicts,
- only advance the queue when dependencies are satisfied.

That is directly aligned with Android guidance for queued writes and WorkManager retry/backoff support. citeturn32view0turn32view2turn32view3

For photos and documents, use **`tus` resumable uploads** rather than whole-file POSTs. `tus` is built on HTTP, supports `HEAD` to discover current offset, `PATCH` to continue from that offset, checksum extensions for chunk integrity, and expiration handling for abandoned uploads. It is explicitly recommended for large files and unreliable mobile networks, and it has official client/server implementations across Android, iOS, JavaScript, and server stacks. citeturn12search1turn14view0turn14view1turn36view0turn36view1turn36view2

The binary-flow recommendation is:

1. Mobile computes `sha256`, `byte_length`, `mime_type`, and creates local `blob_id`.
2. Mobile calls `POST /uploads/sessions` with idempotency key and blob metadata.
3. Hub returns either:
   - `already_present` with existing `blob_id`, or
   - a new `upload_session_id` and `tus` upload URL.
4. Mobile uploads in resumable chunks. Small files may complete in one request; larger files should use moderate chunk sizes such as 1 to 4 MiB to balance overhead and restart cost.
5. Hub verifies final received size and whole-file `sha256`, moves the blob into durable storage, and marks the session complete.
6. Mobile submits a separate idempotent `AttachBlob` command referencing `blob_id`, `parent_type`, `parent_id`, and `attachment_kind`.
7. Mobile purges the local copy **only after** Hub confirms both upload completion and attachment-link commit.

That gives you retry-safe storage dedupe and retry-safe semantic linking. The blob store dedupes by `(sha256, byte_length)`, while the attachment link dedupes by `attachment_id` or idempotency key. That means a network retry will not create duplicate files or duplicate links, while two intentionally separate attachments can still point to the same stored blob. Unsynced photos and print records must remain on-device until that two-phase confirmation finishes. citeturn14view0turn14view1turn36view1turn33view4turn34view0

## Reference invalidation, cloud evolution, and failure containment

For reference-data invalidation, use a **push-hint plus pull-truth model**.

If MQTT is already present in the system, it is a good fit as an **invalidation hint channel**, not as the authoritative data source. MQTT is an OASIS standard designed to be lightweight, bandwidth-efficient, and usable over unreliable cellular networks with persistent sessions and defined QoS levels. That makes it appropriate for “something changed, pull now” notifications to mobile and Raspberry Pi clients. citeturn37view1

The authoritative payload should still come from Hub over normal sync endpoints. A minimal invalidation message can carry:

```json
{
  "scope": "employees|permissions|cards|sr:<id>",
  "new_version": 1842,
  "reason": "revocation|assignment_change|permission_change"
}
```

On receipt, the client immediately pulls the matching authoritative snapshot or delta. If push is unavailable, the client still pulls on app foreground, network regain, login refresh, and a periodic cadence while active. Revocations should be tracked with a **monotonic generation number** so the client can cheaply compare “what I have” versus “what Hub has.”

For cloud evolution, do **not** let office and cloud become simultaneous independent writers. That is how split-brain authority gets introduced. Active-active systems solve that with automatic LWW, version vectors, or merge semantics. Field’s stated requirement is stricter: it wants to avoid conflicting authority, not merely resolve it after the fact. So the future model should be:

- **one writer per authority epoch**,
- tokens become `<authority_epoch, commit_seq>`,
- only the node holding the current writer lease may accept commands,
- replica/edge nodes may serve reads and cached sync, but without a current lease they must reject writes or relay them to the primary.

In the current phase, the **office Hub is the primary writer**. In a future cloud phase, the cutover should explicitly increment `authority_epoch` and make **cloud the only writer**, while the office server becomes a cache/edge/relay. This design is an inference, but it is strongly supported by the user’s “single source of truth” requirement and by the failure modes of distributed active-active sync systems documented in other stacks. citeturn30view0turn30view1turn30view2turn21view0turn24search0

The main failure modes and containment strategy are:

| Failure mode | Prevention / containment |
|---|---|
| Race conditions on same SR | `If-Match` or `base_version`, transactional command handling, `428` on missing precondition, `412` on stale precondition |
| Duplicate submissions on flaky links | client UUIDs, idempotency keys, request fingerprint, stored first response |
| Stale SR edits after lock | reject and return fresh authoritative snapshot |
| Revoked user continues offline | short-lived revocation snapshot, push invalidation, fail-closed privileged ops when stale |
| Partial photo upload | `tus` resume via `HEAD` offset, chunk integrity checks, no local purge before completion |
| Conflicting dispatcher and driver changes | dispatcher change remains authoritative once Hub commits; later offline start evidence is preserved and escalated to review, not auto-merged |
| Duplicate images from retries | dedupe blob storage by content hash and attachment semantics by idempotent link command |
| Office/cloud split-brain later | single writer lease plus `authority_epoch`; edge nodes without lease become read-only or relay-only |

The basis for this table is the combination of offline-first local persistence, conditional writes for lost-update prevention, idempotent request replay, resumable upload semantics, and the choice to avoid timestamp-winner multi-primary authority for Field business state. citeturn32view0turn33view0turn33view1turn33view2turn33view4turn34view0turn14view0turn36view1turn30view0

## Confidence and limitations

**Confidence:** high on the main recommendation.

**High-confidence conclusions**
- Field should use **custom authoritative command/event sync** for business records.
- Field should use a **server-issued change token / oplog** for downstream sync.
- Field should use **immutable append-only storage semantics** for JHA/JSA signatures, audit logs, print events, and work-start evidence.
- Field should use **optimistic concurrency plus precondition rejection** for mutable SR and draft ticket state.
- Field should use **`tus` resumable uploads** for photos/documents.
- Field should keep **Hub as the only authority** and avoid active-active mobile/edge/cloud writers. citeturn32view0turn33view0turn33view2turn33view4turn14view0turn36view1turn21view0

**Key assumptions**
- Field Capture can embed a durable local SQLite store.
- Hub can add a few infrastructure tables: `change_log`, `idempotency_ledger`, `audit_events`, `upload_sessions`, `attachments`.
- The mobile team can implement persistent queue semantics similar to Field Time.
- Future cloud cutover can be managed explicitly instead of requiring permanent active-active office/cloud writes.

**Open questions / limitations**
- I could not inspect the selected GitHub repositories from this session. Direct public fetch attempts for the guessed repo URLs returned `404`, so this report is grounded in the project description you provided and external primary documentation, not repo internals. citeturn5view0turn5view1turn5view2
- I do not know whether Field Capture is React Native, Flutter, native Android, or another stack. That affects the local DB and upload client library choices, but **not** the recommended protocol model.
- I do not know the exact legal retention requirements for signature images and attachments. If retention is regulated, the append-only/no-silent-delete rule should be backed by a formal retention policy in Hub.