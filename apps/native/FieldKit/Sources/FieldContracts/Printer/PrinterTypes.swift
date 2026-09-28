// Port of printer/types.ts — Printer abstraction contracts (ADR 003, docs/printer-pt210.md).
//
// Rules encoded here:
// - All printing flows through PrinterService / PrinterTransport. No screen-to-printer code.
// - PT-210 is target printer #1, connected over iOS BLE GATT (CoreBluetooth).
// - Transport/command-set fields are `.unknown` sentinels until a real device fills them in
//   via PrinterDiagnosticReport.
// - Printing is NOT source of truth. Every print job/event is logged locally and syncable.
// - UID / card / NFC concerns are NOT part of the printer module.
import Foundation

/// Thrown by transport placeholders until the native module proves the path on hardware.
public struct NotImplementedError: Error, CustomStringConvertible, Equatable {
    public let what: String
    public var description: String {
        "\(what) is not implemented yet — gated on the PT-210 hardware spike (ADR 003)."
    }
    public init(_ what: String) { self.what = what }
}

/// Tri-state for capabilities/transport that the spike has not yet verified (TS `T | "unknown"`).
public enum Unknownable<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case unknown
}

public enum PrinterTransportKind: String, Equatable, Sendable, Codable {
    case bleGatt = "ble-gatt"
}

public enum PrinterCommandSet: String, Equatable, Sendable, Codable {
    case escpos
    case proprietary
}

/// TS literal type `"irrelevant"` on `PrinterProfile.supportsCashDrawer` — a single-value marker,
/// modeled here as a one-case enum for the same type safety the TS literal type gives.
public enum CashDrawerSupport: String, Equatable, Sendable, Codable {
    case irrelevant
}

/// Capability descriptor per printer model. `.unknown` until verified by the spike.
public struct PrinterProfile: Equatable, Sendable {
    public var modelName: String
    /// Paper width in millimetres (PT-210 = 58).
    public var paperWidthMm: Double
    /// Likely ESC/POS for PT-210 but MUST be verified.
    public var commandSet: Unknownable<PrinterCommandSet>
    /// iOS BLE GATT (CoreBluetooth) for the PT-210.
    public var transport: Unknownable<PrinterTransportKind>
    /// Printable width in dots; set from self-test or manual verification.
    public var printableWidthDots: Unknownable<Int>
    public var supportsBitmap: Unknownable<Bool>
    public var supportsQr: Unknownable<Bool>
    /// Probably false for a handheld 58mm printer; verify before changing.
    public var supportsCut: Unknownable<Bool>
    /// Irrelevant for a handheld receipt printer.
    public var supportsCashDrawer: CashDrawerSupport
    /// Whether the unit requires a vendor app (would fail the forbidden-workflow rule).
    public var requiresVendorApp: Unknownable<Bool>
    public var targetUse: String

    public init(
        modelName: String,
        paperWidthMm: Double,
        commandSet: Unknownable<PrinterCommandSet>,
        transport: Unknownable<PrinterTransportKind>,
        printableWidthDots: Unknownable<Int>,
        supportsBitmap: Unknownable<Bool>,
        supportsQr: Unknownable<Bool>,
        supportsCut: Unknownable<Bool>,
        supportsCashDrawer: CashDrawerSupport,
        requiresVendorApp: Unknownable<Bool>,
        targetUse: String
    ) {
        self.modelName = modelName
        self.paperWidthMm = paperWidthMm
        self.commandSet = commandSet
        self.transport = transport
        self.printableWidthDots = printableWidthDots
        self.supportsBitmap = supportsBitmap
        self.supportsQr = supportsQr
        self.supportsCut = supportsCut
        self.supportsCashDrawer = supportsCashDrawer
        self.requiresVendorApp = requiresVendorApp
        self.targetUse = targetUse
    }
}

