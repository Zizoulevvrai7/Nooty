import { describe, expect, it } from 'vitest';
import { AddObjects, Composite, History, RemoveObjects } from '../src/core/commands';
import { createStroke } from '../src/core/stroke';
import { createPage, type PageDoc } from '../src/core/types';

const stroke = (id: string, x = 0) =>
  createStroke(id, new Float32Array([x, 0, 0, 0.5, 0, 0, x + 10, 10, 8, 0.5, 0, 0]), '#000000', 1, 0, 'pen');
const ids = (p: PageDoc) => p.objects.map((o) => o.id).join('');

describe('historique', () => {
  it('annule et rétablit un ajout', () => {
    const page = createPage('p', 0);
    const h = new History();
    const area = h.execute(page, new AddObjects([stroke('a')]));
    expect(area).toEqual(page.objects[0].bbox);
    expect(h.canUndo).toBe(true);
    expect(h.undo(page)).toEqual(area);
    expect(ids(page)).toBe('');
    h.redo(page);
    expect(ids(page)).toBe('a');
  });

  it('restaure l’ordre d’affichage après une suppression', () => {
    const page = createPage('p', 0);
    const h = new History();
    h.execute(page, new AddObjects(['a', 'b', 'c', 'd', 'e'].map((id) => stroke(id))));
    h.execute(page, new RemoveObjects(['d', 'b']));
    expect(ids(page)).toBe('ace');
    h.undo(page);
    expect(ids(page)).toBe('abcde');
    h.redo(page);
    expect(ids(page)).toBe('ace');
  });

  it('traite un geste de gomme comme une seule transaction', () => {
    const page = createPage('p', 0);
    const h = new History();
    h.execute(page, new AddObjects(['a', 'b', 'c', 'd'].map((id) => stroke(id))));
    // La gomme applique chaque suppression au fil du geste, puis enregistre le tout.
    const steps = [new RemoveObjects(['b']), new RemoveObjects(['d']), new RemoveObjects(['a'])];
    steps.forEach((s) => s.apply(page));
    h.record(new Composite(steps));
    expect(ids(page)).toBe('c');
    h.undo(page);
    expect(ids(page)).toBe('abcd');
    h.redo(page);
    expect(ids(page)).toBe('c');
  });

  it('invalide la pile de rétablissement à la première nouvelle action', () => {
    const page = createPage('p', 0);
    const h = new History();
    h.execute(page, new AddObjects([stroke('a')]));
    h.undo(page);
    expect(h.canRedo).toBe(true);
    h.execute(page, new AddObjects([stroke('b')]));
    expect(h.canRedo).toBe(false);
    expect(h.redo(page)).toBeNull();
    expect(ids(page)).toBe('b');
  });

  it('borne la mémoire en oubliant les actions les plus anciennes', () => {
    const page = createPage('p', 0);
    const h = new History(3);
    for (const id of ['a', 'b', 'c', 'd', 'e']) h.execute(page, new AddObjects([stroke(id)]));
    let undone = 0;
    while (h.canUndo) {
      h.undo(page);
      undone++;
    }
    expect(undone).toBe(3);
    expect(ids(page)).toBe('ab');
  });

  it('revient à l’état exact après 100 annulations puis 100 rétablissements', () => {
    const page = createPage('p', 0);
    const h = new History();
    for (let i = 0; i < 100; i++) {
      if (i % 5 === 4) h.execute(page, new RemoveObjects([page.objects[Math.floor(page.objects.length / 2)].id]));
      else h.execute(page, new AddObjects([stroke(`s${i}`, i)]));
    }
    const final = page.objects.map((o) => o.id);
    for (let i = 0; i < 100; i++) h.undo(page);
    expect(page.objects.length).toBe(0);
    for (let i = 0; i < 100; i++) h.redo(page);
    expect(page.objects.map((o) => o.id)).toEqual(final);
  });

  it('ne fait rien quand il n’y a rien à annuler', () => {
    const page = createPage('p', 0);
    expect(new History().undo(page)).toBeNull();
  });
});
