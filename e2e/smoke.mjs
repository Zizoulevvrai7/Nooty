// Test navigateur de bout en bout sur le build de production (souris simulée, Chromium).
// Usage : npm run build && npm run e2e
// Ne remplace pas les essais au stylet réel.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const URL = 'http://localhost:4173/';
const results = [];
function check(name, ok, detail = '') {
  results.push(ok);
  console.log(`${ok ? 'OK    ' : 'ÉCHEC '} ${name}${detail ? ` — ${detail}` : ''}`);
}

const server = spawn('npx', ['vite', 'preview', '--port', '4173', '--strictPort'], { stdio: 'ignore' });
async function waitForServer() {
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(URL)).ok) return;
    } catch { /* pas encore prêt */ }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('Serveur de prévisualisation injoignable');
}

const strokes = (page) => page.locator('.surface').getAttribute('data-strokes').then(Number);
const saved = (page) => page.waitForFunction(() => document.querySelector('.surface')?.dataset.save === 'saved');

async function draw(page, pts) {
  await page.mouse.move(pts[0][0], pts[0][1]);
  await page.mouse.down();
  for (const [x, y] of pts.slice(1)) await page.mouse.move(x, y, { steps: 6 });
  await page.mouse.up();
}

/** Compte les pixels sombres (encre) dans le calque validé. */
const inkPixels = (page) => page.evaluate(() => {
  const c = document.querySelector('canvas.ink-layer');
  const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i + 3] > 0 && d[i] < 90 && d[i + 1] < 90 && d[i + 2] < 110) n++;
  return n;
});

let browser;
try {
  await waitForServer();
  mkdirSync('e2e/out', { recursive: true });
  browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1024, height: 768 }, deviceScaleFactor: 2 });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.goto(URL);
  await saved(page);

  check('page vide au premier lancement', (await strokes(page)) === 0);
  const empty = await inkPixels(page);

  await draw(page, [[300, 300], [380, 340], [460, 300], [540, 360]]);
  await draw(page, [[300, 450], [420, 470], [560, 440]]);
  await draw(page, [[300, 560], [300, 560]]);
  check('trois traits tracés (dont un simple appui)', (await strokes(page)) === 3);
  const inked = await inkPixels(page);
  check('les traits sont visibles sur le calque validé', inked > empty + 500, `${inked - empty} pixels d’encre`);

  await page.getByRole('button', { name: 'Annuler' }).click();
  check('annuler retire le dernier trait', (await strokes(page)) === 2);
  await page.keyboard.press('Control+z');
  check('Ctrl+Z annule', (await strokes(page)) === 1);
  await page.keyboard.press('Control+Shift+z');
  await page.getByRole('button', { name: 'Rétablir' }).click();
  check('rétablir restaure les traits', (await strokes(page)) === 3);
  check('rétablir redonne le même rendu', (await inkPixels(page)) === inked);

  await page.getByRole('radio', { name: 'Gomme (trait entier)' }).click();
  await draw(page, [[430, 420], [430, 500]]);
  check('la gomme supprime le trait traversé, et lui seul', (await strokes(page)) === 2);
  await page.getByRole('button', { name: 'Annuler' }).click();
  check('annuler restaure le trait gommé', (await strokes(page)) === 3 && (await inkPixels(page)) === inked);
  await page.getByRole('button', { name: 'Rétablir' }).click();
  await page.getByRole('radio', { name: 'Stylo' }).click();

  // Zoom : le rendu vectoriel doit être redessiné net, puis revenir à l'identique.
  await page.mouse.move(400, 400);
  await page.keyboard.down('Control');
  await page.mouse.wheel(0, -120);
  await page.keyboard.up('Control');
  await page.waitForTimeout(300);
  const zoomLabel = await page.locator('.zoom').textContent();
  check('Ctrl+molette zoome', parseInt(zoomLabel, 10) > 200, zoomLabel);
  await page.locator('.zoom').click();
  await page.waitForTimeout(300);

  await saved(page);
  const beforeReload = await inkPixels(page);
  await page.reload();
  await page.waitForFunction(() => document.querySelector('.surface')?.dataset.strokes === '2');
  check('les traits survivent au rechargement', (await strokes(page)) === 2);
  check('rendu identique après rechargement', (await inkPixels(page)) === beforeReload);

  // Fermeture brutale : on trace puis on ferme l'onglet sans attendre l'enregistrement différé.
  await draw(page, [[600, 600], [700, 620]]);
  await page.close({ runBeforeUnload: false });
  const page2 = await context.newPage();
  page2.on('pageerror', (e) => errors.push(e.message));
  await page2.goto(URL);
  await saved(page2);
  check('le trait tracé juste avant la fermeture de l’onglet est conservé', (await strokes(page2)) === 3, `${await strokes(page2)} traits`);

  // Hors connexion : le service worker doit servir l'application.
  await page2.evaluate(() => navigator.serviceWorker.ready);
  await page2.waitForFunction(() => navigator.serviceWorker.controller !== null);
  await context.setOffline(true);
  await page2.reload();
  await saved(page2);
  check('l’application se recharge hors connexion avec ses données', (await strokes(page2)) === 3);
  await draw(page2, [[300, 650], [400, 660]]);
  await saved(page2);
  check('écrire et enregistrer fonctionne hors connexion', (await strokes(page2)) === 4);
  await context.setOffline(false);

  // Test de charge.
  await page2.getByRole('button', { name: 'Options' }).click();
  await page2.getByRole('checkbox', { name: /Afficher le diagnostic/ }).check();
  await page2.getByRole('button', { name: /Test de charge/ }).click();
  await saved(page2);
  check('5 000 traits ajoutés et enregistrés', (await strokes(page2)) === 5004);
  await page2.keyboard.press('Escape');
  const t0 = Date.now();
  await draw(page2, [[320, 700], [420, 690], [520, 705]]);
  check('écrire sur la page chargée reste possible', (await strokes(page2)) === 5005, `${Date.now() - t0} ms pour le geste simulé`);
  await page2.waitForTimeout(1100);
  console.log('\nDiagnostic (Chromium sans GPU, non représentatif d’un iPad) :\n' + (await page2.locator('.diag').textContent()));
  await page2.screenshot({ path: 'e2e/out/prototype.png' });

  check('aucune erreur JavaScript', errors.length === 0, errors.join(' | '));
} catch (err) {
  check('exécution du scénario', false, String(err));
} finally {
  await browser?.close();
  server.kill();
}

const failed = results.filter((r) => !r).length;
console.log(`\n${results.length - failed}/${results.length} vérifications réussies`);
process.exit(failed ? 1 : 0);
