// Port of adapters/printer/Pt210Module.ts's `createPt210TestReceipt` and
// `createPt210SignatureBitmapTest` — on-device diagnostic payload builders. Byte building itself
// stays in FieldContracts (`createEscPosEncoder`, `MonoBitmap`); this file only assembles the
// same diagnostic content the TS did.
import Foundation
import FieldContracts

/// Port of the TS `createPt210TestReceipt`'s optional-input bag.
public struct Pt210TestReceiptInput: Sendable {
    public var title: String?
    public var serviceRequestId: String?
    public var fieldTicketId: String?
    public var quantityBbl: Double?
    public var disposalTicketNo: String?
    public var profile: PrinterProfile?

    public init(
        title: String? = nil,
        serviceRequestId: String? = nil,
        fieldTicketId: String? = nil,
        quantityBbl: Double? = nil,
        disposalTicketNo: String? = nil,
        profile: PrinterProfile? = nil
    ) {
        self.title = title
        self.serviceRequestId = serviceRequestId
        self.fieldTicketId = fieldTicketId
        self.quantityBbl = quantityBbl
        self.disposalTicketNo = disposalTicketNo
        self.profile = profile
    }
}

/// Port of the TS `createPt210TestReceipt` — a mock field-ticket receipt used by the diagnostic.
public func createPt210TestReceipt(_ input: Pt210TestReceiptInput = Pt210TestReceiptInput()) throws -> Data {
    let profile = input.profile ?? PT210_PROFILE
    let title = input.title ?? "FIELD MOBILE"
    let serviceRequestId = input.serviceRequestId ?? "sr-diagnostic"
    let fieldTicketId = input.fieldTicketId ?? "field-ticket-test"
    let quantityBbl = input.quantityBbl ?? 0
    let disposalTicketNo = input.disposalTicketNo ?? "diagnostic"
    return try createEscPosEncoder(profile)
        .reset()
        .align(.center)
        .bold(true)
        .text(title)
        .bold(false)
        .text("PT-210 TEST RECEIPT")
        .align(.left)
        .separator()
        .text("SR: \(serviceRequestId)")
        .text("Ticket: \(fieldTicketId)")
        .text("Qty: \(jsNumberString(quantityBbl)) bbl")
        .text("Disposal: \(disposalTicketNo)")
        .separator()
        .feed(3)
        .encode()
}

/// Port of the TS `createPt210SignatureBitmapTest` — draws a small squiggle + baseline into a
/// 256x72 1bpp bitmap and encodes it as a GS v 0 raster, the same shape FieldPrinter.swift's
/// `signatureBitmap` diagnostic check prints.
public func createPt210SignatureBitmapTest(profile: PrinterProfile = PT210_PROFILE) throws -> Data {
    let widthPx = 256
    let heightPx = 72
    let widthBytes = (widthPx + 7) / 8
    var bitmapBytes = [UInt8](repeating: 0, count: widthBytes * heightPx)

    func setPixel(_ x: Int, _ y: Int) {
        guard x >= 0, x < widthPx, y >= 0, y < heightPx else { return }
        let byteIndex = y * widthBytes + x / 8
        let mask: UInt8 = 1 << (7 - (x % 8))
        if bitmapBytes[byteIndex] & mask == 0 {
            bitmapBytes[byteIndex] |= mask
        }
    }

    func drawLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, radius: Int = 1) {
        let steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in 0...steps {
            let x = x0 + Int((Double(x1 - x0) * Double(i) / Double(steps)).rounded())
            let y = y0 + Int((Double(y1 - y0) * Double(i) / Double(steps)).rounded())
            for yy in (y - radius)...(y + radius) {
                for xx in (x - radius)...(x + radius) {
                    if (xx - x) * (xx - x) + (yy - y) * (yy - y) <= radius * radius {
                        setPixel(xx, yy)
                    }
                }
            }
        }
    }

    drawLine(18, 52, 42, 24, radius: 2)
    drawLine(42, 24, 66, 54, radius: 2)
    drawLine(66, 54, 94, 34, radius: 2)
    drawLine(94, 34, 128, 50, radius: 2)
    drawLine(128, 50, 170, 36, radius: 2)
    drawLine(170, 36, 220, 46, radius: 2)
    drawLine(42, 62, 220, 62, radius: 1)

    return try createEscPosEncoder(profile)
        .reset()
        .align(.center)
        .text("PT-210 SIGNATURE TEST")
        .bitmap(MonoBitmap(widthPx: widthPx, heightPx: heightPx, data: Data(bitmapBytes)))
        .feed(3)
        .encode()
}

/// JS `${number}` string coercion for the receipt's quantity line (`3` not `3.0`, `3.5` stays
/// `3.5`) — this diagnostic text has no byte-exact contract test, so exact IEEE754-vs-Double tie
/// behavior is not chased further than this.
private func jsNumberString(_ value: Double) -> String {
    value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
}
