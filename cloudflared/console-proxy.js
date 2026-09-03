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
const os   = require('os');
const path = require('path');

const PROXY_PORT    = 7681;
const UPSTREAM_PORT = 7682;

// Resolve, don't hardcode: the profile name is not always "Heiner" (this machine
// is C:\Users\HeinerPC). setup-console-wsl.sh generates these keys into
// /mnt/c/Users/$WIN_USER/Documents/Cloudflare/sshwifty/keys, and the PowerShell
// scripts all use "$env:USERPROFILE\Documents\Cloudflare" — os.homedir() is the
// same directory, so all three agree on any profile.
const KEY_DIR = path.join(os.homedir(), 'Documents', 'Cloudflare', 'sshwifty', 'keys');

const PRIVATE_KEY_FILES = {
  'WSL Terminal (Persistent)': 'wsl-terminal',
  'WSL Shell (Fresh)': 'wsl-shell',
  'Libra (Persistent)': 'libra',
  'Libra (Fresh)': 'libra-shell',
  'Eclipse-con (Persistent)': 'eclipse-con',
  'Eclipse-con (Fresh)': 'eclipse-con-shell',
  'Puck (Persistent)': 'puck',
  'Puck (Fresh)': 'puck-shell',
  'AeleOS (Persistent)': 'aeleos',
  'AeleOS (Fresh)': 'aeleos-shell',
  'PCSetup (Persistent)': 'pcsetup',
  'PCSetup (Fresh)': 'pcsetup-shell',
};

// One unreadable key must not take the whole proxy down. These are read at module
// load and only ever get JSON-serialized into the page for autofill, so a missing
// entry costs that one preset its key — not console.ffxiv.be entirely.
const privateKeys = {};
const missingKeys = [];
for (const [title, keyName] of Object.entries(PRIVATE_KEY_FILES)) {
  const keyPath = path.join(KEY_DIR, keyName);
  try {
    privateKeys[title] = fs.readFileSync(keyPath, 'utf8');
  } catch (err) {
    missingKeys.push(`${title} -> ${keyPath} (${err.code || err.message})`);
  }
}
if (missingKeys.length) {
  console.error(`[console-proxy] WARNING: ${missingKeys.length}/${Object.keys(PRIVATE_KEY_FILES).length} preset key(s) unreadable; those presets will not autofill:`);
  for (const m of missingKeys) console.error(`[console-proxy]   - ${m}`);
  console.error('[console-proxy] Run setup-console-wsl.sh (generates the keys), then setup-console-windows.ps1.');
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

// --- Extra "special key": Enter -------------------------------------------
// SSHwifty's on-screen special-keys menu (click the session tab) ships
// Escape / Tab / Insert / Delete under "Misc Keys" and has no Enter, which
// makes the menu useless on a phone for anything that needs a newline.
// The list is baked into a minified asset bundle, not into the HTML, so it is
// patched here on the way through: find the "Tab" entry and clone it as
// "Enter" (keyCode/which 13) immediately after it.
//
// The clone is derived from the matched Tab entry rather than written out as a
// literal, so it keeps whatever minifier style the bundle uses (`!1` vs
// `false`) and survives an sshwifty upgrade that changes it. If the shape ever
// stops matching, the regex simply doesn't fire — the bundle is passed through
// untouched and the menu is merely missing Enter again, never broken.
const TAB_KEY_ENTRY = /\["Tab",\s*\{[^{}]*?keyCode:\s*9\b[^{}]*?\}\]/;

function patchSpecialKeys(js) {
  if (/\["Enter",\s*\{/.test(js)) return js;   // already patched / upstream added it
  const m = js.match(TAB_KEY_ENTRY);
  if (!m) return js;
  const enter = m[0]
    .replace('["Tab",', '["Enter",')
    .replace('code:"Tab"', 'code:"Enter"')
    .replace('key:"Tab"', 'key:"Enter"')
    .replace(/keyCode:\s*9\b/, 'keyCode:13')
    .replace(/which:\s*9\b/, 'which:13');
  return js.replace(TAB_KEY_ENTRY, m[0] + ',' + enter);
}

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

    // JS bundles: buffer only so the special-keys list can gain an Enter key.
    if (ct.includes('javascript')) {
      const jsChunks = [];
      proxyRes.on('data', chunk => jsChunks.push(chunk));
      proxyRes.on('end', () => {
        const original = Buffer.concat(jsChunks).toString('utf8');
        const patched = patchSpecialKeys(original);
        if (patched === original) {
          const headers = copyHeaders(proxyRes.headers, { 'content-length': jsChunks.reduce((n, c) => n + c.length, 0) });
          delete headers['transfer-encoding'];
          res.writeHead(proxyRes.statusCode, headers);
          res.end(Buffer.concat(jsChunks));
          return;
        }
        const body = Buffer.from(patched, 'utf8');
        // The asset filename is content-hashed upstream and does NOT change when
        // we patch it, so sshwifty's 60-day max-age would pin the unpatched copy
        // in every browser that already has it. Force revalidation instead.
        const headers = copyHeaders(proxyRes.headers, {
          'content-length': body.length,
          'cache-control': 'no-cache',
        });
        delete headers['content-encoding'];
        delete headers['transfer-encoding'];
        delete headers['etag'];
        res.writeHead(proxyRes.statusCode, headers);
        res.end(body);
      });
      return;
    }

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
