//
//  SignatureModel.swift
//  Ported from apps/mobile/src/design/signatureModel.ts
//
//  Signature stroke model — pure geometry, no view code. This is the testable core behind the
//  finger-drawable SignaturePad: the pad collects touch points into strokes via a drag gesture, this
//  file turns them into renderable ink and a compact serialized form.
//
//  Why dots-with-interpolation instead of a drawn path: mirrors the RN source's dependency-free
//  design (it ships no react-native-svg there, deliberately). A signature is a dense run of small
//  circles; `inkDots` fills the gaps between sampled touch points so the line reads as continuous at
//  any signing speed.
//
//  The serialized format is persisted/uploaded and MUST stay byte-identical to the TS
//  `serializeSignature`: `{"v":1,"strokes":[[[x,y],...],...]}`, integer-rounded, no whitespace, `v`
//  before `strokes`. Built by hand below rather than via JSONEncoder/Codable so the key order and
//  formatting can't drift with Foundation's encoder internals.
//

import Foundation

/// A single sampled touch point, in the drawing surface's local coordinates.
struct SigPoint: Equatable {
    var x: Double
    var y: Double
}

/// One continuous pen-down..pen-up stroke.
typealias SigStroke = [SigPoint]

/// Begin a new stroke (pen down) seeded with its first point.
func startStroke(_ strokes: [SigStroke], point: SigPoint) -> [SigStroke] {
    strokes + [[point]]
}

/// Extend the most recent stroke (pen move). A no-op-equivalent (starts a stroke) if none is open yet.
func extendStroke(_ strokes: [SigStroke], point: SigPoint) -> [SigStroke] {
    guard !strokes.isEmpty else { return [[point]] }
    var next = strokes
    next[next.count - 1].append(point)
    return next
}

/// True when nothing has been drawn (no strokes, or only empty strokes).
func isEmpty(_ strokes: [SigStroke]) -> Bool {
    strokes.allSatisfy { $0.isEmpty }
}

/// Total sampled points across all strokes.
func pointCount(_ strokes: [SigStroke]) -> Int {
    strokes.reduce(0) { $0 + $1.count }
}

/// Expand sampled strokes into a dense point cloud for rendering: every consecutive pair is filled
/// with interpolated points no farther apart than `step` px, so the rendered dots read as a line. A
/// lone point (a dot/period in a signature) is preserved.
func inkDots(_ strokes: [SigStroke], step: Double = 3) -> [SigPoint] {
    var out: [SigPoint] = []
    for stroke in strokes {
        guard !stroke.isEmpty else { continue }
        out.append(stroke[0])
        for i in 1..<stroke.count {
            let a = stroke[i - 1]
            let b = stroke[i]
            let dist = hypot(b.x - a.x, b.y - a.y)
            let segments = max(1, Int(ceil(dist / step)))
            for s in 1...segments {
                let t = Double(s) / Double(segments)
                out.append(SigPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
    }
    return out
}

/// Compact serialization (integer-rounded) suitable for persisting as the signature artifact.
/// ponytail: rounds half-away-from-zero (Swift's `.rounded()` default), matching JS `Math.round` for
/// all non-negative coordinates — the only domain touch points ever produce.
func serializeSignature(_ strokes: [SigStroke]) -> String {
    let strokesJSON = strokes.map { stroke -> String in
        let points = stroke.map { p -> String in
            "[\(Int(p.x.rounded())),\(Int(p.y.rounded()))]"
        }
        return "[\(points.joined(separator: ","))]"
    }
    return "{\"v\":1,\"strokes\":[\(strokesJSON.joined(separator: ","))]}"
}

private struct SerializedSignature: Decodable {
    var v: Int?
    var strokes: [[[Double]]]?
}

/// Inverse of `serializeSignature`; returns `[]` for empty/garbage input.
func deserializeSignature(_ raw: String) -> [SigStroke] {
    guard let data = raw.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(SerializedSignature.self, from: data),
        let strokes = parsed.strokes
    else {
        return []
    }
    return strokes.map { stroke in
        stroke.compactMap { point in
            point.count >= 2 ? SigPoint(x: point[0], y: point[1]) : nil
        }
    }
}
