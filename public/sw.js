const CACHE_NAME = 'clearsplit-shell-v7'
const APP_SHELL = ['/', '/manifest.webmanifest', '/clearsplit-icon-v2.svg', '/clearsplit-icon-v2-192.png', '/clearsplit-icon-v2-512.png', '/apple-touch-icon-v2.png']

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)))
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(
    keys.filter((key) => key.startsWith('clearsplit-shell-') && key !== CACHE_NAME).map((key) => caches.delete(key)),
  )))
  self.clients.claim()
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return

  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).then(async (response) => {
      if (response.ok) {
        const cache = await caches.open(CACHE_NAME)
        await cache.put('/', response.clone())
      }
      return response
    }).catch(() => caches.match('/')))
    return
  }

  const isStaticAsset = url.pathname.startsWith('/assets/')
    || APP_SHELL.includes(url.pathname)
  if (!isStaticAsset) return
  event.respondWith(caches.match(request).then((cached) => cached ?? fetch(request).then(async (response) => {
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME)
      await cache.put(request, response.clone())
    }
    return response
  })))
})
