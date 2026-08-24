const CACHE = 'notify-shell-v3';
const SHELL = ['/', '/styles.css', '/notify_web.js', '/manifest.webmanifest'];
self.addEventListener('install', (event) => event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL))));
self.addEventListener('activate', (event) => event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))));
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== location.origin) return;
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    const payload = event.data?.json() || {};
    if (payload.event === 'subscription_expiring') {
      await self.registration.showNotification('Notify', {body:'Your browser notification subscription will expire soon.', tag:'notify-subscription-expiring', data:{url:'/'}});
      return;
    }
    if (payload.event !== 'message' || !payload.message) return;
    const message = payload.message;
    const channel = new BroadcastChannel('notify-webpush');
    channel.postMessage(payload);
    channel.close();
    const actions = (message.actions || []).filter((action) => action.action === 'view').slice(0, 2).map((action, index) => ({action:`view-${index}`, title:action.label}));
    await self.registration.showNotification(message.title || message.topic || 'Notify', {
      body:message.message || '',
      icon:message.icon || undefined,
      tag:message.id,
      renotify:false,
      actions,
      data:{url:message.click || payload.subscription_id || '/', actions:message.actions || []},
    });
  })());
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    let target = event.notification.data?.url || '/';
    if (event.action?.startsWith('view-')) {
      const index = Number(event.action.slice(5));
      target = event.notification.data?.actions?.[index]?.url || target;
    }
    const windows = await clients.matchAll({type:'window', includeUncontrolled:true});
    const sameOrigin = new URL(target, location.origin).origin === location.origin;
    const existing = sameOrigin && windows.find((client) => new URL(client.url).origin === location.origin);
    if (existing) { await existing.navigate(target); return existing.focus(); }
    return clients.openWindow(target);
  })());
});
