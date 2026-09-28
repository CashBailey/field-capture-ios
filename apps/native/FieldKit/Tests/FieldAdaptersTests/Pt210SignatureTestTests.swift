// Port of the diagnostic-payload assertions in apps/mobile/__tests__/print-runtime.test.ts:
// "generates ESC/POS bytes for the diagnostic receipt instead of a fake print marker" and
// "generates a GS v 0 signature bitmap payload for the PT-210".
import XCTest

@testable import FieldAdapters

final class Pt210SignatureTestTests: XCTestCase {
    func testReceiptStartsWithEscPosResetAndContainsTheSuppliedFields() throws {
        let bytes = try createPt210TestReceipt(
            Pt210TestReceiptInput(
                title: "FIELD MOBILE",
                serviceRequestId: "sr-9",
                fieldTicketId: "ft-1",
                quantityBbl: 120,
                disposalTicketNo: "D-123"
            ))

        XCTAssertEqual(Array(bytes.prefix(2)), [0x1b, 0x40])
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("FIELD MOBILE"))
        XCTAssertTrue(text.contains("SR: sr-9"))
    }

    func testSignatureBitmapEmitsAGsV0RasterHeaderSizedForA256x72Bitmap() throws {
        let bytes = try createPt210SignatureBitmapTest()
        let bytesArray = [UInt8](bytes)
        let markerIndex = bytesArray.indices.first {
            $0 + 3 < bytesArray.count
                && bytesArray[$0] == 0x1d
                && bytesArray[$0 + 1] == 0x76
                && bytesArray[$0 + 2] == 0x30
                && bytesArray[$0 + 3] == 0x00
        }

        let index = try XCTUnwrap(markerIndex)
        XCTAssertGreaterThan(index, 0)
        XCTAssertEqual(Array(bytesArray[index..<(index + 8)]), [0x1d, 0x76, 0x30, 0x00, 32, 0, 72, 0])
    }
}
