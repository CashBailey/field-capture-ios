/**
 * Durable receipt-draft storage (Phase 5) — UI-editable local work that exists before any submit,
 * preserved until submitted or explicitly deleted, in its own table like field_ticket_drafts.
 */
import type { ReceiptDraft, ReceiptDraftStore, ReceiptType, StoreDurability } from '../domain';
import type { SqlDriver } from './sqlDriver';

interface ReceiptRow extends Record<string, unknown> {
  id: string;
  service_request_id: string;
  receipt_type: string;
  vendor: string;
  receipt_no: string;
  amount: number;
  notes: string;
  ticket_draft_id: string | null;
  created_at: string;
  updated_at: string;
}

function fromRow(row: ReceiptRow): ReceiptDraft {
  return {
    id: row.id,
    serviceRequestId: row.service_request_id,
    receiptType: row.receipt_type as ReceiptType,
    vendor: row.vendor,
    receiptNo: row.receipt_no,
    amount: row.amount,
    notes: row.notes,
    ...(row.ticket_draft_id !== null ? { ticketDraftId: row.ticket_draft_id } : {}),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const COLUMNS =
  'id, service_request_id, receipt_type, vendor, receipt_no, amount, notes, ticket_draft_id, created_at, updated_at';

export class SqliteReceiptDraftStore implements ReceiptDraftStore {
  constructor(
    private readonly db: SqlDriver,
    readonly durability: Exclude<StoreDurability, 'volatile-memory'>,
  ) {}

  save(draft: ReceiptDraft): void {
    this.db.run(
      `INSERT OR REPLACE INTO receipt_drafts (${COLUMNS})
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        draft.id,
        draft.serviceRequestId,
        draft.receiptType,
        draft.vendor,
        draft.receiptNo,
        draft.amount,
        draft.notes,
        draft.ticketDraftId ?? null,
        draft.createdAt,
        draft.updatedAt,
      ],
    );
  }

  get(id: string): ReceiptDraft | undefined {
    const row = this.db.first<ReceiptRow>(`SELECT ${COLUMNS} FROM receipt_drafts WHERE id = ?`, [
      id,
    ]);
    return row === null ? undefined : fromRow(row);
  }

  list(): ReceiptDraft[] {
    return this.db
      .all<ReceiptRow>(`SELECT ${COLUMNS} FROM receipt_drafts ORDER BY created_at, id`)
      .map(fromRow);
  }

  delete(id: string): void {
    this.db.run('DELETE FROM receipt_drafts WHERE id = ?', [id]);
  }
}
