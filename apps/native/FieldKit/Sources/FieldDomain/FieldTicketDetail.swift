// Port of src/domain/fieldTicketDetail.ts — Full field-ticket detail (spec: digital version of
// the paper Acme Oilfield field ticket).
//
// The paper ticket carries far more than the minimal V1 submit (`quantity_bbl`/`disposal_ticket_no`):
// yard/in/out times, a rig number, per-tank beginning/ending gauges (total/water/condensate in
// ft+inches), water pulled, per-tank barrels, and priced line items. These ride as ONE optional
// `detail` blob on the draft and the submission so the wire stays additive — the SR number is
// still the ticket number (`ticketNo == request_no`) and `quantityBbl` is still the contract total
// Hub prices. Rate/total on line items are Hub-priced; the driver never types them.
//
// ponytail: one nested optional blob instead of ~24 flat fields — additive on mobile, one jsonb
// column on the Hub. The Hub currently ignores unknown submit fields (verified: 201), so mobile
// can ship this ahead of the backend persisting it. See
// docs/integration/field-ticket-full-form-hub-spec.md.

/// A gauge measurement as the driver reads the tank: feet + inches.
public struct FtIn: Equatable, Sendable {
    public var ft: Double?
    public var inches: Double?

    public init(ft: Double? = nil, inches: Double? = nil) {
        self.ft = ft
        self.inches = inches
    }
}

/// One gauge snapshot (beginning OR ending): the three readings on the paper ticket.
public struct GaugeReading: Equatable, Sendable {
    public var total: FtIn?
    public var water: FtIn?
    public var condensate: FtIn?

    public init(total: FtIn? = nil, water: FtIn? = nil, condensate: FtIn? = nil) {
        self.total = total
        self.water = water
        self.condensate = condensate
    }
}

/// One tank panel from the paper ticket (the form has two side-by-side).
public struct TankGauge: Equatable, Sendable {
    /// Free-text tank id the driver writes on the "TANK:" line (e.g. "Truck", "Trailer", "Tank 1").
    public var label: String?
    public var locationTime: String?
    public var beginning: GaugeReading?
    public var ending: GaugeReading?
    public var waterPulled: FtIn?
    /// Barrels pulled from THIS tank. The submission's `quantityBbl` remains the contract total.
    public var barrelsPulled: Double?

    public init(
        label: String? = nil,
        locationTime: String? = nil,
        beginning: GaugeReading? = nil,
        ending: GaugeReading? = nil,
        waterPulled: FtIn? = nil,
        barrelsPulled: Double? = nil
    ) {
        self.label = label
        self.locationTime = locationTime
        self.beginning = beginning
        self.ending = ending
        self.waterPulled = waterPulled
        self.barrelsPulled = barrelsPulled
    }
}

/// One billable line (DESCRIPTION / Qty / Rate / TOTAL). Rate + total are Hub-priced.
public struct TicketLineItem: Equatable, Sendable {
    public var description: String
    public var qty: Double?
    /// Hub-priced by the rate card — present only on the Hub's returned/priced copy.
    public var rate: Double?
    public var total: Double?

    public init(description: String, qty: Double? = nil, rate: Double? = nil, total: Double? = nil) {
        self.description = description
        self.qty = qty
        self.rate = rate
        self.total = total
    }
}

/// The clock fields across the top of the paper ticket. Strings (HH:MM or ISO), driver-entered.
public struct FieldTicketTimes: Equatable, Sendable {
    public var yardArrival: String?
    public var timeIn: String?
    public var timeOut: String?

    public init(yardArrival: String? = nil, timeIn: String? = nil, timeOut: String? = nil) {
        self.yardArrival = yardArrival
        self.timeIn = timeIn
        self.timeOut = timeOut
    }
}

/// The full paper-ticket detail, additive to the minimal V1 submission.
public struct FieldTicketDetail: Equatable, Sendable {
    public var rigNo: String?
    public var times: FieldTicketTimes?
    public var tanks: [TankGauge]?
    public var lineItems: [TicketLineItem]?

    public init(
        rigNo: String? = nil,
        times: FieldTicketTimes? = nil,
        tanks: [TankGauge]? = nil,
        lineItems: [TicketLineItem]? = nil
    ) {
        self.rigNo = rigNo
        self.times = times
        self.tanks = tanks
        self.lineItems = lineItems
    }
}
