import { bboxIntersects, isIdentity } from '../core/geometry';
import { buildSamples } from '../core/stroke';
import type { BBox, PageDoc, Stroke } from '../core/types';
import { POINT_STRIDE } from '../core/types';
import type { View } from '../core/viewport';

const quant = (w: number) => Math.max(0.125, Math.round(w * 8) / 8);

/** Dessine une polyligne à largeur variable ; les segments de même largeur sont regroupés. */
function drawSamples(ctx: CanvasRenderingContext2D, s: Float32Array, color: string, opacity: number): void {
  const n = s.length / 3;
  if (n === 0) return;
  ctx.globalAlpha = opacity;
  ctx.fillStyle = color;
  ctx.strokeStyle = color;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  // Un point de départ rond garantit qu'un simple appui laisse une trace.
  ctx.beginPath();
  ctx.arc(s[0], s[1], s[2] / 2, 0, Math.PI * 2);
  ctx.fill();
  let i = 0;
  while (i < n - 1) {
    const q = quant((s[i * 3 + 2] + s[i * 3 + 5]) / 2);
    ctx.beginPath();
    ctx.moveTo(s[i * 3], s[i * 3 + 1]);
    let j = i;
    while (j < n - 1 && quant((s[j * 3 + 2] + s[j * 3 + 5]) / 2) === q) {
      ctx.lineTo(s[j * 3 + 3], s[j * 3 + 4]);
      j++;
    }
    ctx.lineWidth = q;
    ctx.stroke();
    i = j;
  }
  ctx.globalAlpha = 1;
}

function drawStroke(ctx: CanvasRenderingContext2D, stroke: Stroke): void {
  const samples = buildSamples(stroke.points, stroke.points.length / POINT_STRIDE, stroke.width);
  if (isIdentity(stroke.transform)) {
    drawSamples(ctx, samples, stroke.color, stroke.opacity);
  } else {
    ctx.save();
    ctx.transform(...stroke.transform);
    drawSamples(ctx, samples, stroke.color, stroke.opacity);
    ctx.restore();
  }
}

function drawBackground(ctx: CanvasRenderingContext2D, page: PageDoc, region: BBox, scale: number): void {
  const bg = page.background;
  ctx.fillStyle = bg.color;
  ctx.fillRect(0, 0, page.width, page.height);
  const x0 = Math.max(0, region.minX);
  const x1 = Math.min(page.width, region.maxX);
  const y0 = Math.max(0, region.minY);
  const y1 = Math.min(page.height, region.maxY);
  if (bg.kind === 'blank' || x1 <= x0 || y1 <= y0) return;
  const sp = bg.spacing;
  const firstRow = Math.max(1, Math.floor(y0 / sp));
  const firstCol = Math.max(1, Math.floor(x0 / sp));
  ctx.strokeStyle = bg.lineColor;
  ctx.fillStyle = bg.lineColor;
  ctx.lineWidth = Math.max(0.5, 1 / scale);
  if (bg.kind === 'dots') {
    const r = Math.max(0.6, 1.2 / scale);
    for (let row = firstRow; row * sp < Math.min(y1 + sp, page.height); row++) {
      for (let col = firstCol; col * sp < Math.min(x1 + sp, page.width); col++) {
        ctx.fillRect(col * sp - r / 2, row * sp - r / 2, r, r);
      }
    }
    return;
  }
  ctx.beginPath();
  for (let row = firstRow; row * sp < Math.min(y1 + sp, page.height); row++) {
    ctx.moveTo(0, row * sp);
    ctx.lineTo(page.width, row * sp);
  }
  if (bg.kind === 'grid') {
    for (let col = firstCol; col * sp < Math.min(x1 + sp, page.width); col++) {
      ctx.moveTo(col * sp, 0);
      ctx.lineTo(col * sp, page.height);
    }
  }
  ctx.stroke();
}

/**
 * Deux calques : `committed` contient le fond et les traits validés, `live` le trait en cours.
 * Écrire ne redessine que le calque `live` ; valider un trait l'ajoute au calque `committed`
 * sans rien effacer ; annuler ou gommer ne redessine que la zone concernée.
 */
export class InkRenderer {
  readonly committed: HTMLCanvasElement;
  readonly live: HTMLCanvasElement;
  private cctx: CanvasRenderingContext2D;
  private lctx: CanvasRenderingContext2D;
  private dpr = 1;
  private cssW = 0;
  private cssH = 0;
  private liveDirty: [number, number, number, number] | null = null;
  /** Vue utilisée lors du dernier rendu complet. */
  rendered: View = { scale: 1, tx: 0, ty: 0 };
  /** Durée du dernier rendu complet, en ms. */
  lastFullMs = 0;

  constructor(container: HTMLElement) {
    this.committed = document.createElement('canvas');
    this.live = document.createElement('canvas');
    for (const c of [this.committed, this.live]) {
      c.className = 'ink-layer';
      c.setAttribute('aria-hidden', 'true');
      container.appendChild(c);
    }
    this.cctx = this.committed.getContext('2d', { desynchronized: true })!;
    this.lctx = this.live.getContext('2d', { desynchronized: true })!;
  }

