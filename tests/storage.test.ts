import { IDBFactory } from 'fake-indexeddb';
import { describe, expect, it } from 'vitest';
import { generateStrokes } from '../src/core/benchmark';
import { createPage, defaultBackground } from '../src/core/types';
import { PageStore } from '../src/storage/db';

function sample(n: number) {
  const page = createPage('p1', 1);
  page.objects = generateStrokes(page, n, 3, (i) => `s${i}`, 1);
  return page;
}

describe('stockage de travail', () => {
  it('retourne null pour une page inconnue', async () => {
    const store = await PageStore.open(new IDBFactory());
    expect((await store.load('absente')).page).toBeNull();
  });

  it('écrit, ferme, rouvre et retrouve le même contenu dans le même ordre', async () => {
    const factory = new IDBFactory();
    const page = sample(50);
    page.background = defaultBackground('dots');
    const a = await PageStore.open(factory);
    await a.save(page);
    a.close();

    const b = await PageStore.open(factory);
    const { page: loaded, missing } = await b.load('p1');
    expect(missing).toBe(0);
    expect(loaded!.background.kind).toBe('dots');
    expect(loaded!.objects.map((o) => o.id)).toEqual(page.objects.map((o) => o.id));
    expect(Array.from(loaded!.objects[17].points)).toEqual(Array.from(page.objects[17].points));
    expect(loaded!.objects[17].points).toBeInstanceOf(Float32Array);
    expect(loaded!.objects[17]).not.toHaveProperty('pageId');
  });

  it('n’écrit que les objets ajoutés ou supprimés', async () => {
    const factory = new IDBFactory();
    const page = sample(200);
    const store = await PageStore.open(factory);
    expect(await store.save(page)).toBe(200);
    expect(await store.save(page)).toBe(0);

    const extra = generateStrokes(page, 1, 9, () => 'nouveau', 2)[0];
    page.objects.push(extra);
    expect(await store.save(page)).toBe(1);

    page.objects = page.objects.filter((o) => o.id !== 's3' && o.id !== 's4');
    expect(await store.save(page)).toBe(2);
    store.close();

    const { page: loaded } = await (await PageStore.open(factory)).load('p1');
    expect(loaded!.objects.length).toBe(199);
    expect(loaded!.objects.some((o) => o.id === 's3')).toBe(false);
    expect(loaded!.objects.at(-1)!.id).toBe('nouveau');
  });

  it('n’écrit que la différence après un rechargement', async () => {
    const factory = new IDBFactory();
    const first = await PageStore.open(factory);
    await first.save(sample(30));
    first.close();
    const store = await PageStore.open(factory);
    const { page } = await store.load('p1');
    expect(await store.save(page!)).toBe(0);
  });

  it('signale les objets référencés mais absents', async () => {
    const factory = new IDBFactory();
    const store = await PageStore.open(factory, 'corrompue');
    await store.save(sample(5));
    store.close();
    await new Promise<void>((resolve, reject) => {
      const r = factory.open('corrompue');
      r.onsuccess = () => {
        const tx = r.result.transaction('objects', 'readwrite');
        tx.objectStore('objects').delete('s2');
        tx.oncomplete = () => { r.result.close(); resolve(); };
        tx.onerror = () => reject(tx.error);
      };
    });
    const { page, missing } = await (await PageStore.open(factory, 'corrompue')).load('p1');
    expect(missing).toBe(1);
    expect(page!.objects.map((o) => o.id)).toEqual(['s0', 's1', 's3', 's4']);
  });
});
