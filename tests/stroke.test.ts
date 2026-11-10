import { describe, expect, it } from 'vitest';
import { generateStrokes } from '../src/core/benchmark';
import { buildSamples, computeBBox, createStroke, hitTestStroke, PointBuffer, pressureToWidth } from '../src/core/stroke';
import { POINT_STRIDE, createPage } from '../src/core/types';

function points(...xy: [number, number, number?][]): Float32Array {
  const b = new PointBuffer();
  xy.forEach(([x, y, p], i) => b.push(x, y, i * 8, p ?? 0.5, 0, 0));
  return b.toArray();
}

describe('largeur selon la pression', () => {
  it('vaut la largeur nominale à pression 0,5 et croît avec la pression', () => {
    expect(pressureToWidth(2, 0.5)).toBeCloseTo(2);
    expect(pressureToWidth(2, 0.9)).toBeGreaterThan(pressureToWidth(2, 0.2));
    expect(pressureToWidth(2, 5)).toBeCloseTo(pressureToWidth(2, 1));
    expect(pressureToWidth(2, -1)).toBeGreaterThan(0);
  });
});

describe('tampon de points', () => {
  it('s’agrandit sans perdre de données', () => {
    const b = new PointBuffer();
    for (let i = 0; i < 1000; i++) b.push(i, -i, i, 0.5, 1, 2);
    const a = b.toArray();
    expect(a.length).toBe(1000 * POINT_STRIDE);
    expect(Array.from(a.slice(999 * POINT_STRIDE))).toEqual([999, -999, 999, 0.5, 1, 2]);
  });
});

describe('lissage', () => {
  it('conserve exactement les extrémités', () => {
    const p = points([0, 0], [10, 5], [20, -5], [30, 0]);
    const s = buildSamples(p, 4, 1);
    expect([s[0], s[1]]).toEqual([0, 0]);
    expect([s[s.length - 3], s[s.length - 2]]).toEqual([30, 0]);
  });

  it('reste dans l’enveloppe des points saisis (pas de déformation hors tracé)', () => {
    const p = points([0, 0], [10, 8], [20, -6], [30, 4], [40, 0]);
    const s = buildSamples(p, 5, 1);
    for (let i = 0; i < s.length; i += 3) {
      expect(s[i]).toBeGreaterThanOrEqual(0);
      expect(s[i]).toBeLessThanOrEqual(40);
      expect(s[i + 1]).toBeGreaterThanOrEqual(-6);
      expect(s[i + 1]).toBeLessThanOrEqual(8);
    }
  });

  it('ne déplace pas une ligne droite', () => {
    const p = points([0, 0], [10, 10], [20, 20], [30, 30]);
    const s = buildSamples(p, 4, 1);
    for (let i = 0; i < s.length; i += 3) expect(s[i + 1]).toBeCloseTo(s[i], 5);
  });

  it('est déterministe', () => {
    const p = points([0, 0, 0.2], [3, 9, 0.8], [12, 4, 0.6], [15, 15, 0.3]);
    expect(Array.from(buildSamples(p, 4, 1.1))).toEqual(Array.from(buildSamples(p.slice(), 4, 1.1)));
  });

  it('gère zéro, un et deux points', () => {
    expect(buildSamples(new Float32Array(0), 0, 1).length).toBe(0);
    expect(buildSamples(points([4, 5]), 1, 1).length).toBe(3);
    expect(buildSamples(points([0, 0], [1, 1]), 2, 1).length).toBe(9);
  });

  it('produit un trait plus large quand la pression est plus forte', () => {
    const light = buildSamples(points([0, 0, 0.1], [5, 0, 0.1], [10, 0, 0.1]), 3, 1);
    const heavy = buildSamples(points([0, 0, 0.9], [5, 0, 0.9], [10, 0, 0.9]), 3, 1);
    expect(heavy[2]).toBeGreaterThan(light[2] * 2);
  });
});

describe('boîte englobante et gomme', () => {
  const stroke = createStroke('s', points([10, 10], [50, 10], [50, 40]), '#000000', 2, 0, 'pen');

  it('englobe les points et l’épaisseur', () => {
    expect(stroke.bbox.minX).toBeLessThan(10);
    expect(stroke.bbox.maxY).toBeGreaterThan(40);
    expect(computeBBox(stroke.points, 3, 2)).toEqual(stroke.bbox);
  });

  it('touche le trait le long de son tracé, pas dans le creux de l’angle', () => {
    expect(hitTestStroke(stroke, 30, 11, 2)).toBe(true);
    expect(hitTestStroke(stroke, 51, 25, 2)).toBe(true);
    expect(hitTestStroke(stroke, 25, 30, 2)).toBe(false);
    expect(hitTestStroke(stroke, 200, 200, 2)).toBe(false);
  });

  it('touche un trait réduit à un point', () => {
    const dot = createStroke('d', points([5, 5]), '#000000', 2, 0, 'pen');
    expect(hitTestStroke(dot, 6, 5, 1)).toBe(true);
    expect(hitTestStroke(dot, 15, 5, 1)).toBe(false);
  });

  it('tient compte de la transformation de l’objet', () => {
    const moved = { ...stroke, transform: [1, 0, 0, 1, 100, 0] as [number, number, number, number, number, number],
      bbox: { minX: stroke.bbox.minX + 100, minY: stroke.bbox.minY, maxX: stroke.bbox.maxX + 100, maxY: stroke.bbox.maxY } };
    expect(hitTestStroke(moved, 130, 11, 2)).toBe(true);
    expect(hitTestStroke(moved, 30, 11, 2)).toBe(false);
  });
});

describe('générateur de charge', () => {
  it('est déterministe et reste dans la page', () => {
    const page = createPage('p', 0);
    const a = generateStrokes(page, 500, 42, (i) => `a${i}`, 0);
    const b = generateStrokes(page, 500, 42, (i) => `a${i}`, 0);
    expect(a.length).toBe(500);
    expect(Array.from(a[321].points)).toEqual(Array.from(b[321].points));
    for (const s of a) {
      expect(s.bbox.minX).toBeGreaterThan(0);
      expect(s.bbox.maxX).toBeLessThan(page.width);
      expect(s.bbox.minY).toBeGreaterThan(0);
      expect(s.bbox.maxY).toBeLessThan(page.height);
    }
  });
});
