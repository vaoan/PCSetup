// console-pwa-sw.js — minimal service worker for the "SSH Console" PWA.
//
// Its ONLY job is to make console.ffxiv.be installable in Chrome: the
// browser requires a registered service worker with a fetch handler before it
// offers "Install app". We deliberately do NO caching — sshwifty is a live SSH
// session, so every request must hit the network (and carry the Cloudflare
// Access cookie). This handler is a transparent pass-through.
'use strict';

self.addEventListener('install', () => {
  // Activate immediately on first install / update.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  // Pass-through: no offline cache, no interception. Present only to satisfy
  // Chrome's installability requirement.
  event.respondWith(fetch(event.request));
});
