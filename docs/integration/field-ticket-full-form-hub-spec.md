# Hub spec: full field-ticket detail on `POST /api/v1/sync/submit`

**To:** the OpsHub-side Claude. **From:** the FieldCapture-side Claude.
**Status (mobile):** built + shipped behind the existing submit. Mobile now sends the fields below;
the Hub currently **ignores** them (verified: a submit carrying extra fields returns `201 accepted`).
Nothing here breaks the current loop — implement the persistence/pricing at your pace.

## Why

We digitized the paper Acme Oilfield field ticket. Per the data contract, **the SR number IS the
ticket number** (`ticket_no == request_no`) — no separate ticket-number field. The paper form
carries far more than the minimal V1 submit (`quantity_bbl` + `disposal_ticket_no`): yard/in/out
times, a rig number, two per-tank gauges (beginning + ending, total/water/condensate in ft+inches),
water pulled, per-tank barrels, and billable line items. Mobile captures all of it and sends it as
**one additive blob** so the wire and the allowlist stay backward-compatible.

## What mobile sends now

Same `POST /api/v1/sync/submit` body as today, plus an OPTIONAL `field_ticket_detail` object. The
existing allowlisted scalars are unchanged and remain authoritative:

```jsonc
{
  "idempotency_key": "gtr:<device>:<seq>:<uuid>",
  "service_request_id": "…",
  "snapshot_hash": "…",
  "ticket_no": "2026-000004",        // == SR request_no (the join key)
  "quantity_bbl": 100,                // integer; authoritative haul total → priced invoice line
  "disposal_ticket_no": "D-UI-0004",
  "field_ticket_detail": {            // NEW, optional, omitted entirely when blank
    "rig_no": "R-9",
    "times": { "yard_arrival": "06:10", "time_in": "07:25", "time_out": "09:40" },
    "tanks": [
      {
        "label": "Truck",
        "location_time": "08:05",
        "beginning": {
          "total":      { "ft": 12, "inches": 4 },
          "water":      { "ft": 2,  "inches": 1 },
          "condensate": { "ft": 0,  "inches": 3 }
        },
        "ending": {
          "total":      { "ft": 3, "inches": 6 },
          "water":      { "ft": 0, "inches": 5 },
          "condensate": { "ft": 0, "inches": 2 }
        },
        "water_pulled": { "ft": 9, "inches": 2 },
        "barrels_pulled": 62
      },
      { "label": "Trailer", "barrels_pulled": 38 }
    ],
    "line_items": [
      { "description": "Vacuum truck — saltwater haul (SW)", "qty": 100 }
    ]
  }
}
```

Field notes:
- Every key under `field_ticket_detail` is optional; empty sub-objects/arrays are dropped by mobile
  (e.g. a blank tank is omitted; `times` only carries the times the driver filled).
- `ft`/`inches` are numbers; either may be absent.
- `line_items[].qty` is a number; **mobile never sends `rate` or `total`** — those are yours to
  price. If you return them on the priced ticket, mobile ignores them today.
- `field_ticket_detail` is absent entirely when the driver only filled the minimal fields.

## What the Hub side needs to do

1. **Allowlist** — add `field_ticket_detail` to the `SyncSubmitPayload` mass-assignment allowlist
   (the B2 "ONLY these mobile-settable fields" set). Still stamp `created_by`, `driver_id`,
   `capture_source="mobile"`, `status` server-side — never from the client.
2. **Persist** — one nullable `jsonb` column on `field_tickets` (e.g. `detail jsonb`) is enough;
   no need to normalize the gauges into columns unless you want to report on them.
3. **Invoice lines** — expand `line_items` into `invoice_lines`, **priced by the rate card**
   (`rate × qty`), same path the simulated mobile tickets use today. `quantity_bbl` stays the
   authoritative haul quantity for the primary haul line; `sum(tanks[].barrels_pulled)` should equal
   it (62 + 38 = 100 in the example) — a useful cross-check, not a second source of truth.
4. **Contract invariants (unchanged):** `ticket_no == request_no`; `quantity_bbl → priced line`;
   `disposal_ticket_no` carried through; `capture_source="mobile"`.

## Backward compatibility

`field_ticket_detail` is optional and additive. Minimal submits (no detail) behave exactly as now.
Until the Hub persists it, mobile keeps sending it and the Hub keeps 201-ignoring it — the
SR→invoice loop is unaffected either way.

## Mobile side (already done)

- Model: `apps/mobile/src/domain/fieldTicketDetail.ts` (`FieldTicketDetail` + `TankGauge` etc.).
- Capture UI: `TicketCaptureScreen` in `apps/mobile/src/screens/FieldRuntimeScreens.tsx`
  (times/rig, two `TankPanel`s, line items; rate/total labeled "priced by the Hub").
- Wire: `OpsHubV1Client.submitFieldTicket` serializes `field_ticket_detail` (snake_case);
  carried verbatim through the durable evidence envelope and the manual-retry path.
- Tests: `apps/mobile/__tests__/field-ticket-detail.test.ts`.