  /** Ajuste la taille des calques. Retourne vrai si un rendu complet est nécessaire. */
  resize(cssW: number, cssH: number, dpr: number): boolean {
    if (cssW === this.cssW && cssH === this.cssH && dpr === this.dpr) return false;
    this.cssW = cssW;
    this.cssH = cssH;
    this.dpr = dpr;
    for (const c of [this.committed, this.live]) {
      c.width = Math.max(1, Math.round(cssW * dpr));
      c.height = Math.max(1, Math.round(cssH * dpr));
      c.style.width = `${cssW}px`;
      c.style.height = `${cssH}px`;
    }
    this.liveDirty = null;
    return true;
  }

  get pixelRatio(): number {
    return this.dpr;
  }

  private applyView(ctx: CanvasRenderingContext2D, v: View): void {
    ctx.setTransform(this.dpr * v.scale, 0, 0, this.dpr * v.scale, this.dpr * v.tx, this.dpr * v.ty);
  }

  /** Rectangle en pixels physiques couvrant une zone de page, marge comprise. */
  private deviceRect(b: BBox, v: View): [number, number, number, number] {
    const k = this.dpr * v.scale;
    const x0 = Math.max(0, Math.floor(b.minX * k + this.dpr * v.tx) - 2);
    const y0 = Math.max(0, Math.floor(b.minY * k + this.dpr * v.ty) - 2);
    const x1 = Math.min(this.committed.width, Math.ceil(b.maxX * k + this.dpr * v.tx) + 2);
    const y1 = Math.min(this.committed.height, Math.ceil(b.maxY * k + this.dpr * v.ty) + 2);
    return [x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0)];
  }

  private visibleRegion(v: View): BBox {
    return {
      minX: -v.tx / v.scale,
      minY: -v.ty / v.scale,
      maxX: (this.cssW - v.tx) / v.scale,
      maxY: (this.cssH - v.ty) / v.scale,
    };
  }

  private paint(page: PageDoc, v: View, region: BBox): void {
    const ctx = this.cctx;
    this.applyView(ctx, v);
    drawBackground(ctx, page, region, v.scale);
    // Les traits sont limités à la page.
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, page.width, page.height);
    ctx.clip();
    for (const o of page.objects) {
      if (bboxIntersects(o.bbox, region)) drawStroke(ctx, o);
    }
    ctx.restore();
  }

  /** Rendu complet de la zone visible. */
  renderAll(page: PageDoc, v: View): void {
    const t0 = performance.now();
    const ctx = this.cctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.committed.width, this.committed.height);
    this.paint(page, v, this.visibleRegion(v));
    this.rendered = { ...v };
    this.committed.style.transform = '';
    this.live.style.transform = '';
    this.lastFullMs = performance.now() - t0;
  }

  /** Redessine uniquement une zone de la page (annulation, gomme). */
  renderRegion(page: PageDoc, region: BBox): void {
    const v = this.rendered;
    const [x, y, w, h] = this.deviceRect(region, v);
    if (w === 0 || h === 0) return;
    const ctx = this.cctx;
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.beginPath();
    ctx.rect(x, y, w, h);
    ctx.clip();
    ctx.clearRect(x, y, w, h);
    const k = this.dpr * v.scale;
    this.paint(page, v, {
      minX: (x - this.dpr * v.tx) / k,
      minY: (y - this.dpr * v.ty) / k,
      maxX: (x + w - this.dpr * v.tx) / k,
      maxY: (y + h - this.dpr * v.ty) / k,
    });
    ctx.restore();
  }

  /** Ajoute un trait validé au-dessus du contenu existant, sans rien redessiner d'autre. */
  appendStroke(page: PageDoc, stroke: Stroke): void {
    const ctx = this.cctx;
    this.applyView(ctx, this.rendered);
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, page.width, page.height);
    ctx.clip();
    drawStroke(ctx, stroke);
    ctx.restore();
  }

  /** Redessine le trait en cours sur le calque `live` (seule sa zone est effacée). */
  renderLive(page: PageDoc, pts: Float32Array, count: number, color: string, width: number, bbox: BBox): void {
    this.clearLive();
    const ctx = this.lctx;
    const rect = this.deviceRect(bbox, this.rendered);
    this.applyView(ctx, this.rendered);
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, page.width, page.height);
    ctx.clip();
    drawSamples(ctx, buildSamples(pts, count, width), color, 1);
    ctx.restore();
    this.liveDirty = rect;
  }

  clearLive(): void {
    if (!this.liveDirty) return;
    const [x, y, w, h] = this.liveDirty;
    this.lctx.setTransform(1, 0, 0, 1, 0, 0);
    this.lctx.clearRect(x, y, w, h);
    this.liveDirty = null;
  }

  /**
   * Pendant un geste de zoom ou de déplacement sur une page lourde : transforme
   * l'image déjà rendue au lieu de tout redessiner à chaque image.
   */
  previewView(v: View): void {
    const r = this.rendered;
    const k = v.scale / r.scale;
    const t = `translate(${v.tx - r.tx * k}px, ${v.ty - r.ty * k}px) scale(${k})`;
    this.committed.style.transform = t;
    this.live.style.transform = t;
  }
}
