import type { FieldTicketDetail } from './fieldTicketDetail';
import type { StoreDurability } from './hubGateway';

/** How the ticket was captured — digital-native, a scanned paper ticket, or both. */
export type TicketCaptureMethod = 'digital' | 'paper' | 'hybrid';

export const TICKET_CAPTURE_METHODS: readonly TicketCaptureMethod[] = [
  'digital',
  'paper',
  'hybrid',
];

export interface FieldTicketDraft {
  id: string;
  serviceRequestId: string;
  ticketNo: string;
  quantityBbl: number;
  disposalTicketNo: string;
  // Hauling-detail fields (spec 7.10). Optional + additive so older drafts and the V1 submit path
  // (ticket_no/quantity_bbl/disposal_ticket_no only) keep working unchanged.
  truck?: string;
  trailer?: string;
  driver?: string;
  notes?: string;
  captureMethod?: TicketCaptureMethod;
  /**
   * Full paper-ticket detail (gauges, times, rig #, line items). Additive: the minimal submit path
   * (ticketNo/quantityBbl/disposalTicketNo) ignores it, so older drafts and the V1 wire keep working.
   */
  detail?: FieldTicketDetail;
  createdAt: string;
  updatedAt: string;
}

export interface FieldTicketDraftStore {
  readonly durability: StoreDurability;
  save(draft: FieldTicketDraft): void;
  get(id: string): FieldTicketDraft | undefined;
  list(): FieldTicketDraft[];
  delete(id: string): void;
}
