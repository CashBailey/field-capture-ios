// Port of src/domain/receiptDraft.ts — Receipt drafts (spec 7.10 — the ticket+receipt capture
// package). Like field-ticket drafts, a receipt is UI-editable LOCAL work that exists before any
// submit creates immutable evidence, so it lives in its own durable table and is preserved until
// the worker submits or explicitly deletes it (never silently evicted). A receipt links to its SR
// and, optionally, to the field-ticket draft it belongs with; receipt photos attach via the
// existing `receipt-photo` blob kind.

public enum ReceiptType: String, Equatable, Sendable, Codable, CaseIterable {
    case disposal
    case fuel
    case parts
    case other
}

public let RECEIPT_TYPES: [ReceiptType] = [.disposal, .fuel, .parts, .other]

public struct ReceiptDraft: Equatable, Sendable {
    public var id: String
    public var serviceRequestId: String
    public var receiptType: ReceiptType
    public var vendor: String
    public var receiptNo: String
    /// Currency amount (>= 0). Stored as a number; the Hub re-validates on submit.
    public var amount: Double
    public var notes: String
    /// Optional link to the field-ticket draft this receipt belongs with.
    public var ticketDraftId: String?
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        serviceRequestId: String,
        receiptType: ReceiptType,
        vendor: String,
        receiptNo: String,
        amount: Double,
        notes: String,
        ticketDraftId: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.serviceRequestId = serviceRequestId
        self.receiptType = receiptType
        self.vendor = vendor
        self.receiptNo = receiptNo
        self.amount = amount
        self.notes = notes
        self.ticketDraftId = ticketDraftId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol ReceiptDraftStore {
    var durability: StoreDurability { get }
    func save(_ draft: ReceiptDraft) throws
    func get(_ id: String) throws -> ReceiptDraft?
    func list() throws -> [ReceiptDraft]
    func delete(_ id: String) throws
}

/// In-memory test seam — explicitly volatile; never present its contents as "saved on the device".
public final class VolatileReceiptDraftStore: ReceiptDraftStore {
    public let durability: StoreDurability = .volatileMemory
    private var rows: [String: ReceiptDraft] = [:]

    public init() {}

    public func save(_ draft: ReceiptDraft) {
        rows[draft.id] = draft
    }
    public func get(_ id: String) -> ReceiptDraft? {
        rows[id]
    }
    public func list() -> [ReceiptDraft] {
        Array(rows.values)
    }
    public func delete(_ id: String) {
        rows.removeValue(forKey: id)
    }
}
