import { describe, expect, it } from 'vitest';
import {
  IDENTITY, applyToPoint, bboxIntersects, bboxUnion, distSqPointSegment, invert, multiply, type Matrix,
} from '../src/core/geometry';
import { fitWidth, MAX_SCALE, MIN_SCALE, pageToScreen, panBy, pinch, screenToPage, zoomAt } from '../src/core/viewport';

describe('matrices', () => {
  const m: Matrix = [2, 0.5, -1, 3, 10, -4];

  it('compose avec son inverse pour donner l’identité', () => {
    const r = multiply(m, invert(m)!);
    r.forEach((v, i) => expect(v).toBeCloseTo(IDENTITY[i], 10));
  });

  it('applique m2 avant m1 dans multiply(m1, m2)', () => {
    const translate: Matrix = [1, 0, 0, 1, 5, 0];
    const scale: Matrix = [2, 0, 0, 2, 0, 0];
    expect(applyToPoint(multiply(scale, translate), 1, 1)).toEqual([12, 2]);
    expect(applyToPoint(multiply(translate, scale), 1, 1)).toEqual([7, 2]);
  });

  it('refuse d’inverser une matrice singulière', () => {
    expect(invert([1, 2, 2, 4, 0, 0])).toBeNull();
  });
});

describe('boîtes et distances', () => {
  it('détecte les intersections, bords compris', () => {
    const a = { minX: 0, minY: 0, maxX: 10, maxY: 10 };
    expect(bboxIntersects(a, { minX: 10, minY: 10, maxX: 20, maxY: 20 })).toBe(true);
    expect(bboxIntersects(a, { minX: 10.1, minY: 0, maxX: 20, maxY: 10 })).toBe(false);
  });

  it('calcule l’union, null étant neutre', () => {
    const a = { minX: 0, minY: 0, maxX: 1, maxY: 1 };
    expect(bboxUnion(null, a)).toBe(a);
    expect(bboxUnion(a, { minX: -2, minY: 0.5, maxX: 0.5, maxY: 3 })).toEqual({ minX: -2, minY: 0, maxX: 1, maxY: 3 });
  });

  it('mesure la distance à un segment, extrémités et segment nul compris', () => {
    expect(distSqPointSegment(5, 3, 0, 0, 10, 0)).toBeCloseTo(9);
    expect(distSqPointSegment(-3, 4, 0, 0, 10, 0)).toBeCloseTo(25);
    expect(distSqPointSegment(3, 4, 0, 0, 0, 0)).toBeCloseTo(25);
  });
});

describe('vue', () => {
  const v = { scale: 2, tx: 30, ty: -10 };

  it('convertit écran ↔ page de façon réversible', () => {
    const [px, py] = screenToPage(v, 130, 90);
    expect([px, py]).toEqual([50, 50]);
    expect(pageToScreen(v, px, py)).toEqual([130, 90]);
  });

  it('garde fixe le point sous le curseur pendant le zoom', () => {
    const before = screenToPage(v, 200, 120);
    const z = zoomAt(v, 200, 120, 1.7);
    const after = screenToPage(z, 200, 120);
    expect(after[0]).toBeCloseTo(before[0], 9);
    expect(after[1]).toBeCloseTo(before[1], 9);
    expect(z.scale).toBeCloseTo(3.4);
  });

  it('borne le zoom', () => {
    expect(zoomAt(v, 0, 0, 1000).scale).toBe(MAX_SCALE);
    expect(zoomAt(v, 0, 0, 0.0001).scale).toBe(MIN_SCALE);
  });

  it('suit les doigts pendant un pincement', () => {
    // Le point de page sous le centroïde initial doit se retrouver sous le centroïde final.
    const anchor = screenToPage(v, 100, 100);
    const p = pinch(v, 100, 100, 50, 140, 80, 100);
    expect(p.scale).toBeCloseTo(4);
    const s = pageToScreen(p, anchor[0], anchor[1]);
    expect(s[0]).toBeCloseTo(140);
    expect(s[1]).toBeCloseTo(80);
  });

  it('déplace sans changer l’échelle', () => {
    expect(panBy(v, 5, -5)).toEqual({ scale: 2, tx: 35, ty: -15 });
  });

  it('ajuste la page à la largeur disponible', () => {
    const f = fitWidth(500, 1040, 20, 70);
    expect(f.scale).toBe(2);
    expect(f.tx).toBe(20);
    expect(f.ty).toBe(70);
  });
});
