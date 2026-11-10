import './style.css';
import { generateStrokes } from '../core/benchmark';
import { AddObjects, Composite, History, RemoveObjects, type Command } from '../core/commands';
import { computeBBox, createStroke, hitTestStroke, PointBuffer } from '../core/stroke';
import {
  POINT_STRIDE, createPage, defaultBackground, newId,
  type BackgroundKind, type InputKind, type PageDoc,
} from '../core/types';
import { fitWidth, panBy, pinch, sameView, screenToPage, zoomAt, type View } from '../core/viewport';
import { t, type MessageKey } from '../i18n';
import { InkInput, supportsCoalesced, supportsPredicted, type PointerInfo, type RawPoint } from '../ink/input';
import { InkRenderer } from '../ink/renderer';
import { PageStore } from '../storage/db';

const PAGE_ID = 'prototype-page';
const SETTINGS_KEY = 'nooty.prototype.settings';
const ERASER_RADIUS_PX = 8;
/** Au-delà de cette durée de rendu complet, zoom et déplacement passent par une prévisualisation. */
const FAST_RENDER_MS = 12;

const COLORS: { key: MessageKey; value: string }[] = [
  { key: 'color.ink', value: '#1d2a44' },
  { key: 'color.black', value: '#111111' },
  { key: 'color.red', value: '#c62828' },
  { key: 'color.green', value: '#2e7d32' },
  { key: 'color.blue', value: '#1565c0' },
];
const WIDTHS: { key: MessageKey; value: number; dot: number }[] = [
  { key: 'width.fine', value: 0.6, dot: 5 },
  { key: 'width.medium', value: 1.1, dot: 9 },
  { key: 'width.thick', value: 2.2, dot: 14 },
];
const BACKGROUNDS: { key: MessageKey; value: BackgroundKind }[] = [
  { key: 'bg.blank', value: 'blank' },
  { key: 'bg.ruled', value: 'ruled' },
  { key: 'bg.grid', value: 'grid' },
  { key: 'bg.dots', value: 'dots' },
];

const ICONS = {
  pen: '<path d="M4 20l1-4L16.5 4.5a2.1 2.1 0 013 3L8 19l-4 1z"/><path d="M14.5 6.5l3 3"/>',
  eraser: '<path d="M8.5 19.5L4 15a1.5 1.5 0 010-2.1l8.9-8.9a1.5 1.5 0 012.1 0l5 5a1.5 1.5 0 010 2.1l-8.4 8.4H8.5z"/><path d="M9 9l6 6"/><path d="M11.6 19.5H20"/>',
  undo: '<path d="M8 6L3 11l5 5"/><path d="M3 11h11a5 5 0 010 10h-3"/>',
  redo: '<path d="M16 6l5 5-5 5"/><path d="M21 11H10a5 5 0 000 10h3"/>',
  menu: '<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>',
};

interface Settings {
  tool: 'pen' | 'eraser';
  color: string;
  width: number;
  fingerDraws: boolean;
  usePrediction: boolean;
  diagnostics: boolean;
}

function loadSettings(): Settings {
  const defaults: Settings = {
    tool: 'pen', color: COLORS[0].value, width: WIDTHS[1].value,
    fingerDraws: false, usePrediction: false, diagnostics: false,
  };
  try {
    const raw = JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}') as Partial<Settings>;
    return {
      tool: raw.tool === 'eraser' ? 'eraser' : 'pen',
      color: COLORS.some((c) => c.value === raw.color) ? raw.color! : defaults.color,
      width: WIDTHS.some((w) => w.value === raw.width) ? raw.width! : defaults.width,
      fingerDraws: raw.fingerDraws === true,
      usePrediction: raw.usePrediction === true,
      diagnostics: raw.diagnostics === true,
    };
  } catch {
    return defaults;
  }
}

const settings = loadSettings();
function saveSettings(): void {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch {
    /* préférences non conservées : sans conséquence sur les notes */
  }
}

// ---------- État du document ----------

let page: PageDoc = createPage(PAGE_ID, Date.now());
let view: View = { scale: 1, tx: 0, ty: 0 };
const history = new History();

// ---------- Construction de l'interface ----------

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K, attrs: Record<string, string> = {}, html = '',
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  if (html) node.innerHTML = html;
  return node;
}

const icon = (name: keyof typeof ICONS) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;

