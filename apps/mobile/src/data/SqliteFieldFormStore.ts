/**
 * Durable `FieldFormStore` over SQLite (migration v5). DVIR/JHA drafts survive restart;
 * enqueued/answered forms keep their full payload, outbox opId, and Hub's verbatim reason —
 * safety evidence is never trimmed to a status flag.
 */
import type { fieldwork } from '@fieldcapture/contracts';

import type { FieldFormRecord, FieldFormStatus, FieldFormStore, StoreDurability } from '../domain';
import type { SqlDriver, SqlValue } from './sqlDriver';

interface FormRow extends Record<string, unknown> {
  form_id: string;
  kind: string;
  service_request_id: string | null;
  vehicle_ref: string | null;
  payload_json: string;
  status: string;
  op_id: string | null;
  last_error: string | null;
  created_at: string;
  updated_at: string;
}

const COLUMNS =
  'form_id, kind, service_request_id, vehicle_ref, payload_json, status, op_id, last_error, created_at, updated_at';

function toRowParams(r: FieldFormRecord): SqlValue[] {
  const form = r.form;
  return [
    form.formId,
    form.kind,
    form.kind === 'jha-jsa' ? form.serviceRequestId : null,
    form.kind === 'jha-jsa' ? null : form.vehicleRef,
    JSON.stringify(form),
    r.status,
    r.opId ?? null,
    r.lastError ?? null,
    r.createdAt,
    r.updatedAt,
  ];
}

function fromRow(row: FormRow): FieldFormRecord {
  return {
    form: JSON.parse(row.payload_json) as fieldwork.FieldForm,
    status: row.status as FieldFormStatus,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.op_id !== null ? { opId: row.op_id } : {}),
    ...(row.last_error !== null ? { lastError: row.last_error } : {}),
  };
}

export class SqliteFieldFormStore implements FieldFormStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(record: FieldFormRecord): void {
    this.db.run(
      `INSERT OR REPLACE INTO field_forms (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      toRowParams(record),
    );
  }

  get(formId: string): FieldFormRecord | undefined {
    const row = this.db.first<FormRow>(`SELECT ${COLUMNS} FROM field_forms WHERE form_id = ?`, [
      formId,
    ]);
    return row === null ? undefined : fromRow(row);
  }

  list(): FieldFormRecord[] {
    return this.db
      .all<FormRow>(`SELECT ${COLUMNS} FROM field_forms ORDER BY created_at, form_id`)
      .map(fromRow);
  }

  listByStatus(status: FieldFormStatus): FieldFormRecord[] {
    return this.db
      .all<FormRow>(
        `SELECT ${COLUMNS} FROM field_forms WHERE status = ? ORDER BY created_at, form_id`,
        [status],
      )
      .map(fromRow);
  }
}