/// Moves raw bytes to a device. Implemented by the native module, one class per transport.
public protocol PrinterTransport: AnyObject, Sendable {
    var kind: PrinterTransportKind { get }
    func connect(_ deviceId: String) async throws
    func disconnect() async throws
    func isConnected() -> Bool
    /// Write a raw byte stream (e.g. an ESC/POS payload) to the connected device.
    func writeBytes(_ bytes: Data) async throws
}

/// 1-bit-per-pixel bitmap (signatures, ticket renders). width should match printableWidthDots.
public struct MonoBitmap: Equatable, Sendable {
    public var widthPx: Int
    public var heightPx: Int
    /// Row-major 1bpp packed bytes.
    public var data: Data

    public init(widthPx: Int, heightPx: Int, data: Data) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.data = data
    }
}

public enum PrintJobStatus: String, Equatable, Sendable, Codable {
    case queued
    case rendering
    case printing
    case printed
    case synced
    case failed
    case canceled
}

/**
 * Print job model (ADR 003 / Slice 4). A print job is an output artifact, not truth.
 * It must be logged on creation and on every status change, then synced to Hub.
 */
public struct PrintJob: Equatable, Sendable {
    public var printJobId: String
    public var srId: String
    public var fieldTicketId: String
    /// One of these identifies the actor.
    public var employeeId: String?
    public var workerRef: String?
    public var printerProfileId: String
    public var createdAt: String
    public var printedAt: String?
    public var syncedAt: String?
    public var status: PrintJobStatus
    public var retryCount: Int
    public var errorCode: String?
    public var diagnosticMessage: String?
    /// Hash of the finalized payload — durable record stored only after payload is finalized.
    public var payloadHash: String
    public var payloadSizeBytes: Int

    public init(
        printJobId: String,
        srId: String,
        fieldTicketId: String,
        employeeId: String? = nil,
        workerRef: String? = nil,
        printerProfileId: String,
        createdAt: String,
        printedAt: String? = nil,
        syncedAt: String? = nil,
        status: PrintJobStatus,
        retryCount: Int,
        errorCode: String? = nil,
        diagnosticMessage: String? = nil,
        payloadHash: String,
        payloadSizeBytes: Int
    ) {
        self.printJobId = printJobId
        self.srId = srId
        self.fieldTicketId = fieldTicketId
        self.employeeId = employeeId
        self.workerRef = workerRef
        self.printerProfileId = printerProfileId
        self.createdAt = createdAt
        self.printedAt = printedAt
        self.syncedAt = syncedAt
        self.status = status
        self.retryCount = retryCount
        self.errorCode = errorCode
        self.diagnosticMessage = diagnosticMessage
        self.payloadHash = payloadHash
        self.payloadSizeBytes = payloadSizeBytes
    }
}

/// Outcome of one print attempt.
public struct PrintResult: Equatable, Sendable {
    public var printJobId: String
    public var ok: Bool
    public var status: PrintJobStatus
    public var errorCode: String?
    public var diagnosticMessage: String?

    public init(
        printJobId: String, ok: Bool, status: PrintJobStatus, errorCode: String? = nil, diagnosticMessage: String? = nil
    ) {
        self.printJobId = printJobId
        self.ok = ok
        self.status = status
        self.errorCode = errorCode
        self.diagnosticMessage = diagnosticMessage
    }
}

public enum SpikeCheck: String, Equatable, Sendable, Codable {
    case pass
    case fail
    case untested
}

public struct PrinterDiagnosticChecks: Equatable, Sendable {
    public var discovery: SpikeCheck
    public var connect: SpikeCheck
    public var plainText: SpikeCheck
    public var boldLarge: SpikeCheck
    public var alignment: SpikeCheck
    public var separators: SpikeCheck
    public var fieldTicketMock: SpikeCheck
    public var jhaJsaReceipt: SpikeCheck
    public var signatureBitmap: SpikeCheck
    public var qrBarcode: SpikeCheck
    public var statusReady: SpikeCheck
    public var reconnectAfterRestart: SpikeCheck
    public var reconnectAfterSleep: SpikeCheck
    public var reconnectAfterDisconnect: SpikeCheck
    public var disconnect: SpikeCheck
    public var offlineQueuedJob: SpikeCheck

