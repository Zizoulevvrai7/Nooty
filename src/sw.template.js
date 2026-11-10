/* Service worker de Nooty : met l'application en cache pour un usage hors connexion.
   Ne traite que les requêtes GET de même origine ; aucune donnée de note ne transite ici. */
const CACHE = 'nooty-__VERSION__';
const FILES = "__FILES__";

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(FILES)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('nooty-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) return;
  event.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const hit = await cache.match(request, { ignoreSearch: true, ignoreVary: true });
      if (hit) return hit;
      if (request.mode === 'navigate') {
        const shell = await cache.match('./', { ignoreVary: true });
        if (shell) return shell;
      }
      return fetch(request);
    }),
  );
});
