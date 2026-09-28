// Port of adapters/printer/Pt210Module.ts — error taxonomy, `normalizePt210NativeError`, and the
// timeout-normalization helper (`timeout()` in the TS).
//
// The TS file splits this into two layers: a native module that rejects with raw
// `ERR_PT210_*` string codes (FieldPrinter.swift, the iOS CoreBluetooth implementation) and a JS
// bridge wrapper (`ReactNativePt210NativeBinding`) that normalizes those raw codes into the typed
// `Pt210ErrorCode` union. This Swift port collapses both layers into one: `Pt210PrinterTransport`
// IS the CoreBluetooth implementation, so it throws `Pt210NativeError` directly (constructed via
// `.make(_:_:)` from the same raw `ERR_PT210_*` codes FieldPrinter.swift used) instead of
// round-tripping through a bridge. `normalizePt210NativeError` is kept as a pure function so
// callers (print runtime, diagnostics) can classify any error the same way the TS did.
import FieldContracts

/// Same cases as the TS `Pt210ErrorCode` union. `.printerNotImplemented` is never the `code` of a
/// `Pt210NativeError` (mirrors the TS `Exclude<Pt210ErrorCode, 'printer-not-implemented'>` on
/// `Pt210NativeErrorInput`) — it only ever comes from classifying a `NotImplementedError`.
public enum Pt210ErrorCode: String, Equatable, Sendable {
    case printerNotImplemented = "printer-not-implemented"
    case transportError = "transport-error"
    case permissionDenied = "permission-denied"
    case bluetoothUnavailable = "bluetooth-unavailable"
    case bluetoothDisabled = "bluetooth-disabled"
    case discoveryFailed = "discovery-failed"
    case connectFailed = "connect-failed"
    case writeFailed = "write-failed"
    case notConnected = "not-connected"
    case noPriorDevice = "no-prior-device"
    case badDeviceId = "bad-device-id"
    case noWritableCharacteristic = "no-writable-characteristic"
    case timeout
    case nativeModuleInvalid = "native-module-invalid"
}

/// Port of the TS `NATIVE_ERROR_CODES` table — the raw ObjC/CoreBluetooth error codes
/// FieldPrinter.swift rejected with, mapped to the typed taxonomy above.
let pt210NativeErrorCodes: [String: Pt210ErrorCode] = [
    "ERR_PT210_PERMISSION_DENIED": .permissionDenied,
    "ERR_PT210_BLUETOOTH_UNAVAILABLE": .bluetoothUnavailable,
    "ERR_PT210_BLUETOOTH_DISABLED": .bluetoothDisabled,
    "ERR_PT210_DISCOVERY_FAILED": .discoveryFailed,
    "ERR_PT210_CONNECT_FAILED": .connectFailed,
    "ERR_PT210_WRITE_FAILED": .writeFailed,
    "ERR_PT210_NOT_CONNECTED": .notConnected,
    "ERR_PT210_NO_DEVICE": .noPriorDevice,
    "ERR_PT210_BAD_DEVICE_ID": .badDeviceId,
    "ERR_PT210_NO_WRITABLE_CHARACTERISTIC": .noWritableCharacteristic,
    "ERR_PT210_TIMEOUT": .timeout,
    "ERR_PT210_NATIVE_CONTRACT": .nativeModuleInvalid,
    "ERR_PT210_CONTEXT": .nativeModuleInvalid,
]

/// Port of the TS `Pt210NativeError` class — what the transport throws for every CoreBluetooth
/// failure (connect/write/discovery/timeout/etc). `nativeCode` keeps the original
/// `ERR_PT210_*` string for parity with FieldPrinter.swift's reject codes.
public struct Pt210NativeError: Error, CustomStringConvertible, Equatable, Sendable {
    public let code: Pt210ErrorCode
    public let message: String
    public let nativeCode: String?

    public var description: String { message }

