import { describe, expect, it } from 'vitest';
import { generateStrokes } from '../src/core/benchmark';
import { FormatError, pageFromJSON, pageToJSON } from '../src/core/serialize';
import { SCHEMA_VERSION, createPage, defaultBackground } from '../src/core/types';

function sample() {
  const page = createPage('page-1', 1700000000000);
  page.background = defaultBackground('grid');
  page.objects = generateStrokes(page, 40, 7, (i) => `s${i}`, 1700000000000);
  return page;
}

const clone = (v: unknown) => JSON.parse(JSON.stringify(v));

describe('sérialisation', () => {
  it('fait l’aller-retour sans perte au-delà de l’arrondi au millième', () => {
    const page = sample();
    const back = pageFromJSON(clone(pageToJSON(page)));
    expect(back.id).toBe(page.id);
    expect(back.background).toEqual(page.background);
    expect(back.objects.length).toBe(40);
    back.objects.forEach((s, i) => {
      const o = page.objects[i];
      expect(s.id).toBe(o.id);
      expect(s.color).toBe(o.color);
      expect(s.points.length).toBe(o.points.length);
      for (let k = 0; k < s.points.length; k++) expect(Math.abs(s.points[k] - o.points[k])).toBeLessThan(1e-3);
      expect(s.bbox.minX).toBeCloseTo(o.bbox.minX, 2);
    });
  });

  it('est stable : un second aller-retour donne un JSON identique', () => {
    const once = clone(pageToJSON(pageFromJSON(clone(pageToJSON(sample())))));
    const twice = clone(pageToJSON(pageFromJSON(once)));
    expect(twice).toEqual(once);
  });

  it('rejette une version de schéma plus récente', () => {
    const json = clone(pageToJSON(sample()));
    json.schemaVersion = SCHEMA_VERSION + 1;
    expect(() => pageFromJSON(json)).toThrow(FormatError);
  });

  it.each([
    ['entrée non objet', (_j: any) => 'texte'],
    ['objets absents', (j: any) => { delete j.objects; return j; }],
    ['points non multiples du pas', (j: any) => { j.objects[0].points.pop(); return j; }],
    ['point non numérique', (j: any) => { j.objects[0].points[3] = 'x'; return j; }],
    ['point infini', (j: any) => { j.objects[0].points[3] = null; return j; }],
    ['couleur invalide', (j: any) => { j.objects[0].color = 'red;'; return j; }],
    ['identifiant en double', (j: any) => { j.objects[1].id = j.objects[0].id; return j; }],
    ['type inconnu', (j: any) => { j.objects[0].type = 'script'; return j; }],
    ['transformation tronquée', (j: any) => { j.objects[0].transform = [1, 0]; return j; }],
    ['fond inconnu', (j: any) => { j.background.kind = 'x'; return j; }],
    ['dimensions absurdes', (j: any) => { j.width = 1e9; return j; }],
  ])('rejette : %s', (_name, mutate) => {
    expect(() => pageFromJSON(mutate(clone(pageToJSON(sample()))))).toThrow(FormatError);
  });
});
