// Port of printer/pt210-profile.ts
import Foundation

/// PT-210 profile (printer #1), updated from the verified iOS BLE/CoreBluetooth spike.
public let PT210_PROFILE = PrinterProfile(
    modelName: "PT-210",
    paperWidthMm: 58,
    commandSet: .value(.escpos),
    transport: .value(.bleGatt),
    printableWidthDots: .value(384),
    supportsBitmap: .value(true),
    supportsQr: .unknown,
    supportsCut: .value(false),
    supportsCashDrawer: .irrelevant,
    requiresVendorApp: .value(false),
    targetUse: "field ticket / receipt style printing"
)

/// Stable identifier used by PrintJob.printerProfileId.
public let PT210_PROFILE_ID = "pt210"

/**
 * BLE transport placeholder. It exists so the abstraction is complete and unit-testable, but
 * it throws NotImplementedError — the real iOS CoreBluetooth path lives in the native module
 * (FieldPrinter.swift), wired through Pt210PrinterTransport in the app target.
 */
public final class BleTransport: PrinterTransport, @unchecked Sendable {
    public let kind: PrinterTransportKind = .bleGatt
    private var connected = false

    public init() {}

    public func connect(_ deviceId: String) async throws {
        throw NotImplementedError("\(kind.rawValue) transport connect")
    }

    public func disconnect() async throws {
        connected = false
    }

    public func isConnected() -> Bool {
        connected
    }

    public func writeBytes(_ bytes: Data) async throws {
        throw NotImplementedError("\(kind.rawValue) transport writeBytes")
    }
}
