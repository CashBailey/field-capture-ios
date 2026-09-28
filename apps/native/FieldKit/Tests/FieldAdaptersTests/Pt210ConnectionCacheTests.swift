import Foundation
import XCTest

@testable import FieldAdapters

final class Pt210ConnectionCacheTests: XCTestCase {
    func testDisconnectInvalidatesCachedConnectionState() async throws {
        let transport = transportWithCachedConnection()

        XCTAssertTrue(transport.isConnected())

        try await transport.disconnect()

        XCTAssertFalse(transport.isConnected())
    }

    func testReconnectFailureInvalidatesCachedConnectionState() async {
        let transport = transportWithCachedConnection()

        do {
            _ = try await transport.reconnect(timeoutMs: 1)
            XCTFail("Expected reconnect without a prior device to fail")
        } catch let error as Pt210NativeError {
            XCTAssertEqual(error.code, .noPriorDevice)
        } catch {
            XCTFail("Expected Pt210NativeError, got \(error)")
        }

        XCTAssertFalse(transport.isConnected())
    }

    func testWriteFailureInvalidatesCachedConnectionState() async {
        let transport = transportWithCachedConnection()

        do {
            _ = try await transport.writeBytes(Data([0x01]), timeoutMs: 1)
            XCTFail("Expected write without a live connection to fail")
        } catch let error as Pt210NativeError {
            XCTAssertEqual(error.code, .notConnected)
        } catch {
            XCTFail("Expected Pt210NativeError, got \(error)")
        }

        XCTAssertFalse(transport.isConnected())
    }

    private func transportWithCachedConnection() -> Pt210PrinterTransport {
        let transport = Pt210PrinterTransport()
        transport.updateCachedConnected(
            Pt210Status(
                state: .connected,
                connected: true,
                ready: true,
                deviceId: "cached-printer",
                deviceName: "PT-210",
                transport: .bleGatt
            ))
        return transport
    }
}
