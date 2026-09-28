/**
 * Minimal ESC/POS encoder (ADR 003). Implements ONLY the unconditional subset of the
 * `EscPosEncoder` contract — plain text, bold, alignment, separators, feed, and GS v 0 raster
 * bitmaps when the bound printer profile has verified bitmap support. `qr()` still throws until
 * a hardware run proves the PT-210 QR/barcode command set.
 *
 * Byte sequences are the de-facto ESC/POS core set (Epson): ESC @ reset, ESC E n bold,
 * ESC a n align, ESC d n feed. Text is kept ASCII-only with '?' for anything outside it —
 * the PT-210 self-test reports PC936/GB18030, so raw UTF-8 punctuation can print as garbage.
 */
import { NotImplementedError, type EscPosEncoder, type MonoBitmap, type PrinterProfile } from "./types";

const ESC = 0x1b;
const GS = 0x1d;
const LF = 0x0a;

/** 58 mm paper at the common 32-chars-per-line density. */
const DEFAULT_SEPARATOR_WIDTH = 32;

class BasicEscPosEncoder implements EscPosEncoder {
  private readonly chunks: number[] = [];

  constructor(private readonly profile: PrinterProfile) {}

  reset(): this {
    this.chunks.push(ESC, 0x40);
    return this;
  }

  text(value: string): this {
    for (const ch of value) {
      const cp = ch.codePointAt(0) as number;
      this.chunks.push(cp <= 0x7f ? cp : 0x3f);
    }
    this.chunks.push(LF);
    return this;
  }

  bold(on: boolean): this {
    this.chunks.push(ESC, 0x45, on ? 1 : 0);
    return this;
  }

  align(mode: "left" | "center" | "right"): this {
    this.chunks.push(ESC, 0x61, mode === "left" ? 0 : mode === "center" ? 1 : 2);
    return this;
  }

  separator(): this {
    for (let i = 0; i < DEFAULT_SEPARATOR_WIDTH; i++) this.chunks.push(0x2d);
    this.chunks.push(LF);
    return this;
  }

  feed(lines: number): this {
    if (!Number.isInteger(lines) || lines < 0 || lines > 255) {
      throw new RangeError(`feed lines must be an integer in [0,255] (got ${lines})`);
    }
    this.chunks.push(ESC, 0x64, lines);
    return this;
  }

  bitmap(_mono: MonoBitmap): this {
    if (this.profile.supportsBitmap !== true) {
      throw new NotImplementedError(
        `bitmap printing on ${this.profile.modelName} (supportsBitmap=${String(this.profile.supportsBitmap)})`,
      );
    }
    const mono = _mono;
    if (
      !Number.isInteger(mono.widthPx) ||
      !Number.isInteger(mono.heightPx) ||
      mono.widthPx <= 0 ||
      mono.heightPx <= 0
    ) {
      throw new RangeError("bitmap width/height must be positive integers");
    }
    const widthBytes = Math.ceil(mono.widthPx / 8);
    const expectedBytes = widthBytes * mono.heightPx;
    if (mono.data.length !== expectedBytes) {
      throw new RangeError(
        `bitmap data length must be ${expectedBytes} bytes for ${mono.widthPx}x${mono.heightPx} (got ${mono.data.length})`,
      );
    }
    this.chunks.push(
      GS,
      0x76,
      0x30,
      0x00,
      widthBytes & 0xff,
      (widthBytes >> 8) & 0xff,
      mono.heightPx & 0xff,
      (mono.heightPx >> 8) & 0xff,
      ...mono.data,
    );
    return this;
  }

  qr(_data: string): this {
    if (this.profile.supportsQr !== true) {
      throw new NotImplementedError(
        `QR printing on ${this.profile.modelName} (supportsQr=${String(this.profile.supportsQr)})`,
      );
    }
    throw new NotImplementedError("QR command selection (pending hardware spike)");
  }

  encode(): Uint8Array {
    return Uint8Array.from(this.chunks);
  }
}

/** Build an encoder bound to a printer profile (the profile gates conditional features). */
export function createEscPosEncoder(profile: PrinterProfile): EscPosEncoder {
  return new BasicEscPosEncoder(profile);
}
