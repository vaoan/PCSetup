// console-proxy.js — SSHwifty launcher proxy
// Listens on 127.0.0.1:7681, forwards to SSHwifty on 127.0.0.1:7682
// Injects launcher.js into HTML responses so the quick-connect panel appears.
//
// Security note: HTTP on loopback (127.0.0.1) is intentional.
// TLS is terminated externally by the Cloudflare tunnel — no cleartext ever
// leaves this machine.
'use strict';

const http = require('http');
const net  = require('net');
const fs   = require('fs');
const path = require('path');

const PROXY_PORT    = 7681;
const UPSTREAM_PORT = 7682;

const PRIVATE_KEY_FILES = {
  'WSL Terminal (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/wsl-terminal',
  'WSL Shell (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/wsl-shell',
  'Candystore (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/candystore',
  'Candystore (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/candystore-shell',
  'Eclipse-con (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/eclipse-con',
  'Eclipse-con (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/eclipse-con-shell',
  'Puck (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/puck',
  'Puck (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/puck-shell',
  'AeleOS (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/aeleos',
  'AeleOS (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/aeleos-shell',
  'PCSetup (Persistent)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/pcsetup',
  'PCSetup (Fresh)': 'C:/Users/Heiner/Documents/Cloudflare/sshwifty/keys/pcsetup-shell',
};

