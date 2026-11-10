import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import type { Plugin } from 'vite';
import { defineConfig } from 'vitest/config';

function listFiles(dir: string, root = dir): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? listFiles(full, root) : [relative(root, full).replace(/\\/g, '/')];
  });
}

/**
 * Génère `sw.js` après le build : liste exacte des fichiers à mettre en cache et
 * version dérivée de leur contenu. Aucune dépendance d'exécution.
 */
function offlineServiceWorker(): Plugin {
  let outDir = 'dist';
  return {
    name: 'nooty-offline-sw',
    apply: 'build',
    configResolved(config) {
      outDir = config.build.outDir;
    },
    closeBundle() {
      const files = listFiles(outDir).filter((f) => f !== 'sw.js').sort();
      const hash = createHash('sha256');
      for (const f of files) hash.update(f).update(readFileSync(join(outDir, f)));
      const version = hash.digest('hex').slice(0, 12);
      const template = readFileSync('src/sw.template.js', 'utf8');
      writeFileSync(
        join(outDir, 'sw.js'),
        template.replace('__VERSION__', version).replace('"__FILES__"', JSON.stringify(['./', ...files])),
      );
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [offlineServiceWorker()],
  build: { target: 'es2022' },
  test: { include: ['tests/**/*.test.ts'] },
});
