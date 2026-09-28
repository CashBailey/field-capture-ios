// Port of adapters/printer/Pt210Module.ts — the wire-shape types (`Pt210ConnectionState`,
// `Pt210Status`) and the discovery result FieldPrinter.swift returns (`DiscoveredBlePrinter`,
// née the TS `Pt210DiscoveredDevice`).
import FieldContracts

/// Port of the TS `Pt210ConnectionState` union. FieldPrinter.swift's `statusMap` only ever
/// produces `.connected`/`.disconnected` on iOS today (the other cases exist for parity with the
/// full TS union other transports/platforms could report) — preserved rather than trimmed, since
/// narrowing the enum would be a silent contract change for any caller pattern-matching on it.
public enum Pt210ConnectionState: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case writing
    case error
}

/// Port of the TS `Pt210Status` interface.
public struct Pt210Status: Equatable, Sendable {
    public var state: Pt210ConnectionState
    public var connected: Bool
    public var ready: Bool
    public var deviceId: String?
    public var deviceName: String?
    public var transport: PrinterTransportKind?
    public var errorCode: String?
    public var message: String?

    public init(
        state: Pt210ConnectionState,
        connected: Bool,
        ready: Bool,
        deviceId: String? = nil,
        deviceName: String? = nil,
        transport: PrinterTransportKind? = nil,
        errorCode: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.connected = connected
        self.ready = ready
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.transport = transport
        self.errorCode = errorCode
        self.message = message
    }
}

/// Port of the TS `Pt210DiscoveredDevice` / FieldPrinter.swift's private `DiscoveredBlePrinter`,
/// promoted to a public result type since it is now the direct return value of `discover(...)`
/// instead of an `NSDictionary` crossing the RN bridge.
public struct DiscoveredBlePrinter: Equatable, Sendable {
    public var deviceId: String
    public var name: String
    /// FieldPrinter.swift's BLE scan never determines OS-level pairing state — it always reports
    /// `false` here (kept for shape parity with the TS type, not a deviation).
    public var paired: Bool
    public var transport: PrinterTransportKind
    public var rssi: Int
    public var advertisedServiceUUIDs: [String]

    public init(
        deviceId: String,
        name: String,
        paired: Bool = false,
        transport: PrinterTransportKind = .bleGatt,
        rssi: Int,
        advertisedServiceUUIDs: [String]
    ) {
        self.deviceId = deviceId
        self.name = name
        self.paired = paired
        self.transport = transport
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
    }

    /// Port of FieldPrinter.swift's `exactNameMatch`.
    var exactNameMatch: Bool { Pt210PrinterTransport.isExactPrinterName(name) }

    /// Port of FieldPrinter.swift's `nameHintMatch`.
    var nameHintMatch: Bool { Pt210PrinterTransport.isLikelyPrinterName(name) }

    /// Port of FieldPrinter.swift's `serviceHintMatch`.
    var serviceHintMatch: Bool {
        advertisedServiceUUIDs.contains { Pt210PrinterTransport.knownServiceUUIDs.contains($0.uppercased()) }
    }

    /// Port of FieldPrinter.swift's `matchesPrinterHint` — discovery filter.
    var matchesPrinterHint: Bool { exactNameMatch || nameHintMatch || serviceHintMatch }
}
