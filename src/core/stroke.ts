import { IDENTITY, distSqPointSegment, invert, isIdentity, applyToPoint } from './geometry';
import { POINT_STRIDE, type BBox, type InputKind, type Stroke } from './types';

const S = POINT_STRIDE;

/** Largeur maximale relative atteinte à pression 1. */
export const MAX_WIDTH_FACTOR = 1.65;
/** Pas de discrétisation des courbes, en points typographiques. */
const CURVE_STEP = 0.5;
const MAX_STEPS = 12;

/** Largeur du trait pour une pression donnée ; vaut `base` à pression 0,5. */
export function pressureToWidth(base: number, pressure: number): number {
  const p = pressure < 0 ? 0 : pressure > 1 ? 1 : pressure;
  return base * (0.35 + 1.3 * p);
}

/** Tampon de points extensible pour le trait en cours. */
export class PointBuffer {
  data = new Float32Array(256 * S);
  count = 0;

  clear(): void {
    this.count = 0;
  }

  push(x: number, y: number, t: number, p: number, tiltX: number, tiltY: number): void {
    if ((this.count + 1) * S > this.data.length) {
      const next = new Float32Array(this.data.length * 2);
      next.set(this.data);
      this.data = next;
    }
    const o = this.count * S;
    this.data[o] = x;
    this.data[o + 1] = y;
    this.data[o + 2] = t;
    this.data[o + 3] = p;
    this.data[o + 4] = tiltX;
    this.data[o + 5] = tiltY;
    this.count++;
  }

  toArray(): Float32Array {
    return this.data.slice(0, this.count * S);
  }
}

/**
 * Convertit les points bruts en polyligne lissée [x, y, largeur, …].
 * Lissage par courbes quadratiques entre milieux de segments : la courbe reste
 * dans l'enveloppe des points saisis, et les extrémités sont conservées exactement.
 * La pression est filtrée (passe-bas d'ordre 1) pour éviter les à-coups de largeur.
 * Fonction pure et déterministe : même entrée, même sortie, en direct comme après rechargement.
 */
export function buildSamples(pts: Float32Array, count: number, base: number): Float32Array {
  if (count <= 0) return new Float32Array(0);
  const w = new Float32Array(count);
  let f = pts[3];
  for (let i = 0; i < count; i++) {
    if (i > 0) f += 0.5 * (pts[i * S + 3] - f);
    w[i] = pressureToWidth(base, f);
  }
  if (count === 1) return new Float32Array([pts[0], pts[1], w[0]]);

  const out: number[] = [pts[0], pts[1], w[0]];
  let mx = (pts[0] + pts[S]) / 2;
  let my = (pts[1] + pts[S + 1]) / 2;
  let mw = (w[0] + w[1]) / 2;
  out.push(mx, my, mw);
  for (let i = 1; i < count - 1; i++) {
    const cx = pts[i * S];
    const cy = pts[i * S + 1];
    const cw = w[i];
    const nx = (cx + pts[(i + 1) * S]) / 2;
    const ny = (cy + pts[(i + 1) * S + 1]) / 2;
    const nw = (cw + w[i + 1]) / 2;
    const len = Math.hypot(cx - mx, cy - my) + Math.hypot(nx - cx, ny - cy);
    const steps = Math.min(MAX_STEPS, Math.max(1, Math.ceil(len / CURVE_STEP)));
    for (let s = 1; s <= steps; s++) {
      const t = s / steps;
      const u = 1 - t;
      out.push(
        u * u * mx + 2 * u * t * cx + t * t * nx,
        u * u * my + 2 * u * t * cy + t * t * ny,
        u * u * mw + 2 * u * t * cw + t * t * nw,
      );
    }
    mx = nx;
    my = ny;
    mw = nw;
  }
  const l = (count - 1) * S;
  out.push(pts[l], pts[l + 1], w[count - 1]);
  return new Float32Array(out);
}

/** Boîte englobante des points, élargie de la demi-épaisseur maximale possible. */
export function computeBBox(pts: Float32Array, count: number, base: number): BBox {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (let i = 0; i < count; i++) {
    const x = pts[i * S];
    const y = pts[i * S + 1];
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  const pad = (base * MAX_WIDTH_FACTOR) / 2;
  return { minX: minX - pad, minY: minY - pad, maxX: maxX + pad, maxY: maxY + pad };
}

export function createStroke(
  id: string, pts: Float32Array, color: string, width: number, createdAt: number, input: InputKind,
): Stroke {
  return {
    id,
    type: 'stroke',
    tool: 'pen',
    color,
    width,
    opacity: 1,
    points: pts,
    bbox: computeBBox(pts, pts.length / S, width),
    transform: IDENTITY,
    createdAt,
    input,
  };
}

/** Vrai si le disque (x, y, radius), en repère page, touche le trait. */
export function hitTestStroke(stroke: Stroke, x: number, y: number, radius: number): boolean {
  const b = stroke.bbox;
  if (x < b.minX - radius || x > b.maxX + radius || y < b.minY - radius || y > b.maxY + radius) {
    return false;
  }
  if (!isIdentity(stroke.transform)) {
    const inv = invert(stroke.transform);
    if (!inv) return false;
    [x, y] = applyToPoint(inv, x, y);
  }
  const pts = stroke.points;
  const n = pts.length / S;
  const reach = radius + (stroke.width * MAX_WIDTH_FACTOR) / 2;
  const reach2 = reach * reach;
  if (n === 1) return distSqPointSegment(x, y, pts[0], pts[1], pts[0], pts[1]) <= reach2;
  for (let i = 0; i < n - 1; i++) {
    const o = i * S;
    if (distSqPointSegment(x, y, pts[o], pts[o + 1], pts[o + S], pts[o + S + 1]) <= reach2) {
      return true;
    }
  }
  return false;
}
