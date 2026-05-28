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
const INJECTION   = `\n<script>\nwindow.__SSHWIFTY_PRIVATE_KEYS__ = ${JSON.stringify(privateKeys)};\n</script>\n<script>\n${launcherSrc}\n</script>\n`;

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

      if (html.includes('</body>')) {
        html = html.replace('</body>', INJECTION + '</body>');
      } else {
        html += INJECTION;
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
