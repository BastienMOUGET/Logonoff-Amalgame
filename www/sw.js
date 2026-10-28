// Logonoff service worker — only what makes the PWA installable and
// opens the shell instantly. The server is local and always on, so the
// network is tried first; the cache is just a fallback for the shell.
// /api/* is never cached (per-user, always live).
const CACHE = "logonoff-v10";
const SHELL = ["/", "/index.html", "/style.css", "/app.js", "/manifest.webmanifest",
               "/favicon.png", "/icon-192.png", "/icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  e.respondWith(
    fetch(e.request)
      .then((resp) => {
        const copy = resp.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy));
        return resp;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("/index.html")))
  );
});

// Click on a Logonoff notification: focus an open window on the page it
// points to, or open one.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "/#today";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) {
      if (new URL(c.url).origin === location.origin && "focus" in c) {
        return c.focus().then((w) => (w && "navigate" in w ? w.navigate(url) : w));
      }
    }
    return self.clients.openWindow(url);
  }));
});
