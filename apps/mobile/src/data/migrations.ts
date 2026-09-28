/**
 * Versioned schema migrations for the durable local store. Applied in order via
 * `PRAGMA user_version` — each entry runs exactly once per database, inside a transaction.
 *
 * Schema covers everything the spec requires to survive a restart: assignments (+ snapshot
 * hashes), pre-submit field-ticket drafts, submit evidence (the outbox rows: idempotency keys,
 * submit status, rejection code/detail/http-status/timestamps, retry metadata), and the device's
 * durable write identity (device_instance_id + the monotonic local_seq allocator — reusing a seq
 * after a restart would corrupt idempotency keys).
 */
import type { SqlDriver } from './sqlDriver';

export const MIGRATIONS: readonly string[] = [
  // v1 — initial durable store
  `
  CREATE TABLE assignments (
    service_request_id TEXT PRIMARY KEY,
    snapshot_hash      TEXT NOT NULL,
    snapshot_json      TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );

  CREATE TABLE ticket_evidence (
    idempotency_key       TEXT PRIMARY KEY,
    envelope_json         TEXT NOT NULL,
    state                 TEXT NOT NULL
                          CHECK (state IN ('pending','in-flight','accepted','rejected','needs-review')),
    attempts              INTEGER NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL,
    last_rejection_code   TEXT,
    last_detail           TEXT,
    last_http_status      INTEGER,
    last_outcome_at       TEXT,
    last_transient_reason TEXT,
    next_attempt_at_ms    INTEGER
  );
  CREATE INDEX idx_ticket_evidence_state ON ticket_evidence(state);

  CREATE TABLE device_identity (
    id                 INTEGER PRIMARY KEY CHECK (id = 1),
    device_instance_id TEXT NOT NULL,
    next_local_seq     INTEGER NOT NULL
  );
  `,
  // v2 — explicit durable outbox projection over the evidence envelope/state machine.
  `
  ALTER TABLE ticket_evidence ADD COLUMN id TEXT NOT NULL DEFAULT '';
  ALTER TABLE ticket_evidence ADD COLUMN type TEXT NOT NULL DEFAULT '';
  ALTER TABLE ticket_evidence ADD COLUMN payload_json TEXT NOT NULL DEFAULT '{}';
  ALTER TABLE ticket_evidence ADD COLUMN outbox_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (outbox_status IN ('pending','in-flight','retry','failed','accepted','needs-review'));

  UPDATE ticket_evidence
     SET id = idempotency_key
   WHERE id = '';

  UPDATE ticket_evidence
     SET type = 'ticket.submit'
   WHERE type = '';

  UPDATE ticket_evidence
     SET outbox_status =
       CASE
         WHEN state = 'accepted' THEN 'accepted'
         WHEN state = 'in-flight' THEN 'in-flight'
         WHEN state = 'needs-review' THEN 'needs-review'
         WHEN state = 'rejected' THEN 'failed'
         WHEN state = 'pending'
              AND (attempts > 0 OR last_rejection_code IS NOT NULL OR last_transient_reason IS NOT NULL)
           THEN CASE WHEN last_rejection_code IS NOT NULL THEN 'failed' ELSE 'retry' END
         ELSE 'pending'
       END;
  `,
  // v3 — blocked outbox status + durable pre-submit field-ticket drafts.
  `
  CREATE TABLE ticket_evidence_next (
    idempotency_key       TEXT PRIMARY KEY,
    envelope_json         TEXT NOT NULL,
    state                 TEXT NOT NULL
                          CHECK (state IN ('pending','in-flight','accepted','rejected','needs-review')),
    attempts              INTEGER NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL,
    updated_at            TEXT NOT NULL,
    last_rejection_code   TEXT,
    last_detail           TEXT,
    last_http_status      INTEGER,
    last_outcome_at       TEXT,
    last_transient_reason TEXT,
    next_attempt_at_ms    INTEGER,
    id                    TEXT NOT NULL DEFAULT '',
    type                  TEXT NOT NULL DEFAULT '',
    payload_json          TEXT NOT NULL DEFAULT '{}',
    outbox_status         TEXT NOT NULL DEFAULT 'pending'
                          CHECK (outbox_status IN ('pending','in-flight','retry','blocked','failed','accepted','needs-review'))
  );

  INSERT INTO ticket_evidence_next (
    idempotency_key, envelope_json, state, attempts, created_at, updated_at,
    last_rejection_code, last_detail, last_http_status, last_outcome_at,
    last_transient_reason, next_attempt_at_ms, id, type, payload_json, outbox_status
  )
  SELECT
    idempotency_key, envelope_json, state, attempts, created_at, updated_at,
    last_rejection_code, last_detail, last_http_status, last_outcome_at,
    last_transient_reason, next_attempt_at_ms, id, type, payload_json,
    CASE
      WHEN state = 'pending' AND last_rejection_code IS NOT NULL THEN 'blocked'
      ELSE outbox_status
    END
  FROM ticket_evidence;

  DROP TABLE ticket_evidence;
  ALTER TABLE ticket_evidence_next RENAME TO ticket_evidence;
  CREATE INDEX idx_ticket_evidence_state ON ticket_evidence(state);

  CREATE TABLE field_ticket_drafts (
    id                 TEXT PRIMARY KEY,
    service_request_id TEXT NOT NULL,
    ticket_no          TEXT NOT NULL,
    quantity_bbl       INTEGER NOT NULL,
    disposal_ticket_no TEXT NOT NULL,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );
  `,
  // v4 — full ADR 004 sync engine: generic operation outbox, down-sync frontier, committed-op
  // ledger (parents pruned from the outbox stay resolvable for dependency planning), and the
  // durable blob/upload records behind tus-style resumable uploads.
  `
  CREATE TABLE sync_frontier (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    authority_epoch INTEGER NOT NULL,
    commit_seq      INTEGER NOT NULL
  );

  CREATE TABLE sync_outbox (
    op_id              TEXT PRIMARY KEY,
    idempotency_key    TEXT NOT NULL UNIQUE,
    envelope_json      TEXT NOT NULL,
    state              TEXT NOT NULL
                       CHECK (state IN ('pending','in-flight','accepted','rejected','needs-review')),
    retry_count        INTEGER NOT NULL DEFAULT 0,
    committed_epoch    INTEGER,
    committed_seq      INTEGER,
    rejection_code     TEXT,
    last_error         TEXT,
    next_attempt_at_ms INTEGER,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );
  CREATE INDEX idx_sync_outbox_state ON sync_outbox(state);

  CREATE TABLE committed_ops (
    op_id        TEXT PRIMARY KEY,
    committed_at TEXT NOT NULL
  );

  CREATE TABLE blob_records (
    blob_id                 TEXT PRIMARY KEY,
    sha256                  TEXT NOT NULL,
    byte_length             INTEGER NOT NULL,
    mime_type               TEXT NOT NULL,
    local_uri               TEXT NOT NULL,
    state                   TEXT NOT NULL
                            CHECK (state IN ('local-only','uploading','uploaded','linked','upload-expired')),
    upload_confirmed        INTEGER NOT NULL DEFAULT 0,
    link_confirmed          INTEGER NOT NULL DEFAULT 0,
    bytes_acked             INTEGER NOT NULL DEFAULT 0,
    upload_session_id       TEXT,
    upload_url              TEXT,
    attachment_id           TEXT NOT NULL UNIQUE,
    parent_type             TEXT NOT NULL,
    parent_id               TEXT NOT NULL,
    attachment_kind         TEXT NOT NULL,
    session_idempotency_key TEXT NOT NULL,
    parent_op_id            TEXT,
    link_op_id              TEXT,
    purged_at               TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL
  );
  CREATE INDEX idx_blob_records_state ON blob_records(state);
  `,
  // v5 — field-runtime slice: DVIR/JHA form records (drafts + append-only evidence status) and
  // the durable print-job queue rows (ADR 003 — a print job is an output artifact, logged then
  // synced; never removable before printed + Hub-acknowledged).
  `
  CREATE TABLE field_forms (
    form_id            TEXT PRIMARY KEY,
    kind               TEXT NOT NULL
                       CHECK (kind IN ('pre-trip-dvir','jha-jsa','post-trip-dvir')),
    service_request_id TEXT,
    vehicle_ref        TEXT,
    payload_json       TEXT NOT NULL,
    status             TEXT NOT NULL
                       CHECK (status IN ('draft','completed','enqueued','accepted','needs-review','rejected')),
    op_id              TEXT,
    last_error         TEXT,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );
  CREATE INDEX idx_field_forms_kind ON field_forms(kind);
  CREATE INDEX idx_field_forms_status ON field_forms(status);

  CREATE TABLE print_jobs (
    print_job_id       TEXT PRIMARY KEY,
    sr_id              TEXT NOT NULL,
    field_ticket_id    TEXT NOT NULL,
    employee_id        TEXT,
    worker_ref         TEXT,
    printer_profile_id TEXT NOT NULL,
    created_at         TEXT NOT NULL,
    printed_at         TEXT,
    synced_at          TEXT,
    status             TEXT NOT NULL
                       CHECK (status IN ('queued','rendering','printing','printed','synced','failed','canceled')),
    retry_count        INTEGER NOT NULL DEFAULT 0,
    error_code         TEXT,
    diagnostic_message TEXT,
    payload_hash       TEXT NOT NULL,
    payload_size_bytes INTEGER NOT NULL
  );
  CREATE INDEX idx_print_jobs_status ON print_jobs(status);
  `,
  // v6 — rich assignment metadata from Hub. Raw snapshots remain the compatibility source;
  // normalized metadata drives UI/workflow without mutating the snapshot boundary.
  `
  ALTER TABLE assignments ADD COLUMN latest_server_version INTEGER;
  ALTER TABLE assignments ADD COLUMN rich_json TEXT NOT NULL DEFAULT '{}';
  `,
  // v7 — retype latest_server_version to TEXT. The real Hub sends latest_server_version as a
  // STRING equal to snapshot_hash (opshub sync/router.py), not an integer counter. Rebuild the
  // table (SQLite can't ALTER a column type) following the established table-rebuild pattern;
  // CAST preserves any legacy integer value as its text form.
  `
  CREATE TABLE assignments_v7 (
    service_request_id    TEXT PRIMARY KEY,
    snapshot_hash         TEXT NOT NULL,
    snapshot_json         TEXT NOT NULL,
    latest_server_version TEXT,
    rich_json             TEXT NOT NULL DEFAULT '{}',
    updated_at            TEXT NOT NULL
  );
  INSERT INTO assignments_v7 (
    service_request_id, snapshot_hash, snapshot_json, latest_server_version, rich_json, updated_at
  )
  SELECT service_request_id, snapshot_hash, snapshot_json,
         CAST(latest_server_version AS TEXT), rich_json, updated_at
    FROM assignments;
  DROP TABLE assignments;
  ALTER TABLE assignments_v7 RENAME TO assignments;
  `,
  // v8 — durable 24h offline-policy baseline (Phase 8). Single row; last_hub_contact_at_ms must
  // survive a restart so the offline clock cannot be reset by relaunching. window_hours is the
  // optional Hub-seeded override of the 24h default.
  `
  CREATE TABLE offline_policy_state (
    id                      INTEGER PRIMARY KEY CHECK (id = 1),
    last_hub_contact_at_ms  INTEGER,
    window_hours            INTEGER
  );
  `,
  // v9 — receipt drafts (Phase 5). UI-editable local work, preserved until submitted or explicitly
  // deleted (never silently evicted), in its own table like field_ticket_drafts.
  `
  CREATE TABLE receipt_drafts (
    id                 TEXT PRIMARY KEY,
    service_request_id TEXT NOT NULL,
    receipt_type       TEXT NOT NULL
                       CHECK (receipt_type IN ('disposal','fuel','parts','other')),
    vendor             TEXT NOT NULL DEFAULT '',
    receipt_no         TEXT NOT NULL DEFAULT '',
    amount             REAL NOT NULL DEFAULT 0,
    notes              TEXT NOT NULL DEFAULT '',
    ticket_draft_id    TEXT,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
  );
  CREATE INDEX idx_receipt_drafts_sr ON receipt_drafts(service_request_id);
  `,
  // v10 — additive hauling-detail fields on field-ticket drafts (Phase 5 / spec 7.10). Nullable so
  // existing drafts and the V1 submit path (ticket_no/quantity_bbl/disposal_ticket_no) are unchanged.
  `
  ALTER TABLE field_ticket_drafts ADD COLUMN truck TEXT;
  ALTER TABLE field_ticket_drafts ADD COLUMN trailer TEXT;
  ALTER TABLE field_ticket_drafts ADD COLUMN driver TEXT;
  ALTER TABLE field_ticket_drafts ADD COLUMN notes TEXT;
  ALTER TABLE field_ticket_drafts ADD COLUMN capture_method TEXT;
  `,
  // v11 — down-sync applied-changes ledger (ADR-004 §4g). Keyed by the server-issued
  // (authority_epoch, commit_seq) so re-applying a change page is idempotent and authoritative
  // changes are durably recorded, never dropped by a no-op apply.
  `
  CREATE TABLE sync_changes (
    authority_epoch INTEGER NOT NULL,
    commit_seq      INTEGER NOT NULL,
    op_id           TEXT NOT NULL DEFAULT '',
    entity_type     TEXT NOT NULL DEFAULT '',
    entity_id       TEXT NOT NULL DEFAULT '',
    change_type     TEXT NOT NULL,
    payload_json    TEXT NOT NULL DEFAULT 'null',
    created_at      TEXT NOT NULL DEFAULT '',
    applied_at      TEXT NOT NULL,
    PRIMARY KEY (authority_epoch, commit_seq)
  );
  `,
  // v12 — diagnostic logs (§4f-g) backing the Sync Center / More copy-diagnostic export. Append-
  // only; these are diagnostics (may be rotated), NOT field work.
  `
  CREATE TABLE diagnostic_logs (
    id           TEXT PRIMARY KEY,
    level        TEXT NOT NULL CHECK (level IN ('info','warning','error')),
    message      TEXT NOT NULL,
    context_json TEXT,
    created_at   TEXT NOT NULL
  );
  CREATE INDEX idx_diagnostic_logs_created ON diagnostic_logs(created_at);
  `,
  // v13 — validation-only location evidence (Phase 7). Append-only, NON-EVICTABLE (unsynced field
  // work, preserved until Hub-acked). gps_json is null for manual-only / gps-unavailable records.
  `
  CREATE TABLE location_evidence (
    id                 TEXT PRIMARY KEY,
    service_request_id TEXT NOT NULL,
    place_kind         TEXT NOT NULL
                       CHECK (place_kind IN ('yard','disposal-site','well-site','other')),
    evidence_type      TEXT NOT NULL,
    gps_json           TEXT,
    notes              TEXT,
    state              TEXT NOT NULL CHECK (state IN (
                         'not-captured','captured','verified','outside-expected-area',
                         'unverified','rejected','gps-unavailable','manual-only')),
    created_at         TEXT NOT NULL
  );
  CREATE INDEX idx_location_evidence_sr ON location_evidence(service_request_id);
  `,
];

export function currentSchemaVersion(db: SqlDriver): number {
  const row = db.first<{ user_version: number }>('PRAGMA user_version');
  return row?.user_version ?? 0;
}

/** Bring the database up to the latest schema. Idempotent; safe to call on every open. */
export function migrate(db: SqlDriver): void {
  const from = currentSchemaVersion(db);
  for (let v = from; v < MIGRATIONS.length; v++) {
    db.transaction(() => {
      db.exec(MIGRATIONS[v]!);
      // PRAGMA cannot be parameter-bound; v+1 is a loop-local integer, not user input.
      db.exec(`PRAGMA user_version = ${v + 1}`);
    });
  }
}
