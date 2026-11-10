import { bboxUnion } from './geometry';
import type { BBox, PageDoc, PageObject } from './types';

/**
 * Une commande représente une action utilisateur cohérente (une transaction).
 * `apply` et `revert` renvoient la zone de page à redessiner.
 */
export interface Command {
  apply(page: PageDoc): BBox | null;
  revert(page: PageDoc): BBox | null;
}

function unionOf(objects: PageObject[]): BBox | null {
  let b: BBox | null = null;
  for (const o of objects) b = bboxUnion(b, o.bbox);
  return b;
}

export class AddObjects implements Command {
  constructor(private readonly objects: PageObject[]) {}

  apply(page: PageDoc): BBox | null {
    page.objects.push(...this.objects);
    return unionOf(this.objects);
  }

  revert(page: PageDoc): BBox | null {
    const ids = new Set(this.objects.map((o) => o.id));
    page.objects = page.objects.filter((o) => !ids.has(o.id));
    return unionOf(this.objects);
  }
}

export class RemoveObjects implements Command {
  private removed: { index: number; object: PageObject }[] = [];

  constructor(private readonly ids: string[]) {}

  apply(page: PageDoc): BBox | null {
    const ids = new Set(this.ids);
    this.removed = [];
    const kept: PageObject[] = [];
    page.objects.forEach((object, index) => {
      if (ids.has(object.id)) this.removed.push({ index, object });
      else kept.push(object);
    });
    page.objects = kept;
    return unionOf(this.removed.map((r) => r.object));
  }

  /** Réinsère chaque objet à sa position d'origine dans l'ordre d'affichage. */
  revert(page: PageDoc): BBox | null {
    for (const r of this.removed) page.objects.splice(r.index, 0, r.object);
    return unionOf(this.removed.map((r) => r.object));
  }
}

/** Regroupe plusieurs commandes en une seule transaction (ex. un geste de gomme). */
export class Composite implements Command {
  constructor(readonly commands: Command[]) {}

  apply(page: PageDoc): BBox | null {
    let b: BBox | null = null;
    for (const c of this.commands) b = bboxUnion(b, c.apply(page));
    return b;
  }

  revert(page: PageDoc): BBox | null {
    let b: BBox | null = null;
    for (let i = this.commands.length - 1; i >= 0; i--) b = bboxUnion(b, this.commands[i].revert(page));
    return b;
  }
}

export class History {
  private undoStack: Command[] = [];
  private redoStack: Command[] = [];

  constructor(private readonly limit = 200) {}

  /** Exécute la commande et l'empile. Toute nouvelle action invalide la pile de rétablissement. */
  execute(page: PageDoc, command: Command): BBox | null {
    const dirty = command.apply(page);
    this.record(command);
    return dirty;
  }

  /** Empile une commande déjà appliquée. */
  record(command: Command): void {
    this.undoStack.push(command);
    if (this.undoStack.length > this.limit) this.undoStack.shift();
    this.redoStack = [];
  }

  undo(page: PageDoc): BBox | null {
    const c = this.undoStack.pop();
    if (!c) return null;
    this.redoStack.push(c);
    return c.revert(page);
  }

  redo(page: PageDoc): BBox | null {
    const c = this.redoStack.pop();
    if (!c) return null;
    this.undoStack.push(c);
    return c.apply(page);
  }

  get canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  get canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  clear(): void {
    this.undoStack = [];
    this.redoStack = [];
  }
}
