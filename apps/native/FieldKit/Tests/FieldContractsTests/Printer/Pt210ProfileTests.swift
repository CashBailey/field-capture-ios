import Foundation
// Port of test/pt210-profile.test.ts
import XCTest

@testable import FieldContracts

final class Pt210ProfileTests: XCTestCase {
    // ---- PT-210 profile ----

    func testIs58mmAndTargetsFieldTicketReceiptPrinting() {
        XCTAssertEqual(PT210_PROFILE.modelName, "PT-210")
        XCTAssertEqual(PT210_PROFILE.paperWidthMm, 58)
        XCTAssertEqual(PT210_PROFILE.supportsCashDrawer, .irrelevant)
        XCTAssertEqual(PT210_PROFILE_ID, "pt210")
    }

    func testRecordsThePt210ValuesProvenByTheIosBleSpike() {
        XCTAssertEqual(PT210_PROFILE.commandSet, .value(.escpos))
        XCTAssertEqual(PT210_PROFILE.transport, .value(.bleGatt))
        XCTAssertEqual(PT210_PROFILE.printableWidthDots, .value(384))
        XCTAssertEqual(PT210_PROFILE.supportsBitmap, .value(true))
        XCTAssertEqual(PT210_PROFILE.supportsQr, .unknown)
        XCTAssertEqual(PT210_PROFILE.supportsCut, .value(false))
        XCTAssertEqual(PT210_PROFILE.requiresVendorApp, .value(false))
    }

    // ---- BLE transport placeholder ----

    func testExposesItsKindButThrowsUntilTheNativeModuleProvesThePathOnHardware() async throws {
        let t = BleTransport()
        XCTAssertEqual(t.kind, .bleGatt)
        XCTAssertFalse(t.isConnected())
        do {
            try await t.connect("dev-1")
            XCTFail("expected connect to throw")
        } catch {
            XCTAssertTrue(error is NotImplementedError)
        }
        do {
            try await t.writeBytes(Data([0x1b, 0x40]))
            XCTFail("expected writeBytes to throw")
        } catch {
            XCTAssertTrue(error is NotImplementedError)
        }
    }
}
