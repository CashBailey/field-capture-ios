// Port of FieldPrinter.swift's printer-name/service matching (`isLikelyPrinterName`,
// `isExactPrinterName`) and chunked-write splitting (`Data.chunks(maxLength:)`) — the pure BLE
// discovery-filter logic that doesn't require CoreBluetooth hardware to exercise.
import XCTest

@testable import FieldAdapters

final class Pt210PrinterNameMatchingTests: XCTestCase {
    // MARK: - isExactPrinterName

    func testExactNameMatchesTheCanonicalPt210NameCaseInsensitively() {
        XCTAssertTrue(Pt210PrinterTransport.isExactPrinterName("PT-210_261D"))
        XCTAssertTrue(Pt210PrinterTransport.isExactPrinterName("pt-210_261d"))
    }

    func testExactNameRejectsFragmentOnlyMatches() {
        XCTAssertFalse(Pt210PrinterTransport.isExactPrinterName("GOOJPRT-1234"))
        XCTAssertFalse(Pt210PrinterTransport.isExactPrinterName("PT-210"))
        XCTAssertFalse(Pt210PrinterTransport.isExactPrinterName("Unrelated BLE Device"))
    }

    // MARK: - isLikelyPrinterName

    func testLikelyNameMatchesTheExactCanonicalName() {
        XCTAssertTrue(Pt210PrinterTransport.isLikelyPrinterName("PT-210_261D"))
    }

    func testLikelyNameMatchesEachKnownFragmentCaseInsensitively() {
        let fragmentHits = [
            "GOOJPRT-A1", "goojprt-a1",
            "PT210", "pt210-x",
            "PT-210 v2",
            "PT200",
            "PT-200",
            "MTP-II printer",
            "mtp ii",
        ]
        for name in fragmentHits {
            XCTAssertTrue(Pt210PrinterTransport.isLikelyPrinterName(name), "expected \(name) to match a known fragment")
        }
    }

    func testLikelyNameRejectsUnrelatedBleDevices() {
        XCTAssertFalse(Pt210PrinterTransport.isLikelyPrinterName("Unrelated BLE Device"))
        XCTAssertFalse(Pt210PrinterTransport.isLikelyPrinterName(""))
        XCTAssertFalse(Pt210PrinterTransport.isLikelyPrinterName("AirPods Pro"))
    }

    // MARK: - discovery filter/sort (DiscoveredBlePrinter)

    func testServiceHintMatchesAKnownAdvertisedServiceUuid() {
        let printer = DiscoveredBlePrinter(
            deviceId: "id-1", name: "Unnamed BLE Peripheral", rssi: -50, advertisedServiceUUIDs: ["18F0"])
        XCTAssertTrue(printer.matchesPrinterHint)
        XCTAssertFalse(printer.exactNameMatch)
        XCTAssertFalse(printer.nameHintMatch)
    }

    func testDeviceWithNoNameOrServiceHintDoesNotMatch() {
        let device = DiscoveredBlePrinter(
            deviceId: "id-2", name: "Random Peripheral", rssi: -50, advertisedServiceUUIDs: ["FFFF"])
        XCTAssertFalse(device.matchesPrinterHint)
    }

    // MARK: - Data.chunks(maxLength:) (chunked BLE writes)

    func testChunksSplitsPayloadIntoMaxLengthPieces() {
        let payload = Data([UInt8](repeating: 0xAB, count: 45))
        let chunks = payload.chunks(maxLength: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(chunks.reduce(Data(), +), payload)
    }

    func testChunksOfExactMultipleLeavesNoRemainder() {
        let payload = Data([UInt8](repeating: 0x01, count: 40))
        XCTAssertEqual(payload.chunks(maxLength: 20).map(\.count), [20, 20])
    }

    func testChunksOfEmptyDataIsEmpty() {
        XCTAssertEqual(Data().chunks(maxLength: 20).count, 0)
    }

    func testChunksWithNonPositiveMaxLengthIsEmpty() {
        XCTAssertEqual(Data([0x01]).chunks(maxLength: 0).count, 0)
    }
}
