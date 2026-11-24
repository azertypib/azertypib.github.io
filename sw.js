// Service worker de l'appli EDT : affiche les notifications (rappels à 18h, annonces) et ouvre l'appli quand on les touche.
// Pas de cache : l'appli se charge toujours en ligne comme avant.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch { m = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(m.title || "EDT", {
    body: m.body || "", icon: "icon.png", badge: "icon.png", data: { url: m.url || "./" }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil((async () => {
    const l = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of l) if ("focus" in c) return c.focus();
    return self.clients.openWindow(e.notification.data?.url || "./");
  })());
});
