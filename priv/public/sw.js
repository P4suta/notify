const CACHE = 'notify-shell-v4';
const SHELL = [
  '/',
  '/styles.css',
  '/notify_web.js',
  '/manifest.webmanifest',
  '/icon.svg',
  '/icon-192.png',
  '/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)),
      ))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== location.origin) return;

  event.respondWith((async () => {
    try {
      return await fetch(event.request);
    } catch (error) {
      if (event.request.mode === 'navigate') {
        const shell = await caches.match('/');
        if (shell) return shell;
      }
      const cached = await caches.match(event.request);
      if (cached) return cached;
      throw error;
    }
  })());
});

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    const payload = event.data?.json() || {};
    if (payload.event === 'subscription_expiring') {
      await self.registration.showNotification('Notify', {
        body: 'Your browser notification subscription will expire soon.',
        tag: 'notify-subscription-expiring',
        data: { url: '/' },
      });
      return;
    }
    if (payload.event !== 'message' || !payload.message) return;
    const message = payload.message;
    const channel = new BroadcastChannel('notify-webpush');
    channel.postMessage(payload);
    channel.close();
    const actions = (message.actions || [])
      .filter((action) => action.action === 'view')
      .slice(0, 2)
      .map((action, index) => ({ action: `view-${index}`, title: action.label }));
    await self.registration.showNotification(
      message.title || message.topic || 'Notify',
      {
        body: message.message || '',
        icon: message.icon || '/icon-192.png',
        badge: '/icon-192.png',
        tag: message.id,
        renotify: false,
        actions,
        data: {
          url: message.click || payload.subscription_id || '/',
          actions: message.actions || [],
        },
      },
    );
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
    const windows = await clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    const sameOrigin = new URL(target, location.origin).origin === location.origin;
    const existing = sameOrigin
      && windows.find((client) => new URL(client.url).origin === location.origin);
    if (existing) {
      await existing.navigate(target);
      return existing.focus();
    }
    return clients.openWindow(target);
  })());
});