    public init(code: Pt210ErrorCode, message: String, nativeCode: String? = nil) {
        self.code = code
        self.message = message
        self.nativeCode = nativeCode
    }

    /// Build from a raw `ERR_PT210_*` code the way FieldPrinter.swift's `reject(reject, code,
    /// message)` call sites did — looks the code up in the known taxonomy, falling back to
    /// `.transportError` for anything unrecognized (same fallback the TS `NATIVE_ERROR_CODES`
    /// lookup uses).
    public static func make(_ rawCode: String, _ message: String) -> Pt210NativeError {
        Pt210NativeError(code: pt210NativeErrorCodes[rawCode] ?? .transportError, message: message, nativeCode: rawCode)
    }

    static func timeoutError(_ label: String, _ timeoutMs: Int) -> Pt210NativeError {
        Pt210NativeError(
            code: .timeout, message: "\(label) timed out after \(timeoutMs)ms", nativeCode: "ERR_PT210_TIMEOUT")
    }
}

/// Port of the TS `Pt210NormalizedError` — the stable shape `normalizePt210NativeError` returns.
public struct Pt210NormalizedError: Equatable, Sendable {
    public let code: Pt210ErrorCode
    public let message: String
    public let nativeCode: String?

    public init(code: Pt210ErrorCode, message: String, nativeCode: String? = nil) {
        self.code = code
        self.message = message
        self.nativeCode = nativeCode
    }
}

/// Port of the TS `normalizePt210NativeError`. Classifies any error a caller (print runtime,
/// diagnostics) catches from printing: contracts' `NotImplementedError` (e.g. a placeholder
/// transport, or `EscPosEncoder.qr`/`.bitmap` before the profile verifies support) becomes
/// `printer-not-implemented`; a `Pt210NativeError` passes its code/message/nativeCode through
/// unchanged; anything else is scanned for an embedded `ERR_PT210_*` code (mirrors the TS
/// `nativeCodeFrom` regex fallback) and otherwise reported as `transport-error`.
public func normalizePt210NativeError(_ error: Error) -> Pt210NormalizedError {
    if let notImplemented = error as? NotImplementedError {
        return Pt210NormalizedError(code: .printerNotImplemented, message: notImplemented.description)
    }
    if let native = error as? Pt210NativeError {
        return Pt210NormalizedError(code: native.code, message: native.message, nativeCode: native.nativeCode)
    }
    let message = String(describing: error)
    let nativeCode = pt210NativeCode(inDescriptionOf: message)
    let code = nativeCode.flatMap { pt210NativeErrorCodes[$0] } ?? .transportError
    return Pt210NormalizedError(code: code, message: message, nativeCode: nativeCode)
}

/// Port of the TS `nativeCodeFrom` regex fallback (`/ERR_PT210_[A-Z_]+/`) for foreign errors that
/// were never routed through `Pt210NativeError.make`.
func pt210NativeCode(inDescriptionOf message: String) -> String? {
    guard let range = message.range(of: "ERR_PT210_[A-Z_]+", options: .regularExpression) else {
        return nil
    }
    return String(message[range])
}

/// Port of the TS `DEFAULT_TIMEOUT_MS`.
public let pt210DefaultTimeoutMs = 10_000

/// Port of the TS `timeout(options)` helper: `Math.max(1, options?.timeoutMs ?? DEFAULT_TIMEOUT_MS)`.
///
// ponytail: FieldPrinter.swift additionally treated a literal `0` as "unset" (`timeoutMs == 0 ?
// default : timeoutMs`) because its RN bridge always received a concrete NSNumber, never a real
// optional. Swift has real optionals, so one nil-coalescing normalization replaces both the JS
// wrapper's and the native module's separate defaulting — same externally observable behavior for
// every real caller (nil/omitted -> default; any positive value clamped to itself; non-positive
// clamped to 1ms).
public func normalizedPt210Timeout(_ timeoutMs: Int?) -> Int {
    max(1, timeoutMs ?? pt210DefaultTimeoutMs)
}
