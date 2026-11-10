import { IDENTITY, type Matrix } from './geometry';
import { computeBBox } from './stroke';
import {
  POINT_STRIDE, SCHEMA_VERSION,
  type Background, type BackgroundKind, type InputKind, type PageDoc, type Stroke,
} from './types';

export class FormatError extends Error {}

const MAX_OBJECTS = 200_000;
const MAX_POINTS_PER_STROKE = 200_000;
const BACKGROUNDS: BackgroundKind[] = ['blank', 'ruled', 'grid', 'dots'];
const INPUTS: InputKind[] = ['pen', 'mouse', 'touch'];

const round3 = (v: number) => Math.round(v * 1000) / 1000;

/** Représentation JSON d'une page (format d'échange). Les données dérivées (bbox) n'y figurent pas. */
export function pageToJSON(page: PageDoc): unknown {
  return {
    schemaVersion: SCHEMA_VERSION,
    id: page.id,
    width: page.width,
    height: page.height,
    background: { ...page.background },
    updatedAt: page.updatedAt,
    objects: page.objects.map((s) => ({
      id: s.id,
      type: s.type,
      tool: s.tool,
      color: s.color,
      width: s.width,
      opacity: s.opacity,
      transform: [...s.transform],
      createdAt: s.createdAt,
      input: s.input,
      stride: POINT_STRIDE,
      points: Array.from(s.points, round3),
    })),
  };
}

function fail(msg: string): never {
  throw new FormatError(msg);
}

function num(v: unknown, name: string, min = -Infinity, max = Infinity): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max) fail(`Champ invalide : ${name}`);
  return v as number;
}

function str(v: unknown, name: string, maxLen = 200): string {
  if (typeof v !== 'string' || v.length === 0 || v.length > maxLen) fail(`Champ invalide : ${name}`);
  return v as string;
}

function color(v: unknown, name: string): string {
  const s = str(v, name, 9);
  if (!/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(s)) fail(`Couleur invalide : ${name}`);
  return s;
}

function obj(v: unknown, name: string): Record<string, unknown> {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) fail(`Objet attendu : ${name}`);
  return v as Record<string, unknown>;
}

/** Migrations de schéma : chaque entrée transforme la version n en n + 1. */
const MIGRATIONS: Record<number, (raw: Record<string, unknown>) => Record<string, unknown>> = {};

/** Valide et reconstruit une page depuis du JSON non fiable. Lève FormatError si invalide. */
export function pageFromJSON(input: unknown): PageDoc {
  let raw = obj(input, 'page');
  let version = num(raw.schemaVersion, 'schemaVersion', 1);
  if (!Number.isInteger(version)) fail('Champ invalide : schemaVersion');
  if (version > SCHEMA_VERSION) fail(`Version de schéma ${version} plus récente que cette application`);
  while (version < SCHEMA_VERSION) {
    const m = MIGRATIONS[version];
    if (!m) fail(`Migration absente depuis la version ${version}`);
    raw = m(raw);
    version++;
  }

  const bg = obj(raw.background, 'background');
  const kind = bg.kind as BackgroundKind;
  if (!BACKGROUNDS.includes(kind)) fail('Champ invalide : background.kind');
  const background: Background = {
    kind,
    color: color(bg.color, 'background.color'),
    lineColor: color(bg.lineColor, 'background.lineColor'),
    spacing: num(bg.spacing, 'background.spacing', 2, 500),
  };

  if (!Array.isArray(raw.objects) || raw.objects.length > MAX_OBJECTS) fail('Champ invalide : objects');
  const seen = new Set<string>();
  const objects: Stroke[] = (raw.objects as unknown[]).map((item, i) => {
    const o = obj(item, `objects[${i}]`);
    if (o.type !== 'stroke' || o.tool !== 'pen') fail(`Type d'objet non pris en charge : objects[${i}]`);
    const id = str(o.id, 'id');
    if (seen.has(id)) fail(`Identifiant en double : ${id}`);
    seen.add(id);
    if (o.stride !== POINT_STRIDE) fail('Champ invalide : stride');
    const p = o.points;
    if (!Array.isArray(p) || p.length === 0 || p.length % POINT_STRIDE !== 0
      || p.length / POINT_STRIDE > MAX_POINTS_PER_STROKE) fail('Champ invalide : points');
    const points = new Float32Array(p.length);
    for (let k = 0; k < p.length; k++) points[k] = num(p[k], 'points');
    const tr = o.transform;
    if (!Array.isArray(tr) || tr.length !== 6) fail('Champ invalide : transform');
    const transform = (tr as unknown[]).map((v) => num(v, 'transform')) as Matrix;
    const input = o.input as InputKind;
    if (!INPUTS.includes(input)) fail('Champ invalide : input');
    const width = num(o.width, 'width', 0.05, 200);
    return {
      id,
      type: 'stroke',
      tool: 'pen',
      color: color(o.color, 'color'),
      width,
      opacity: num(o.opacity, 'opacity', 0, 1),
      points,
      bbox: computeBBox(points, points.length / POINT_STRIDE, width),
      transform: transform.every((v, k) => v === IDENTITY[k]) ? IDENTITY : transform,
      createdAt: num(o.createdAt, 'createdAt', 0),
      input,
    };
  });

  return {
    id: str(raw.id, 'id'),
    schemaVersion: SCHEMA_VERSION,
    width: num(raw.width, 'width', 10, 20000),
    height: num(raw.height, 'height', 10, 20000),
    background,
    objects,
    updatedAt: num(raw.updatedAt, 'updatedAt', 0),
  };
}
