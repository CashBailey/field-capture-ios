/**
 * Receipt drafts (spec 7.10 — the ticket+receipt capture package). Like field-ticket drafts, a
 * receipt is UI-editable LOCAL work that exists before any submit creates immutable evidence, so it
 * lives in its own durable table and is preserved until the worker submits or explicitly deletes it
 * (never silently evicted). A receipt links to its SR and, optionally, to the field-ticket draft it
 * belongs with; receipt photos attach via the existing `receipt-photo` blob kind.
 */
import type { StoreDurability } from './hubGateway';

export type ReceiptType = 'disposal' | 'fuel' | 'parts' | 'other';

export const RECEIPT_TYPES: readonly ReceiptType[] = ['disposal', 'fuel', 'parts', 'other'];

export interface ReceiptDraft {
  id: string;
  serviceRequestId: string;
  receiptType: ReceiptType;
  vendor: string;
  receiptNo: string;
  /** Currency amount (>= 0). Stored as a number; the Hub re-validates on submit. */
  amount: number;
  notes: string;
  /** Optional link to the field-ticket draft this receipt belongs with. */
  ticketDraftId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface ReceiptDraftStore {
  readonly durability: StoreDurability;
  save(draft: ReceiptDraft): void;
  get(id: string): ReceiptDraft | undefined;
  list(): ReceiptDraft[];
  delete(id: string): void;
}

/** In-memory test seam — explicitly volatile; never present its contents as "saved on the device". */
export class VolatileReceiptDraftStore implements ReceiptDraftStore {
  readonly durability = 'volatile-memory' as const;
  private readonly rows = new Map<string, ReceiptDraft>();

  save(draft: ReceiptDraft): void {
    this.rows.set(draft.id, { ...draft });
  }
  get(id: string): ReceiptDraft | undefined {
    const row = this.rows.get(id);
    return row === undefined ? undefined : { ...row };
  }
  list(): ReceiptDraft[] {
    return [...this.rows.values()].map((row) => ({ ...row }));
  }
  delete(id: string): void {
    this.rows.delete(id);
  }
}
