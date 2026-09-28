// Port of src/domain/fieldTicketDraft.ts

/// How the ticket was captured — digital-native, a scanned paper ticket, or both.
public enum TicketCaptureMethod: String, Equatable, Sendable, Codable, CaseIterable {
    case digital
    case paper
    case hybrid
}

public let TICKET_CAPTURE_METHODS: [TicketCaptureMethod] = [.digital, .paper, .hybrid]

public struct FieldTicketDraft: Equatable, Sendable {
    public var id: String
    public var serviceRequestId: String
    public var ticketNo: String
    public var quantityBbl: Double
    public var disposalTicketNo: String
    // Hauling-detail fields (spec 7.10). Optional + additive so older drafts and the V1 submit
    // path (ticket_no/quantity_bbl/disposal_ticket_no only) keep working unchanged.
    public var truck: String?
    public var trailer: String?
    public var driver: String?
    public var notes: String?
    public var captureMethod: TicketCaptureMethod?
    /// Full paper-ticket detail (gauges, times, rig #, line items). Additive: the minimal submit
    /// path (ticketNo/quantityBbl/disposalTicketNo) ignores it, so older drafts and the V1 wire
    /// keep working.
    public var detail: FieldTicketDetail?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        serviceRequestId: String,
        ticketNo: String,
        quantityBbl: Double,
        disposalTicketNo: String,
        truck: String? = nil,
        trailer: String? = nil,
        driver: String? = nil,
        notes: String? = nil,
        captureMethod: TicketCaptureMethod? = nil,
        detail: FieldTicketDetail? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.serviceRequestId = serviceRequestId
        self.ticketNo = ticketNo
        self.quantityBbl = quantityBbl
        self.disposalTicketNo = disposalTicketNo
        self.truck = truck
        self.trailer = trailer
        self.driver = driver
        self.notes = notes
        self.captureMethod = captureMethod
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol FieldTicketDraftStore {
    var durability: StoreDurability { get }
    func save(_ draft: FieldTicketDraft) throws
    func get(_ id: String) throws -> FieldTicketDraft?
    func list() throws -> [FieldTicketDraft]
    func delete(_ id: String) throws
}
