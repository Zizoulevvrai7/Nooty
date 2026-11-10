import type { Matrix } from './geometry';

/** Version du schéma documentaire. Toute évolution incompatible l'incrémente et ajoute une migration. */
export const SCHEMA_VERSION = 1;

/**
 * Disposition d'un point dans `Stroke.points` (tableau plat) :
 * x, y (points typographiques, repère page), t (ms depuis le début du trait),
 * pression (0..1), tiltX, tiltY (degrés, 0 si le matériel ne les fournit pas).
 */
export const POINT_STRIDE = 6;

export type ToolKind = 'pen';
export type InputKind = 'pen' | 'mouse' | 'touch';

export interface BBox {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export interface Stroke {
  id: string;
  type: 'stroke';
  tool: ToolKind;
  color: string;
  /** Épaisseur nominale en points typographiques (à pression 0,5). */
  width: number;
  opacity: number;
  points: Float32Array;
  /** Boîte englobante en repère page, épaisseur comprise. */
  bbox: BBox;
  transform: Matrix;
  /** Horodatage absolu (ms epoch) du premier point. */
  createdAt: number;
  input: InputKind;
}

export type PageObject = Stroke;

export type BackgroundKind = 'blank' | 'ruled' | 'grid' | 'dots';

export interface Background {
  kind: BackgroundKind;
  color: string;
  lineColor: string;
  /** Espacement des lignes en points typographiques. */
  spacing: number;
}

export interface PageDoc {
  id: string;
  schemaVersion: number;
  /** Dimensions en points typographiques (1/72 pouce). */
  width: number;
  height: number;
  background: Background;
  /** Objets dans l'ordre d'affichage (le dernier est au-dessus). */
  objects: PageObject[];
  updatedAt: number;
}

export const MM = 72 / 25.4;

export function defaultBackground(kind: BackgroundKind = 'ruled'): Background {
  return {
    kind,
    color: '#fffdf8',
    lineColor: '#c9d3e0',
    spacing: kind === 'ruled' ? 7 * MM : 5 * MM,
  };
}

export function createPage(id: string, now: number): PageDoc {
  return {
    id,
    schemaVersion: SCHEMA_VERSION,
    width: 595.28, // A4 portrait
    height: 841.89,
    background: defaultBackground(),
    objects: [],
    updatedAt: now,
  };
}

export function newId(): string {
  const c = globalThis.crypto;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  const b = new Uint8Array(16);
  c.getRandomValues(b);
  return Array.from(b, (v) => v.toString(16).padStart(2, '0')).join('');
}
