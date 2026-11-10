import { createStroke, PointBuffer } from './stroke';
import type { PageDoc, Stroke } from './types';

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Génère des traits ressemblant à de l'écriture, de façon déterministe, pour les tests de charge. */
export function generateStrokes(
  page: PageDoc, count: number, seed: number, makeId: (i: number) => string, now: number,
): Stroke[] {
  const rnd = mulberry32(seed);
  const margin = 28;
  const lineH = Math.max(6, (page.height - 2 * margin) / Math.ceil(count / 60));
  const strokes: Stroke[] = [];
  const buf = new PointBuffer();
  let x = margin;
  let y = margin + lineH;
  for (let i = 0; i < count; i++) {
    const w = 4 + rnd() * 6;
    if (x + w > page.width - margin) {
      x = margin;
      y += lineH;
      if (y > page.height - margin) y = margin + lineH;
    }
    buf.clear();
    const n = 24 + Math.floor(rnd() * 24);
    const phase = rnd() * Math.PI * 2;
    const loops = 1 + rnd() * 2;
    const h = lineH * (0.35 + rnd() * 0.4);
    for (let k = 0; k < n; k++) {
      const u = k / (n - 1);
      const a = phase + u * loops * Math.PI * 2;
      buf.push(
        x + u * w + Math.cos(a) * w * 0.18,
        y - h / 2 + Math.sin(a) * h / 2,
        k * 8,
        0.3 + 0.4 * Math.abs(Math.sin(a / 2)),
        0,
        0,
      );
    }
    strokes.push(createStroke(makeId(i), buf.toArray(), '#1d2a44', 0.9, now, 'mouse'));
    x += w + 2 + rnd() * 3;
  }
  return strokes;
}
