import FieldContracts
// Port of the error-normalization/timeout assertions in
// apps/mobile/__tests__/print-runtime.test.ts ("placeholder behavior" + "PT-210 native binding
// boundary" describe blocks) — the parts that don't require CoreBluetooth.
import XCTest

@testable import FieldAdapters

final class Pt210ErrorsTests: XCTestCase {
    // MARK: - normalizePt210NativeError

    func testNormalizesNativeModuleAbsenceToPrinterNotImplemented() {
        let error = NotImplementedError("x")
        XCTAssertEqual(normalizePt210NativeError(error).code, .printerNotImplemented)
    }

    func testNormalizesAnUnrecognizedErrorToTransportError() {
        struct SocketClosed: Error, CustomStringConvertible {
            var description: String { "socket closed" }
        }
        XCTAssertEqual(normalizePt210NativeError(SocketClosed()).code, .transportError)
    }

    func testNormalizesAPt210NativeErrorPassthrough() {
        let error = Pt210NativeError(
            code: .permissionDenied, message: "BLUETOOTH_CONNECT permission is required",
            nativeCode: "ERR_PT210_PERMISSION_DENIED")
        let normalized = normalizePt210NativeError(error)
        XCTAssertEqual(normalized.code, .permissionDenied)
        XCTAssertEqual(normalized.nativeCode, "ERR_PT210_PERMISSION_DENIED")
    }

    func testMapsWriteFailureAndReconnectFailureRawCodes() {
        XCTAssertEqual(Pt210NativeError.make("ERR_PT210_WRITE_FAILED", "socket closed").code, .writeFailed)
        XCTAssertEqual(Pt210NativeError.make("ERR_PT210_NO_DEVICE", "No previous PT-210 device").code, .noPriorDevice)
    }

    func testMapsMissingWritableCharacteristicRawCode() {
        let error = Pt210NativeError.make(
            "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
            "No PT-210 write-with-response characteristic found"
        )
        XCTAssertEqual(error.code, .noWritableCharacteristic)
        XCTAssertEqual(error.nativeCode, "ERR_PT210_NO_WRITABLE_CHARACTERISTIC")
    }

    func testUnknownRawCodeFallsBackToTransportError() {
        XCTAssertEqual(Pt210NativeError.make("ERR_PT210_SOMETHING_NEW", "?").code, .transportError)
    }

    func testEveryKnownFieldPrinterRawCodeMapsToATypedCode() {
        // Every ERR_PT210_* code FieldPrinter.swift's `reject(reject, code, message)` call sites
        // use must resolve to something other than the transport-error fallback.
        let rawCodes = [
            "ERR_PT210_BLUETOOTH_UNAVAILABLE",
            "ERR_PT210_PERMISSION_DENIED",
            "ERR_PT210_BLUETOOTH_DISABLED",
            "ERR_PT210_DISCOVERY_FAILED",
            "ERR_PT210_CONNECT_FAILED",
            "ERR_PT210_WRITE_FAILED",
            "ERR_PT210_NOT_CONNECTED",
            "ERR_PT210_NO_DEVICE",
            "ERR_PT210_BAD_DEVICE_ID",
            "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
            "ERR_PT210_TIMEOUT",
        ]
        for code in rawCodes {
            XCTAssertNotEqual(
                Pt210NativeError.make(code, "msg").code, .transportError,
                "\(code) should not fall back to transport-error")
        }
    }

    func testExtractsAnEmbeddedRawCodeFromAForeignErrorDescription() {
        struct Foreign: Error, CustomStringConvertible {
            var description: String { "Error Domain=CBError Code=1 ERR_PT210_BLUETOOTH_DISABLED" }
        }
        let normalized = normalizePt210NativeError(Foreign())
        XCTAssertEqual(normalized.code, .bluetoothDisabled)
        XCTAssertEqual(normalized.nativeCode, "ERR_PT210_BLUETOOTH_DISABLED")
    }

    // MARK: - timeout normalization (port of TS `timeout(options)`)

    func testDefaultsToTenSecondsWhenNoTimeoutIsGiven() {
        XCTAssertEqual(normalizedPt210Timeout(nil), 10_000)
    }

    func testPassesThroughAPositiveTimeout() {
        XCTAssertEqual(normalizedPt210Timeout(1234), 1234)
    }

    func testClampsZeroAndNegativeTimeoutsToOneMillisecond() {
        XCTAssertEqual(normalizedPt210Timeout(0), 1)
        XCTAssertEqual(normalizedPt210Timeout(-50), 1)
    }
}
