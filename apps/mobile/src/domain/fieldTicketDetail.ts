/**
 * Full field-ticket detail (spec: digital version of the paper Acme Oilfield field ticket).
 *
 * The paper ticket carries far more than the minimal V1 submit (`quantity_bbl`/`disposal_ticket_no`):
 * yard/in/out times, a rig number, per-tank beginning/ending gauges (total/water/condensate in
 * ft+inches), water pulled, per-tank barrels, and priced line items. These ride as ONE optional
 * `detail` blob on the draft and the submission so the wire stays additive — the SR number is still
 * the ticket number (`ticketNo == request_no`) and `quantityBbl` is still the contract total Hub
 * prices. Rate/total on line items are Hub-priced; the driver never types them.
 *
 * ponytail: one nested optional blob instead of ~24 flat fields — additive on mobile, one jsonb
 * column on the Hub. The Hub currently ignores unknown submit fields (verified: 201), so mobile can
 * ship this ahead of the backend persisting it. See docs/integration/field-ticket-full-form-hub-spec.md.
 */

/** A gauge measurement as the driver reads the tank: feet + inches. */
export interface FtIn {
  ft?: number;
  inches?: number;
}

/** One gauge snapshot (beginning OR ending): the three readings on the paper ticket. */
export interface GaugeReading {
  total?: FtIn;
  water?: FtIn;
  condensate?: FtIn;
}

/** One tank panel from the paper ticket (the form has two side-by-side). */
export interface TankGauge {
  /** Free-text tank id the driver writes on the "TANK:" line (e.g. "Truck", "Trailer", "Tank 1"). */
  label?: string;
  locationTime?: string;
  beginning?: GaugeReading;
  ending?: GaugeReading;
  waterPulled?: FtIn;
  /** Barrels pulled from THIS tank. The submission's `quantityBbl` remains the contract total. */
  barrelsPulled?: number;
}

/** One billable line (DESCRIPTION / Qty / Rate / TOTAL). Rate + total are Hub-priced. */
export interface TicketLineItem {
  description: string;
  qty?: number;
  /** Hub-priced by the rate card — present only on the Hub's returned/priced copy. */
  rate?: number;
  total?: number;
}

/** The clock fields across the top of the paper ticket. Strings (HH:MM or ISO), driver-entered. */
export interface FieldTicketTimes {
  yardArrival?: string;
  timeIn?: string;
  timeOut?: string;
}

/** The full paper-ticket detail, additive to the minimal V1 submission. */
export interface FieldTicketDetail {
  rigNo?: string;
  times?: FieldTicketTimes;
  tanks?: TankGauge[];
  lineItems?: TicketLineItem[];
}
