/**
 * Signature stroke model — pure geometry, no React, no native modules. This is the testable core
 * behind the finger-drawable SignaturePad: the pad collects touch points into strokes via
 * PanResponder, this module turns them into renderable ink and a compact serialized form.
 *
 * Why dots-with-interpolation instead of SVG paths: the dev build deliberately ships no
 * react-native-svg / gesture-handler (those force a native rebuild). A signature is therefore drawn
 * as a dense run of small circles; `inkDots` fills the gaps between sampled touch points so the line
 * reads as continuous at any signing speed. 100% JS, works in the existing dev client.
 */

/** A single sampled touch point, in the drawing surface's local coordinates. */
export interface SigPoint {
  x: number;
  y: number;
}

/** One continuous pen-down..pen-up stroke. */
export type SigStroke = SigPoint[];

/** Begin a new stroke (pen down) seeded with its first point. */
export function startStroke(strokes: readonly SigStroke[], point: SigPoint): SigStroke[] {
  return [...strokes, [point]];
}

/** Extend the most recent stroke (pen move). A no-op if no stroke is open yet. */
export function extendStroke(strokes: readonly SigStroke[], point: SigPoint): SigStroke[] {
  if (strokes.length === 0) return [[point]];
  const next = strokes.map((s) => s.slice());
  next[next.length - 1].push(point);
  return next;
}

/** True when nothing has been drawn (no strokes, or only empty strokes). */
export function isEmpty(strokes: readonly SigStroke[]): boolean {
  return strokes.every((s) => s.length === 0);
}

/** Total sampled points across all strokes. */
export function pointCount(strokes: readonly SigStroke[]): number {
  return strokes.reduce((n, s) => n + s.length, 0);
}

/**
 * Expand sampled strokes into a dense point cloud for rendering: every consecutive pair is filled
 * with interpolated points no farther apart than `step` px, so the rendered dots read as a line.
 * A lone point (a dot/period in a signature) is preserved.
 */
export function inkDots(strokes: readonly SigStroke[], step = 3): SigPoint[] {
  const out: SigPoint[] = [];
  for (const stroke of strokes) {
    if (stroke.length === 0) continue;
    out.push(stroke[0]);
    for (let i = 1; i < stroke.length; i++) {
      const a = stroke[i - 1];
      const b = stroke[i];
      const dist = Math.hypot(b.x - a.x, b.y - a.y);
      const segments = Math.max(1, Math.ceil(dist / step));
      for (let s = 1; s <= segments; s++) {
        out.push({ x: a.x + ((b.x - a.x) * s) / segments, y: a.y + ((b.y - a.y) * s) / segments });
      }
    }
  }
  return out;
}

/** Compact serialization (integer-rounded) suitable for persisting as the signature artifact. */
export function serializeSignature(strokes: readonly SigStroke[]): string {
  const rounded = strokes.map((s) => s.map((p) => [Math.round(p.x), Math.round(p.y)]));
  return JSON.stringify({ v: 1, strokes: rounded });
}

/** Inverse of {@link serializeSignature}; returns [] for empty/garbage input. */
export function deserializeSignature(raw: string): SigStroke[] {
  try {
    const parsed = JSON.parse(raw) as { strokes?: number[][][] };
    if (!parsed.strokes) return [];
    return parsed.strokes.map((s) => s.map(([x, y]) => ({ x, y })));
  } catch {
    return [];
  }
}
