import Foundation
// Port of test/escpos.test.ts
import XCTest

@testable import FieldContracts

final class EscPosTests: XCTestCase {
    func testEmitsTheCoreEscPosByteSequences() throws {
        let bytes = try createEscPosEncoder(PT210_PROFILE)
            .reset()
            .align(.center)
            .bold(true)
            .text("FIELD")
            .bold(false)
            .feed(2)
            .encode()
        XCTAssertEqual(
            [UInt8](bytes),
            [
                0x1b, 0x40,  // ESC @ reset
                0x1b, 0x61, 0x01,  // ESC a 1 center
                0x1b, 0x45, 0x01,  // ESC E 1 bold on
                0x47, 0x41, 0x54, 0x4f, 0x52, 0x0a,  // "FIELD" + LF
                0x1b, 0x45, 0x00,  // bold off
                0x1b, 0x64, 0x02,  // ESC d 2 feed
            ])
    }

    func testSeparatorIsAFull32CharDashedLine() {
        let bytes = createEscPosEncoder(PT210_PROFILE).separator().encode()
        XCTAssertEqual(bytes.count, 33)
        XCTAssertEqual(bytes.first, 0x2d)
        XCTAssertEqual([UInt8](bytes)[32], 0x0a)
    }

    func testNonAsciiCharactersDegradeToQuestionMarkInsteadOfPrinterGarbage() {
        let bytes = createEscPosEncoder(PT210_PROFILE).text("aé灣b").encode()
        XCTAssertEqual([UInt8](bytes), [0x61, 0x3f, 0x3f, 0x62, 0x0a])
    }

    func testRejectsOutOfRangeFeed() {
        XCTAssertThrowsError(try createEscPosEncoder(PT210_PROFILE).feed(-1)) { error in
            XCTAssertTrue(error is EscPosRangeError)
        }
        XCTAssertThrowsError(try createEscPosEncoder(PT210_PROFILE).feed(256)) { error in
            XCTAssertTrue(error is EscPosRangeError)
        }
    }

    func testEmitsGsV0RasterBytesForVerifiedPt210Bitmaps() throws {
        let bytes = try createEscPosEncoder(PT210_PROFILE)
            .bitmap(MonoBitmap(widthPx: 8, heightPx: 1, data: Data([0x81])))
            .encode()
        XCTAssertEqual([UInt8](bytes), [0x1d, 0x76, 0x30, 0x00, 0x01, 0x00, 0x01, 0x00, 0x81])
    }

    func testRejectsMalformedBitmapDimensionsAndPayloadSizes() {
        XCTAssertThrowsError(
            try createEscPosEncoder(PT210_PROFILE).bitmap(MonoBitmap(widthPx: 8, heightPx: 2, data: Data(count: 1)))
        ) { error in
            XCTAssertTrue(error is EscPosRangeError)
        }
    }

    func testBitmapStillThrowsNotImplementedErrorWhileAProfilesCapabilityIsUnverified() {
        var unverified = PT210_PROFILE
        unverified.supportsBitmap = .unknown
        let enc = createEscPosEncoder(unverified)
        XCTAssertThrowsError(try enc.bitmap(MonoBitmap(widthPx: 8, heightPx: 1, data: Data(count: 1)))) { error in
            XCTAssertTrue(error is NotImplementedError)
        }
    }

    func testQrThrowsWhileThePt210CommandRemainsUnverified() {
        let enc = createEscPosEncoder(PT210_PROFILE)
        XCTAssertThrowsError(try enc.qr("x")) { error in
            XCTAssertTrue(error is NotImplementedError)
        }
    }

    func testEvenAVerifiedTrueQrProfileDefersQrCommandsToTheSpike() {
        var verified = PT210_PROFILE
        verified.supportsBitmap = .value(true)
        verified.supportsQr = .value(true)
        let enc = createEscPosEncoder(verified)
        XCTAssertThrowsError(try enc.qr("x")) { error in
            XCTAssertTrue("\(error)".contains("pending hardware spike"))
        }
    }
}
