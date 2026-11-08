// Minimal service worker so the page can be installed as an app.
// Caches nothing: our own files are always re-checked with the server
// ("no-cache"), so an installed app never starts on an old version.
// API calls (ingress) pass straight through.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin || url.pathname.includes("/api/")) return;
  e.respondWith(fetch(new Request(req, { cache: "no-cache" })).catch(() => fetch(req)));
});
