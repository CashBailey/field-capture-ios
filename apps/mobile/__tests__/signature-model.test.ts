import {
  deserializeSignature,
  extendStroke,
  inkDots,
  isEmpty,
  pointCount,
  serializeSignature,
  startStroke,
  type SigStroke,
} from '../src/design/signatureModel';

describe('signature stroke model', () => {
  it('treats nothing-drawn as empty', () => {
    expect(isEmpty([])).toBe(true);
    expect(isEmpty([[]])).toBe(true);
    expect(isEmpty(startStroke([], { x: 1, y: 2 }))).toBe(false);
  });

  it('startStroke opens a new stroke, extendStroke grows the last one', () => {
    let s: SigStroke[] = startStroke([], { x: 0, y: 0 });
    s = extendStroke(s, { x: 10, y: 0 });
    s = startStroke(s, { x: 0, y: 20 });
    s = extendStroke(s, { x: 5, y: 25 });
    expect(s).toHaveLength(2);
    expect(s[0]).toHaveLength(2);
    expect(s[1]).toHaveLength(2);
    expect(pointCount(s)).toBe(4);
  });

  it('extendStroke before any pen-down still records the point', () => {
    expect(extendStroke([], { x: 3, y: 4 })).toEqual([[{ x: 3, y: 4 }]]);
  });

  it('does not mutate the input strokes', () => {
    const original = startStroke([], { x: 1, y: 1 });
    const snapshot = JSON.stringify(original);
    extendStroke(original, { x: 2, y: 2 });
    expect(JSON.stringify(original)).toBe(snapshot);
  });

  it('inkDots fills gaps so a sparse stroke reads as a continuous line', () => {
    const stroke = extendStroke(startStroke([], { x: 0, y: 0 }), { x: 30, y: 0 });
    const dots = inkDots(stroke, 3);
    // 30px gap at 3px step → at least 10 interpolated points plus the origin
    expect(dots.length).toBeGreaterThanOrEqual(11);
    expect(dots[0]).toEqual({ x: 0, y: 0 });
    expect(dots[dots.length - 1]).toEqual({ x: 30, y: 0 });
  });

  it('inkDots preserves a lone dot', () => {
    expect(inkDots(startStroke([], { x: 7, y: 9 }))).toEqual([{ x: 7, y: 9 }]);
  });

  it('serialize/deserialize round-trips (rounded to integers)', () => {
    let s = startStroke([], { x: 1.4, y: 2.6 });
    s = extendStroke(s, { x: 10.2, y: 4.9 });
    const round = deserializeSignature(serializeSignature(s));
    expect(round).toEqual([
      [
        { x: 1, y: 3 },
        { x: 10, y: 5 },
      ],
    ]);
  });

  it('deserialize tolerates garbage', () => {
    expect(deserializeSignature('not json')).toEqual([]);
    expect(deserializeSignature('{}')).toEqual([]);
  });
});
