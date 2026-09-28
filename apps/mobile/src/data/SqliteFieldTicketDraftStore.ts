/**
 * Durable field-ticket draft storage. Drafts are UI-editable local work that may exist before
 * a submit attempt creates immutable evidence/outbox rows, so they live in their own table.
 */
import type {
  FieldTicketDraft,
  FieldTicketDraftStore,
  StoreDurability,
  TicketCaptureMethod,
} from '../domain';
import type { SqlDriver } from './sqlDriver';

interface DraftRow extends Record<string, unknown> {
  id: string;
  service_request_id: string;
  ticket_no: string;
  quantity_bbl: number;
  disposal_ticket_no: string;
  truck: string | null;
  trailer: string | null;
  driver: string | null;
  notes: string | null;
  capture_method: string | null;
  created_at: string;
  updated_at: string;
}

const COLUMNS =
  'id, service_request_id, ticket_no, quantity_bbl, disposal_ticket_no, truck, trailer, driver, notes, capture_method, created_at, updated_at';

function fromRow(row: DraftRow): FieldTicketDraft {
  return {
    id: row.id,
    serviceRequestId: row.service_request_id,
    ticketNo: row.ticket_no,
    quantityBbl: row.quantity_bbl,
    disposalTicketNo: row.disposal_ticket_no,
    ...(row.truck !== null ? { truck: row.truck } : {}),
    ...(row.trailer !== null ? { trailer: row.trailer } : {}),
    ...(row.driver !== null ? { driver: row.driver } : {}),
    ...(row.notes !== null ? { notes: row.notes } : {}),
    ...(row.capture_method !== null
      ? { captureMethod: row.capture_method as TicketCaptureMethod }
      : {}),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export class SqliteFieldTicketDraftStore implements FieldTicketDraftStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(draft: FieldTicketDraft): void {
    this.db.run(
      `INSERT OR REPLACE INTO field_ticket_drafts (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        draft.id,
        draft.serviceRequestId,
        draft.ticketNo,
        draft.quantityBbl,
        draft.disposalTicketNo,
        draft.truck ?? null,
        draft.trailer ?? null,
        draft.driver ?? null,
        draft.notes ?? null,
        draft.captureMethod ?? null,
        draft.createdAt,
        draft.updatedAt,
      ],
    );
  }

  get(id: string): FieldTicketDraft | undefined {
    const row = this.db.first<DraftRow>(`SELECT ${COLUMNS} FROM field_ticket_drafts WHERE id = ?`, [
      id,
    ]);
    return row === null ? undefined : fromRow(row);
  }

  list(): FieldTicketDraft[] {
    return this.db
      .all<DraftRow>(`SELECT ${COLUMNS} FROM field_ticket_drafts ORDER BY updated_at, id`)
      .map(fromRow);
  }

  delete(id: string): void {
    this.db.run('DELETE FROM field_ticket_drafts WHERE id = ?', [id]);
  }
}
