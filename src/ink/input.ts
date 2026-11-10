import type { InputKind } from '../core/types';

export interface RawPoint {
  /** Position en px CSS relative à la surface. */
  x: number;
  y: number;
  /** Horodatage de l'événement (ms, horloge performance). */
  t: number;
  pressure: number;
  tiltX: number;
  tiltY: number;
}

export interface PointerInfo {
  type: string;
  pressure: number;
  tiltX: number;
  tiltY: number;
  coalesced: number;
  predicted: number;
}

export interface InkInputHandlers {
  strokeStart(p: RawPoint, kind: InputKind): void;
  strokeMove(points: RawPoint[], predicted: RawPoint[]): void;
  strokeEnd(): void;
  strokeCancel(): void;
  pan(dx: number, dy: number): void;
  pinch(c0x: number, c0y: number, d0: number, c1x: number, c1y: number, d1: number): void;
  wheelZoom(x: number, y: number, factor: number): void;
  info(i: PointerInfo): void;
}

export interface InkInputOptions {
  /** Si vrai, un doigt seul dessine ; sinon le doigt navigue et seul le stylet (ou la souris) dessine. */
  fingerDraws: boolean;
  /** Utilise les points prédits par le navigateur pour l'affichage en direct, s'ils existent. */
  usePrediction: boolean;
}

/** Délai après le dernier contact du stylet pendant lequel le tactile est ignoré (paume). */
const PALM_GUARD_MS = 400;

export const supportsCoalesced =
  typeof PointerEvent !== 'undefined' && 'getCoalescedEvents' in PointerEvent.prototype;
export const supportsPredicted =
  typeof PointerEvent !== 'undefined' && 'getPredictedEvents' in PointerEvent.prototype;

/**
 * Traduit les événements de pointeur en gestes : dessin (stylet, souris, doigt en option),
 * navigation (un doigt : déplacement ; deux doigts : pincement ; molette), avec rejet de paume
 * dans les limites de ce que le navigateur expose.
 */
export class InkInput {
  private drawingId: number | null = null;
  private touches = new Map<number, { x: number; y: number }>();
  private ignored = new Set<number>();
  private mousePanId: number | null = null;
  private lastMouse = { x: 0, y: 0 };
  private lastPenTime = -Infinity;
  private rect: DOMRect;

  constructor(
    private readonly el: HTMLElement,
    private readonly h: InkInputHandlers,
    readonly options: InkInputOptions,
  ) {
    this.rect = el.getBoundingClientRect();
    el.addEventListener('pointerdown', this.onDown);
    el.addEventListener('pointermove', this.onMove);
    el.addEventListener('pointerup', this.onUp);
    el.addEventListener('pointercancel', this.onCancel);
    el.addEventListener('lostpointercapture', this.onLost);
    el.addEventListener('wheel', this.onWheel, { passive: false });
    el.addEventListener('contextmenu', (e) => e.preventDefault());
    // Empêche le défilement, le zoom natif et la loupe de Safari sur la surface.
    for (const type of ['touchstart', 'touchmove', 'gesturestart', 'gesturechange']) {
      el.addEventListener(type, (e) => e.preventDefault(), { passive: false });
    }
  }

  get isDrawing(): boolean {
    return this.drawingId !== null;
  }

  private raw(e: PointerEvent): RawPoint {
    const isPen = e.pointerType === 'pen';
    return {
      x: e.clientX - this.rect.left,
      y: e.clientY - this.rect.top,
      t: e.timeStamp,
      // Sans capteur de pression (souris, doigt, stylet passif), on retient la valeur neutre 0,5.
      pressure: isPen && e.pressure > 0 ? e.pressure : 0.5,
      tiltX: isPen ? e.tiltX || 0 : 0,
      tiltY: isPen ? e.tiltY || 0 : 0,
    };
  }

  private capture(id: number): void {
    try {
      this.el.setPointerCapture(id);
    } catch {
      /* le pointeur a déjà disparu */
    }
  }

  private dropTouches(): void {
    for (const id of this.touches.keys()) this.ignored.add(id);
    this.touches.clear();
  }