const app = document.getElementById('app')!;
const surface = el('div', { class: 'surface', tabindex: '0', role: 'application', 'aria-label': t('canvas.label') });
const toolbar = el('div', { class: 'toolbar', role: 'toolbar', 'aria-label': t('tool.group') });
const menu = el('div', { class: 'menu', id: 'menu', hidden: '' });
const status = el('div', { class: 'status', role: 'status', 'aria-live': 'polite' });
const diag = el('pre', { class: 'diag', 'aria-label': t('diag.title') });
app.append(surface, toolbar, menu, diag, status);

function radioGroup<T>(
  label: string, items: { label: string; value: T; html: string }[], get: () => T, set: (v: T) => void,
): { root: HTMLElement; sync: () => void } {
  const root = el('div', { class: 'group', role: 'radiogroup', 'aria-label': label });
  const buttons = items.map((item) => {
    const b = el('button', { class: 'tb', type: 'button', role: 'radio', 'aria-label': item.label, title: item.label }, item.html);
    b.addEventListener('click', () => {
      set(item.value);
      sync();
    });
    root.append(b);
    return { b, value: item.value };
  });
  const sync = () => buttons.forEach(({ b, value }) => b.setAttribute('aria-checked', String(value === get())));
  sync();
  return { root, sync };
}

function actionButton(label: string, html: string, onClick: () => void): HTMLButtonElement {
  const b = el('button', { class: 'tb', type: 'button', 'aria-label': label, title: label }, html);
  b.addEventListener('click', onClick);
  return b;
}

const sep = () => el('div', { class: 'sep', 'aria-hidden': 'true' });

const toolGroup = radioGroup<'pen' | 'eraser'>(
  t('tool.group'),
  [
    { label: t('tool.pen'), value: 'pen', html: icon('pen') },
    { label: t('tool.eraser'), value: 'eraser', html: icon('eraser') },
  ],
  () => settings.tool,
  (v) => {
    settings.tool = v;
    saveSettings();
  },
);
const colorGroup = radioGroup(
  t('color.group'),
  COLORS.map((c) => ({ label: t(c.key), value: c.value, html: `<span class="swatch" style="background:${c.value}"></span>` })),
  () => settings.color,
  (v) => {
    settings.color = v;
    saveSettings();
  },
);
const widthGroup = radioGroup(
  t('width.group'),
  WIDTHS.map((w) => ({ label: t(w.key), value: w.value, html: `<span class="dot" style="width:${w.dot}px;height:${w.dot}px"></span>` })),
  () => settings.width,
  (v) => {
    settings.width = v;
    saveSettings();
  },
);
const undoBtn = actionButton(t('action.undo'), icon('undo'), () => undo());
const redoBtn = actionButton(t('action.redo'), icon('redo'), () => redo());
const zoomBtn = actionButton(t('action.fit'), '', () => fitView());
zoomBtn.classList.add('zoom');
const menuBtn = actionButton(t('action.menu'), icon('menu'), () => toggleMenu());
menuBtn.setAttribute('aria-expanded', 'false');
menuBtn.setAttribute('aria-controls', 'menu');
toolbar.append(toolGroup.root, sep(), colorGroup.root, sep(), widthGroup.root, sep(), undoBtn, redoBtn, sep(), zoomBtn, menuBtn);

function checkbox(label: string, hint: string, get: () => boolean, set: (v: boolean) => void, disabled = false): HTMLElement {
  const root = el('label', { class: 'check' });
  const input = el('input', { type: 'checkbox' });
  input.checked = get();
  input.disabled = disabled;
  input.addEventListener('change', () => set(input.checked));
  const text = el('span');
  text.append(label, el('small', {}, hint));
  root.append(input, text);
  return root;
}

const bgSection = el('section', {}, `<h2>${t('menu.background')}</h2>`);
const bgGroup = radioGroup<BackgroundKind>(
  t('menu.background'),
  BACKGROUNDS.map((b) => ({ label: t(b.key), value: b.value, html: t(b.key) })),
  () => page.background.kind,
  (kind) => {
    page.background = defaultBackground(kind);
    renderer.renderAll(page, view);
    changed();
  },
);
bgGroup.root.classList.add('seg');
bgSection.append(bgGroup.root);

