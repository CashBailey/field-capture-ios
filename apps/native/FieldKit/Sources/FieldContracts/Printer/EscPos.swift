// Port of printer/escpos.ts — Minimal ESC/POS encoder (ADR 003). Implements ONLY the
// unconditional subset of the TS `EscPosEncoder` contract — plain text, bold, alignment,
// separators, feed, and GS v 0 raster bitmaps when the bound printer profile has verified bitmap
// support. `qr()` still throws until a hardware run proves the PT-210 QR/barcode command set.
//
// Byte sequences are the de-facto ESC/POS core set (Epson): ESC @ reset, ESC E n bold,
// ESC a n align, ESC d n feed. Text is kept ASCII-only with '?' for anything outside it —
// the PT-210 self-test reports PC936/GB18030, so raw UTF-8 punctuation can print as garbage.
//
// Output here must stay BYTE-EXACT with the TS encoder — this file backs the ported byte-level
// test vectors in EscPosTests.swift.
import Foundation

private let ESC: UInt8 = 0x1b
private let GS: UInt8 = 0x1d
private let LF: UInt8 = 0x0a

/// 58 mm paper at the common 32-chars-per-line density.
private let DEFAULT_SEPARATOR_WIDTH = 32

public struct EscPosRangeError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum EscPosAlign: Equatable, Sendable {
    case left
    case center
    case right
}

/**
 * Ported as a concrete `final class` rather than a protocol (TS's `EscPosEncoder` interface):
 * every builder method returns `this` in TS for fluent chaining, which in Swift means returning
 * `Self` — and a protocol with `Self`-returning requirements cannot be called through an
 * existential (`any EscPosEncoder`), only used as a generic constraint. `createEscPosEncoder`
 * needs to return a single concrete type callers chain off of, and `BasicEscPosEncoder` is the
 * only implementation in the TS source, so no polymorphism is lost by skipping the protocol.
 */
public final class EscPosEncoder {
    private var chunks: [UInt8] = []
    private let profile: PrinterProfile

    public init(profile: PrinterProfile) {
        self.profile = profile
    }

    @discardableResult
    public func reset() -> Self {
        chunks.append(contentsOf: [ESC, 0x40])
        return self
    }

    @discardableResult
    public func text(_ value: String) -> Self {
        for scalar in value.unicodeScalars {
            chunks.append(scalar.value <= 0x7f ? UInt8(scalar.value) : 0x3f)
        }
        chunks.append(LF)
        return self
    }

    @discardableResult
    public func bold(_ on: Bool) -> Self {
        chunks.append(contentsOf: [ESC, 0x45, on ? 1 : 0])
        return self
    }

    @discardableResult
    public func align(_ mode: EscPosAlign) -> Self {
        let code: UInt8 = mode == .left ? 0 : mode == .center ? 1 : 2
        chunks.append(contentsOf: [ESC, 0x61, code])
        return self
    }

    @discardableResult
    public func separator() -> Self {
        chunks.append(contentsOf: Array(repeating: UInt8(0x2d), count: DEFAULT_SEPARATOR_WIDTH))
        chunks.append(LF)
        return self
    }

    @discardableResult
    public func feed(_ lines: Int) throws -> Self {
        guard lines >= 0 && lines <= 255 else {
            throw EscPosRangeError("feed lines must be an integer in [0,255] (got \(lines))")
        }
        chunks.append(contentsOf: [ESC, 0x64, UInt8(lines)])
        return self
    }

    /// Only valid when the profile's supportsBitmap is verified true.
    @discardableResult
    public func bitmap(_ mono: MonoBitmap) throws -> Self {
        guard case .value(true) = profile.supportsBitmap else {
            throw NotImplementedError(
                "bitmap printing on \(profile.modelName) (supportsBitmap=\(describeUnknownableBool(profile.supportsBitmap)))"
            )
        }
        guard mono.widthPx > 0, mono.heightPx > 0 else {
            throw EscPosRangeError("bitmap width/height must be positive integers")
        }
        let widthBytes = (mono.widthPx + 7) / 8
        let expectedBytes = widthBytes * mono.heightPx
        guard mono.data.count == expectedBytes else {
            throw EscPosRangeError(
                "bitmap data length must be \(expectedBytes) bytes for \(mono.widthPx)x\(mono.heightPx) (got \(mono.data.count))"
            )
        }
        chunks.append(contentsOf: [
            GS, 0x76, 0x30, 0x00,
            UInt8(widthBytes & 0xff), UInt8((widthBytes >> 8) & 0xff),
            UInt8(mono.heightPx & 0xff), UInt8((mono.heightPx >> 8) & 0xff),
        ])
        chunks.append(contentsOf: mono.data)
        return self
    }

    /// Only valid when the profile's supportsQr is verified true.
    @discardableResult
    public func qr(_ data: String) throws -> Self {
        guard case .value(true) = profile.supportsQr else {
            throw NotImplementedError(
                "QR printing on \(profile.modelName) (supportsQr=\(describeUnknownableBool(profile.supportsQr)))"
            )
        }
        throw NotImplementedError("QR command selection (pending hardware spike)")
    }

    public func encode() -> Data {
        Data(chunks)
    }
}

private func describeUnknownableBool(_ value: Unknownable<Bool>) -> String {
    switch value {
    case .value(let b): return String(b)
    case .unknown: return "unknown"
    }
}

/// Build an encoder bound to a printer profile (the profile gates conditional features).
public func createEscPosEncoder(_ profile: PrinterProfile) -> EscPosEncoder {
    EscPosEncoder(profile: profile)
}