  private onDown = (e: PointerEvent): void => {
    this.rect = this.el.getBoundingClientRect();
    if (e.pointerType === 'pen') {
      this.lastPenTime = e.timeStamp;
      if (this.drawingId !== null) return;
      this.dropTouches();
      this.begin(e, 'pen');
      return;
    }
    if (e.pointerType === 'mouse') {
      if (e.button === 0 && this.drawingId === null) this.begin(e, 'mouse');
      else if (e.button === 1 || e.button === 2) {
        this.mousePanId = e.pointerId;
        this.lastMouse = { x: e.clientX, y: e.clientY };
        this.capture(e.pointerId);
        e.preventDefault();
      }
      return;
    }
    // Tactile : ignoré si le stylet écrit ou vient d'écrire (paume posée).
    const penBusy = this.drawingId !== null && !this.touches.has(this.drawingId);
    if (penBusy || e.timeStamp - this.lastPenTime < PALM_GUARD_MS) {
      this.ignored.add(e.pointerId);
      return;
    }
    if (this.options.fingerDraws) {
      if (this.touches.size === 0 && this.drawingId === null) {
        this.touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
        this.begin(e, 'touch');
        return;
      }
      // Un second doigt transforme le geste en navigation : le trait entamé est abandonné.
      if (this.drawingId !== null) {
        this.drawingId = null;
        this.h.strokeCancel();
      }
    }
    this.touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    this.capture(e.pointerId);
  };

  private begin(e: PointerEvent, kind: InputKind): void {
    this.drawingId = e.pointerId;
    this.capture(e.pointerId);
    this.h.strokeStart(this.raw(e), kind);
    this.report(e, 1, 0);
  }

  private report(e: PointerEvent, coalesced: number, predicted: number): void {
    this.h.info({
      type: e.pointerType,
      pressure: e.pressure,
      tiltX: e.tiltX || 0,
      tiltY: e.tiltY || 0,
      coalesced,
      predicted,
    });
  }

  private onMove = (e: PointerEvent): void => {
    if (e.pointerType === 'pen') this.lastPenTime = e.timeStamp;
    if (e.pointerId === this.drawingId) {
      const list = supportsCoalesced ? e.getCoalescedEvents() : [];
      const events = list.length > 0 ? list : [e];
      const predicted = this.options.usePrediction && supportsPredicted ? e.getPredictedEvents() : [];
      this.h.strokeMove(events.map((ev) => this.raw(ev)), predicted.map((ev) => this.raw(ev)));
      this.report(e, events.length, predicted.length);
      return;
    }
    if (e.pointerId === this.mousePanId) {
      this.h.pan(e.clientX - this.lastMouse.x, e.clientY - this.lastMouse.y);
      this.lastMouse = { x: e.clientX, y: e.clientY };
      return;
    }
    const prev = this.touches.get(e.pointerId);
    if (!prev || this.ignored.has(e.pointerId)) return;
    if (this.touches.size === 1) {
      this.h.pan(e.clientX - prev.x, e.clientY - prev.y);
      prev.x = e.clientX;
      prev.y = e.clientY;
    } else if (this.touches.size === 2) {
      let other = prev;
      for (const [id, p] of this.touches) if (id !== e.pointerId) other = p;
      const l = this.rect.left;
      const t = this.rect.top;
      const c0x = (prev.x + other.x) / 2 - l;
      const c0y = (prev.y + other.y) / 2 - t;
      const d0 = Math.hypot(prev.x - other.x, prev.y - other.y);
      prev.x = e.clientX;
      prev.y = e.clientY;
      const c1x = (prev.x + other.x) / 2 - l;
      const c1y = (prev.y + other.y) / 2 - t;
      const d1 = Math.hypot(prev.x - other.x, prev.y - other.y);
      this.h.pinch(c0x, c0y, d0, c1x, c1y, d1);
    }
  };

  private release(e: PointerEvent): boolean {
    this.ignored.delete(e.pointerId);
    this.touches.delete(e.pointerId);
    if (e.pointerId === this.mousePanId) this.mousePanId = null;
    if (e.pointerId !== this.drawingId) return false;
    this.drawingId = null;
    return true;
  }

  private onUp = (e: PointerEvent): void => {
    if (e.pointerType === 'pen') this.lastPenTime = e.timeStamp;
    if (this.release(e)) this.h.strokeEnd();
  };

  /** Le système a repris la main (geste système, appel, changement d'application) : le trait est abandonné. */
  private onCancel = (e: PointerEvent): void => {
    if (this.release(e)) this.h.strokeCancel();
  };

  private onLost = (e: PointerEvent): void => {
    if (this.release(e)) this.h.strokeCancel();
  };

  private onWheel = (e: WheelEvent): void => {
    e.preventDefault();
    if (e.ctrlKey || e.metaKey) {
      this.rect = this.el.getBoundingClientRect();
      this.h.wheelZoom(e.clientX - this.rect.left, e.clientY - this.rect.top, Math.exp(-e.deltaY * 0.01));
    } else {
      this.h.pan(-e.deltaX, -e.deltaY);
    }
  };
}