const inputSection = el('section');
inputSection.append(
  checkbox(t('menu.fingerDraws'), t('menu.fingerDraws.hint'), () => settings.fingerDraws, (v) => {
    settings.fingerDraws = v;
    input.options.fingerDraws = v;
    saveSettings();
  }),
  checkbox(
    t('menu.prediction'),
    supportsPredicted ? t('menu.prediction.hint') : t('menu.prediction.unsupported'),
    () => settings.usePrediction && supportsPredicted,
    (v) => {
      settings.usePrediction = v;
      input.options.usePrediction = v;
      saveSettings();
    },
    !supportsPredicted,
  ),
  checkbox(t('menu.diagnostics'), '', () => settings.diagnostics, (v) => {
    settings.diagnostics = v;
    saveSettings();
    syncDiagnostics();
  }),
);

const testSection = el('section');
const stressBtn = el('button', { class: 'row-btn', type: 'button' }, t('menu.stress'));
stressBtn.addEventListener('click', () => {
  flushView();
  history.execute(page, new AddObjects(generateStrokes(page, 5000, 42, () => newId(), Date.now())));
  renderer.renderAll(page, view);
  changed();
});
const clearBtn = el('button', { class: 'row-btn danger', type: 'button' }, t('menu.clear'));
clearBtn.addEventListener('click', () => {
  if (page.objects.length === 0) return;
  flushView();
  history.execute(page, new RemoveObjects(page.objects.map((o) => o.id)));
  renderer.renderAll(page, view);
  changed();
});
testSection.append(stressBtn, clearBtn);
menu.append(bgSection, inputSection, testSection);

function toggleMenu(force?: boolean): void {
  const open = force ?? menu.hidden;
  menu.hidden = !open;
  menuBtn.setAttribute('aria-expanded', String(open));
}

const renderer = new InkRenderer(surface);

function updateUi(): void {
  undoBtn.disabled = !history.canUndo;
  redoBtn.disabled = !history.canRedo;
  zoomBtn.textContent = `${Math.round(view.scale * 100)} %`;
  surface.dataset.strokes = String(page.objects.length);
}

// ---------- Vue ----------

let viewRaf = 0;
let settleTimer = 0;

function setView(v: View): void {
  if (sameView(v, view)) return;
  view = v;
  zoomBtn.textContent = `${Math.round(view.scale * 100)} %`;
  if (renderer.lastFullMs < FAST_RENDER_MS) {
    if (!viewRaf) {
      viewRaf = requestAnimationFrame(() => {
        viewRaf = 0;
        renderer.renderAll(page, view);
      });
    }
  } else {
    renderer.previewView(view);
    clearTimeout(settleTimer);
    settleTimer = window.setTimeout(() => renderer.renderAll(page, view), 140);
  }
}

/** Garantit que le calque validé correspond à la vue courante avant tout dessin. */
function flushView(): void {
  cancelAnimationFrame(viewRaf);
  viewRaf = 0;
  clearTimeout(settleTimer);
  if (!sameView(renderer.rendered, view)) renderer.renderAll(page, view);
}

function fitView(): void {
  setView(fitWidth(page.width, surface.clientWidth, 16, 76));
}

// ---------- Sauvegarde ----------

let store: PageStore | null = null;
let saving = false;
let dirty = false;
let persistent: boolean | null = null;

function setStatus(state: 'saved' | 'saving' | 'error' | 'unavailable', text?: string): void {
  status.dataset.state = state;
  surface.dataset.save = state;
  status.textContent = text ?? t(`save.${state}`);
}

function changed(): void {
  page.updatedAt = Date.now();
  updateUi();
  if (!store) return;
  dirty = true;
  setStatus('saving');
  // Écriture immédiate : seule la différence est écrite, et une fermeture brutale
  // juste après un trait ne doit pas le perdre.
  void flushSave();
}

async function flushSave(): Promise<void> {
  if (!store || saving) return;
  saving = true;
  let ok = true;
  while (dirty && ok) {
    dirty = false;
    try {
      await store.save(page);
    } catch (err) {
      console.error(err);
      dirty = true;
      ok = false;
    }
  }
  saving = false;
  setStatus(ok ? 'saved' : 'error');
}

// ---------- Encre ----------

const buf = new PointBuffer();
let strokeT0 = 0;
let strokeEpoch = 0;
let strokeKind: InputKind = 'pen';
let erasing: Command[] | null = null;
let lastErase: [number, number] | null = null;
let rawPointCount = 0;
let lastInfo: PointerInfo | null = null;