    public init(
        discovery: SpikeCheck, connect: SpikeCheck, plainText: SpikeCheck, boldLarge: SpikeCheck,
        alignment: SpikeCheck, separators: SpikeCheck, fieldTicketMock: SpikeCheck, jhaJsaReceipt: SpikeCheck,
        signatureBitmap: SpikeCheck, qrBarcode: SpikeCheck, statusReady: SpikeCheck,
        reconnectAfterRestart: SpikeCheck, reconnectAfterSleep: SpikeCheck, reconnectAfterDisconnect: SpikeCheck,
        disconnect: SpikeCheck, offlineQueuedJob: SpikeCheck
    ) {
        self.discovery = discovery
        self.connect = connect
        self.plainText = plainText
        self.boldLarge = boldLarge
        self.alignment = alignment
        self.separators = separators
        self.fieldTicketMock = fieldTicketMock
        self.jhaJsaReceipt = jhaJsaReceipt
        self.signatureBitmap = signatureBitmap
        self.qrBarcode = qrBarcode
        self.statusReady = statusReady
        self.reconnectAfterRestart = reconnectAfterRestart
        self.reconnectAfterSleep = reconnectAfterSleep
        self.reconnectAfterDisconnect = reconnectAfterDisconnect
        self.disconnect = disconnect
        self.offlineQueuedJob = offlineQueuedJob
    }
}

/// Inline TS union `Unknownable<PrinterTransportKind> | "none"` on
/// `PrinterDiagnosticReport.connectedTransport`.
public enum ConnectedTransport: Equatable, Sendable {
    case value(PrinterTransportKind)
    case unknown
    case none
}

/// Conclusion that feeds the ADR 001 gate.
public enum PrinterGateOutcome: String, Equatable, Sendable, Codable {
    case confirmedBleIos = "confirmed-ble-ios"
    case replacePrinterVendorApp = "replace-printer-vendor-app"
    case replacePrinterProprietary = "replace-printer-proprietary"
    case pending
}

/// Structured output of the hardware spike + runtime self-tests.
public struct PrinterDiagnosticReport: Equatable, Sendable {
    public var modelName: String
    public var ranAt: String
    /// Platform the diagnostic ran on (iOS-only app) — TS literal type `"ios"`.
    public var platform: String = "ios"
    public var connectedTransport: ConnectedTransport
    public var commandSet: Unknownable<PrinterCommandSet>
    public var printableWidthDots: Unknownable<Int>
    public var requiresVendorApp: Unknownable<Bool>
    public var checks: PrinterDiagnosticChecks
    public var gateOutcome: PrinterGateOutcome
    public var notes: String?

    public init(
        modelName: String,
        ranAt: String,
        connectedTransport: ConnectedTransport,
        commandSet: Unknownable<PrinterCommandSet>,
        printableWidthDots: Unknownable<Int>,
        requiresVendorApp: Unknownable<Bool>,
        checks: PrinterDiagnosticChecks,
        gateOutcome: PrinterGateOutcome,
        notes: String? = nil
    ) {
        self.modelName = modelName
        self.ranAt = ranAt
        self.connectedTransport = connectedTransport
        self.commandSet = commandSet
        self.printableWidthDots = printableWidthDots
        self.requiresVendorApp = requiresVendorApp
        self.checks = checks
        self.gateOutcome = gateOutcome
        self.notes = notes
    }
}

/// Top-level API used by features. Owns the queue, selects profile + transport.
public protocol PrinterService: Sendable {
    func diagnose(_ profile: PrinterProfile) async throws -> PrinterDiagnosticReport
    func print(_ job: PrintJob, payload: Data) async throws -> PrintResult
}
