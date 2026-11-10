/** Vue : écran (px CSS) = page (pt) × scale + (tx, ty). */
export interface View {
  scale: number;
  tx: number;
  ty: number;
}

export const MIN_SCALE = 0.25;
export const MAX_SCALE = 8;

export function screenToPage(v: View, sx: number, sy: number): [number, number] {
  return [(sx - v.tx) / v.scale, (sy - v.ty) / v.scale];
}

export function pageToScreen(v: View, px: number, py: number): [number, number] {
  return [px * v.scale + v.tx, py * v.scale + v.ty];
}

/** Zoom d'un facteur donné en gardant fixe le point de la page situé sous (sx, sy). */
export function zoomAt(v: View, sx: number, sy: number, factor: number): View {
  const scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, v.scale * factor));
  const k = scale / v.scale;
  return { scale, tx: sx - (sx - v.tx) * k, ty: sy - (sy - v.ty) * k };
}

export function panBy(v: View, dx: number, dy: number): View {
  return { scale: v.scale, tx: v.tx + dx, ty: v.ty + dy };
}

/** Pincement incrémental : centroïde et écartement précédents puis courants. */
export function pinch(
  v: View, c0x: number, c0y: number, d0: number, c1x: number, c1y: number, d1: number,
): View {
  const factor = d0 > 0 && d1 > 0 ? d1 / d0 : 1;
  return panBy(zoomAt(v, c0x, c0y, factor), c1x - c0x, c1y - c0y);
}

/** Vue qui ajuste la largeur de la page à la fenêtre, centrée horizontalement. */
export function fitWidth(pageW: number, viewW: number, margin: number, top: number): View {
  const scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, (viewW - 2 * margin) / pageW));
  return { scale, tx: (viewW - pageW * scale) / 2, ty: top };
}

export function sameView(a: View, b: View): boolean {
  return a.scale === b.scale && a.tx === b.tx && a.ty === b.ty;
}