function addPoint(p: RawPoint): void {
  const [x, y] = screenToPage(view, p.x, p.y);
  if (buf.count > 0) {
    const o = (buf.count - 1) * POINT_STRIDE;
    const min = 0.25 / view.scale;
    if (Math.abs(buf.data[o] - x) < min && Math.abs(buf.data[o + 1] - y) < min) return;
  }
  buf.push(x, y, p.t - strokeT0, p.pressure, p.tiltX, p.tiltY);
}

function drawLive(predicted: RawPoint[]): void {
  const real = buf.count;
  for (const p of predicted) addPoint(p);
  renderer.renderLive(page, buf.data, buf.count, settings.color, settings.width, computeBBox(buf.data, buf.count, settings.width));
  buf.count = real; // les points prédits ne sont jamais conservés
}

function eraseAt(p: RawPoint): void {
  const [x, y] = screenToPage(view, p.x, p.y);
  const radius = ERASER_RADIUS_PX / view.scale;
  const from = lastErase ?? [x, y];
  const steps = Math.max(1, Math.ceil(Math.hypot(x - from[0], y - from[1]) / radius));
  for (let s = 1; s <= steps; s++) {
    const px = from[0] + ((x - from[0]) * s) / steps;
    const py = from[1] + ((y - from[1]) * s) / steps;
    for (let i = page.objects.length - 1; i >= 0; i--) {
      const o = page.objects[i];
      if (!hitTestStroke(o, px, py, radius)) continue;
      const cmd = new RemoveObjects([o.id]);
      const area = cmd.apply(page);
      erasing!.push(cmd);
      if (area) renderer.renderRegion(page, area);
    }
  }
  lastErase = [x, y];
}

function finishErase(): void {
  if (erasing && erasing.length > 0) {
    history.record(new Composite(erasing));
    changed();
  }
  erasing = null;
  lastErase = null;
}

const input = new InkInput(
  surface,
  {
    strokeStart(p, kind) {
      toggleMenu(false);
      flushView();
      rawPointCount++;
      if (settings.tool === 'eraser') {
        erasing = [];
        lastErase = null;
        eraseAt(p);
        return;
      }
      buf.clear();
      strokeT0 = p.t;
      strokeEpoch = Date.now();
      strokeKind = kind;
      addPoint(p);
      drawLive([]);
    },
    strokeMove(points, predicted) {
      rawPointCount += points.length;
      if (erasing) {
        for (const p of points) eraseAt(p);
        return;
      }
      for (const p of points) addPoint(p);
      drawLive(predicted);
    },
    strokeEnd() {
      if (erasing) {
        finishErase();
        return;
      }
      if (buf.count > 0) {
        const stroke = createStroke(newId(), buf.toArray(), settings.color, settings.width, strokeEpoch, strokeKind);
        history.execute(page, new AddObjects([stroke]));
        renderer.appendStroke(page, stroke);
        changed();
      }
      renderer.clearLive();
      buf.clear();
    },
    strokeCancel() {
      if (erasing) {
        finishErase();
        return;
      }
      renderer.clearLive();
      buf.clear();
    },
    pan: (dx, dy) => setView(panBy(view, dx, dy)),
    pinch: (c0x, c0y, d0, c1x, c1y, d1) => setView(pinch(view, c0x, c0y, d0, c1x, c1y, d1)),
    wheelZoom: (x, y, factor) => setView(zoomAt(view, x, y, factor)),
    info(i) {
      lastInfo = i;
    },
  },
  { fingerDraws: settings.fingerDraws, usePrediction: settings.usePrediction && supportsPredicted },
);

function undo(): void {
  if (input.isDrawing) return;
  flushView();
  const area = history.undo(page);
  if (area) renderer.renderRegion(page, area);
  changed();
}

function redo(): void {
  if (input.isDrawing) return;
  flushView();
  const area = history.redo(page);
  if (area) renderer.renderRegion(page, area);
  changed();
}

window.addEventListener('keydown', (e) => {
  const mod = e.ctrlKey || e.metaKey;
  const key = e.key.toLowerCase();
  if (mod && key === 'z') {
    e.preventDefault();
    if (e.shiftKey) redo();
    else undo();
  } else if (mod && key === 'y') {
    e.preventDefault();
    redo();
  } else if (e.key === 'Escape') {
    toggleMenu(false);
  } else if (!mod && !e.altKey && e.target === surface && (key === 'p' || key === 'e')) {
    settings.tool = key === 'p' ? 'pen' : 'eraser';
    saveSettings();
    toolGroup.sync();
  }
});