function readPrivateKey(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

const privateKeys = {};
for (const [title, relPath] of Object.entries(PRIVATE_KEY_FILES)) {
  privateKeys[title] = readPrivateKey(relPath);
}

const launcherSrc = fs.readFileSync(path.join(__dirname, 'console-launcher.js'), 'utf8');

// PWA bits injected into every HTML page so Chrome offers "Install app".
// The manifest + service worker are served locally by this proxy (see PWA_ASSETS).
//
// IMPORTANT — this MUST go in <head>, not <body>. Chrome only honours the
// <link rel="manifest"> when it is in the document head; injected before </body>
// it is silently ignored (getAppManifest returns no manifest → no install icon).
//
// NOTE: crossorigin="use-credentials" is also REQUIRED here. This site sits behind
// Cloudflare Access, and Chrome fetches the manifest (and its icons) WITHOUT
// credentials by default — Access then 302-redirects those requests to its login
// page, the manifest fails to parse, and no "Install app" is offered. With
// use-credentials the fetches carry the CF_Authorization cookie and succeed.
const PWA_HEAD_INJECTION =
  '\n<link rel="manifest" href="/console-pwa-manifest.webmanifest" crossorigin="use-credentials">' +
  '\n<meta name="theme-color" content="#1e1e2e">' +
  '\n<link rel="apple-touch-icon" href="/console-pwa-icon-192.png">\n';

// Scripts are fine at end of <body>: service-worker registration + the launcher.
const BODY_INJECTION =
  "\n<script>if('serviceWorker' in navigator){navigator.serviceWorker.register('/console-pwa-sw.js').catch(function(e){console.warn('SW registration failed',e);});}</script>\n" +
  `\n<script>\nwindow.__SSHWIFTY_PRIVATE_KEYS__ = ${JSON.stringify(privateKeys)};\n</script>\n<script>\n${launcherSrc}\n</script>\n`;

// Static PWA assets served directly by this proxy (never forwarded to sshwifty).
const PWA_ASSETS = {
  '/console-pwa-manifest.webmanifest': { file: 'console-pwa-manifest.webmanifest', type: 'application/manifest+json; charset=utf-8' },
  '/console-pwa-sw.js':                { file: 'console-pwa-sw.js',                type: 'application/javascript; charset=utf-8'  },
  '/console-pwa-icon-192.png':         { file: 'console-pwa-icon-192.png',         type: 'image/png' },
  '/console-pwa-icon-512.png':         { file: 'console-pwa-icon-512.png',         type: 'image/png' },
};

function copyHeaders(src, overrides) {
  const out = {};
  for (const key of Object.keys(src)) {
    out[key] = src[key];
  }
  for (const key of Object.keys(overrides)) {
    out[key] = overrides[key];
  }
  return out;
}

const server = http.createServer((req, res) => { // nosemgrep
  // Serve local PWA assets (manifest, service worker, icons) without forwarding
  // to sshwifty. Match on pathname so query strings don't defeat the lookup.
  const pathname = (req.url || '/').split('?')[0];
  const asset = PWA_ASSETS[pathname];
  if (asset) {
    try {
      const body = fs.readFileSync(path.join(__dirname, asset.file));
      res.writeHead(200, {
        'content-type': asset.type,
        'content-length': body.length,
        'cache-control': 'no-cache',
        'service-worker-allowed': '/',
      });
      res.end(body);
    } catch (err) {
      res.writeHead(500);
      res.end('PWA asset error: ' + err.message);
    }
    return;
  }

  const upstreamHeaders = copyHeaders(req.headers, { 'accept-encoding': 'identity' });

  const options = { // nosemgrep
    hostname: '127.0.0.1',
    port: UPSTREAM_PORT,
    path: req.url,
    method: req.method,
    headers: upstreamHeaders,
  };

  const proxyReq = http.request(options, (proxyRes) => { // nosemgrep
    const ct = proxyRes.headers['content-type'] || '';

    if (!ct.includes('text/html')) {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
      return;
    }

    const chunks = [];
    proxyRes.on('data', chunk => chunks.push(chunk));
    proxyRes.on('end', () => {
      let html = Buffer.concat(chunks).toString('utf8');

      // Strip sshwifty's own manifest link so OUR "SSH Console" manifest is the
      // one Chrome uses — the browser honours the FIRST <link rel="manifest">.
      html = html.replace(/<link\b[^>]*\brel=["']manifest["'][^>]*>/gi, '');
      // Rename the home-screen / task-switcher title away from "Sshwifty".
      html = html.replace(
        /(<meta\b[^>]*\bname=["'](?:apple-mobile-web-app-title|application-name)["'][^>]*\bcontent=)["'][^"']*["']/gi,
        '$1"SSH Console"'
      );

      // PWA manifest + metas MUST land in <head> (Chrome ignores a body manifest
      // link). Prefer inserting before </head>; fall back to after <head>.
      if (html.includes('</head>')) {
        html = html.replace('</head>', PWA_HEAD_INJECTION + '</head>');
      } else if (/<head[^>]*>/i.test(html)) {
        html = html.replace(/(<head[^>]*>)/i, '$1' + PWA_HEAD_INJECTION);
      } else {
        html = PWA_HEAD_INJECTION + html;
      }

      // Scripts (SW registration + launcher) go at end of <body>.
      if (html.includes('</body>')) {
        html = html.replace('</body>', BODY_INJECTION + '</body>');
      } else {
        html += BODY_INJECTION;
      }

      const body = Buffer.from(html, 'utf8');
      const headers = copyHeaders(proxyRes.headers, { 'content-length': body.length });
      delete headers['content-encoding'];
      delete headers['transfer-encoding'];

      res.writeHead(proxyRes.statusCode, headers);
      res.end(body);
    });
  });

  proxyReq.on('error', err => {
    if (!res.headersSent) {
      res.writeHead(502);
      res.end('Proxy error: ' + err.message);
    }
  });

  req.pipe(proxyReq);
});

// WebSocket upgrades — raw TCP tunnel
server.on('upgrade', (req, clientSocket, head) => {
  const upstream = net.connect(UPSTREAM_PORT, '127.0.0.1', () => {
    let handshake = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
    for (const [k, v] of Object.entries(req.headers)) {
      handshake += `${k}: ${v}\r\n`;
    }
    handshake += '\r\n';

    upstream.write(handshake);
    if (head && head.length > 0) upstream.write(head);

    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  upstream.on('error',     () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
  upstream.on('close',     () => clientSocket.destroy());
  clientSocket.on('close', () => upstream.destroy());
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  process.stderr.write(`[proxy] 127.0.0.1:${PROXY_PORT}  =>  SSHwifty on ${UPSTREAM_PORT}\n`);
});
