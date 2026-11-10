import type { PageDoc, PageObject } from '../core/types';

const DB_NAME = 'nooty';
const DB_VERSION = 1;

interface PageRecord extends Omit<PageDoc, 'objects'> {
  order: string[];
}

type ObjectRecord = PageObject & { pageId: string };

function req<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

function done(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error ?? new Error('Transaction annulée'));
  });
}

/**
 * Stockage de travail. Chaque objet est une entrée distincte : une sauvegarde n'écrit
 * que les objets ajoutés, remplacés ou supprimés, plus l'en-tête de page, dans une
 * seule transaction IndexedDB (tout ou rien, y compris en cas de fermeture brutale).
 * Les objets sont immuables : une modification remplace l'objet, ce qui la rend détectable.
 */
export class PageStore {
  private persisted = new Map<string, PageObject>();

  private constructor(private readonly db: IDBDatabase) {}

  static open(factory: IDBFactory = indexedDB, name = DB_NAME): Promise<PageStore> {
    return new Promise((resolve, reject) => {
      const r = factory.open(name, DB_VERSION);
      r.onupgradeneeded = () => {
        const db = r.result;
        if (!db.objectStoreNames.contains('pages')) db.createObjectStore('pages', { keyPath: 'id' });
        if (!db.objectStoreNames.contains('objects')) {
          db.createObjectStore('objects', { keyPath: 'id' }).createIndex('pageId', 'pageId');
        }
      };
      r.onsuccess = () => resolve(new PageStore(r.result));
      r.onerror = () => reject(r.error);
      r.onblocked = () => reject(new Error('Base de données bloquée par un autre onglet'));
    });
  }

  /** Charge une page. `missing` compte les objets référencés mais introuvables. */
  async load(pageId: string): Promise<{ page: PageDoc | null; missing: number }> {
    const tx = this.db.transaction(['pages', 'objects'], 'readonly');
    const record = (await req(tx.objectStore('pages').get(pageId))) as PageRecord | undefined;
    if (!record) return { page: null, missing: 0 };
    const rows = (await req(tx.objectStore('objects').index('pageId').getAll(pageId))) as ObjectRecord[];
    const byId = new Map<string, PageObject>();
    for (const row of rows) {
      const { pageId: _pageId, ...object } = row;
      byId.set(object.id, object as PageObject);
    }
    const objects: PageObject[] = [];
    let missing = 0;
    for (const id of record.order) {
      const o = byId.get(id);
      if (o) objects.push(o);
      else missing++;
    }
    this.persisted = new Map(objects.map((o) => [o.id, o]));
    const { order: _order, ...head } = record;
    return { page: { ...head, objects }, missing };
  }

  /** Écrit la différence entre l'état persisté et la page. Retourne le nombre d'écritures d'objets. */
  async save(page: PageDoc): Promise<number> {
    const tx = this.db.transaction(['pages', 'objects'], 'readwrite');
    const store = tx.objectStore('objects');
    const next = new Map<string, PageObject>();
    let writes = 0;
    for (const o of page.objects) {
      next.set(o.id, o);
      if (this.persisted.get(o.id) !== o) {
        store.put({ ...o, pageId: page.id } satisfies ObjectRecord);
        writes++;
      }
    }
    for (const id of this.persisted.keys()) {
      if (!next.has(id)) {
        store.delete(id);
        writes++;
      }
    }
    const { objects: _objects, ...head } = page;
    tx.objectStore('pages').put({ ...head, order: page.objects.map((o) => o.id) } satisfies PageRecord);
    const committed = done(tx);
    // Demande la validation tout de suite au lieu d'attendre la fin de la tâche en cours.
    if (typeof tx.commit === 'function') tx.commit();
    await committed;
    this.persisted = next;
    return writes;
  }

  close(): void {
    this.db.close();
  }
}