// ---------- Diagnostic ----------

let diagTimer = 0;
let diagRaf = 0;
let lastFrame = 0;
let slowestFrame = 0;
let rateWindowStart = performance.now();

function frameProbe(now: number): void {
  if (lastFrame) slowestFrame = Math.max(slowestFrame, now - lastFrame);
  lastFrame = now;
  diagRaf = requestAnimationFrame(frameProbe);
}

function refreshDiagnostics(): void {
  const now = performance.now();
  const rate = Math.round((rawPointCount * 1000) / Math.max(1, now - rateWindowStart));
  rawPointCount = 0;
  rateWindowStart = now;
  let points = 0;
  for (const o of page.objects) points += o.points.length / POINT_STRIDE;
  const i = lastInfo;
  const yn = (v: boolean | null) => (v === null ? t('diag.unknown') : v ? t('diag.yes') : t('diag.no'));
  const rows: [string, string][] = [
    [t('diag.pointer'), i ? i.type : '—'],
    [t('diag.pressure'), i ? i.pressure.toFixed(3) : '—'],
    [t('diag.tilt'), i ? `${i.tiltX}° / ${i.tiltY}°` : '—'],
    [t('diag.rate'), String(rate)],
    [t('diag.coalesced'), supportsCoalesced ? String(i?.coalesced ?? 0) : t('diag.no')],
    [t('diag.predicted'), supportsPredicted ? String(i?.predicted ?? 0) : t('diag.no')],
    [t('diag.strokes'), String(page.objects.length)],
    [t('diag.points'), String(points)],
    [t('diag.zoom'), `${Math.round(view.scale * 100)} %`],
    [t('diag.dpr'), String(renderer.pixelRatio)],
    [t('diag.render'), `${renderer.lastFullMs.toFixed(1)} ms`],
    [t('diag.frame'), `${slowestFrame.toFixed(1)} ms`],
    [t('diag.persist'), yn(persistent)],
  ];
  const pad = Math.max(...rows.map((r) => r[0].length));
  diag.textContent = rows.map(([k, v]) => `${k.padEnd(pad)}  ${v}`).join('\n');
  slowestFrame = 0;
}

function syncDiagnostics(): void {
  diag.hidden = !settings.diagnostics;
  clearInterval(diagTimer);
  cancelAnimationFrame(diagRaf);
  lastFrame = 0;
  if (settings.diagnostics) {
    refreshDiagnostics();
    diagTimer = window.setInterval(refreshDiagnostics, 1000);
    diagRaf = requestAnimationFrame(frameProbe);
  }
}

// ---------- Démarrage ----------

function layout(): void {
  const changedSize = renderer.resize(surface.clientWidth, surface.clientHeight, window.devicePixelRatio || 1);
  if (changedSize) renderer.renderAll(page, view);
}

async function start(): Promise<void> {
  renderer.resize(surface.clientWidth, surface.clientHeight, window.devicePixelRatio || 1);
  view = fitWidth(page.width, surface.clientWidth, 16, 76);
  renderer.renderAll(page, view);
  updateUi();
  syncDiagnostics();
  new ResizeObserver(layout).observe(surface);
  window.addEventListener('resize', layout);

  try {
    store = await PageStore.open();
    const loaded = await store.load(PAGE_ID);
    if (loaded.page) {
      page = loaded.page;
      bgGroup.sync();
      renderer.renderAll(page, view);
      updateUi();
    }
    setStatus('saved', loaded.missing > 0 ? t('load.missing', { n: loaded.missing }) : undefined);
  } catch (err) {
    console.error(err);
    store = null;
    setStatus('unavailable');
  }

  // Demande au navigateur de ne pas purger les notes ; il peut refuser.
  try {
    persistent = (await navigator.storage?.persist?.()) ?? null;
  } catch {
    persistent = null;
  }

  const flushNow = () => {
    if (document.visibilityState === 'hidden') void flushSave();
  };
  document.addEventListener('visibilitychange', flushNow);
  window.addEventListener('pagehide', () => void flushSave());

  if (import.meta.env.PROD && 'serviceWorker' in navigator) {
    navigator.serviceWorker.register('./sw.js').catch((err) => console.error(err));
  }
}

void start();
