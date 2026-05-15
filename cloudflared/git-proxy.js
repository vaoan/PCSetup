'use strict';
const http = require('http');
const net  = require('net');
const fs   = require('fs');
const path = require('path');

const UNGIT_PORT  = 7688;
const PROXY_PORT  = 7687;
const GITHUB_ROOT = '/mnt/z/Github';

function repoList() {
  try {
    return fs.readdirSync(GITHUB_ROOT, { withFileTypes: true })
      .filter(e => e.isDirectory() && /^[^/\\]+$/.test(e.name) && fs.existsSync(path.join(GITHUB_ROOT, e.name, '.git'))) // nosemgrep - e.name from readdirSync never contains separators; regex guards defensively
      .map(e => e.name)
      .sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  } catch { return []; }
}

function landingPage() {
  const repos = repoList();
  const cards = repos.length
    ? repos.map(name => `
    <a class="card" href="/#/repository?path=${encodeURIComponent(GITHUB_ROOT + '/' + name)}">
      <span class="icon">⎇</span>
      <span class="name">${name}</span>
    </a>`).join('')
    : '<p class="empty">No git repos found in ' + GITHUB_ROOT + '</p>';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>Git Repos</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #1e1e2e; color: #cdd6f4;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      min-height: 100dvh; display: flex; flex-direction: column;
      align-items: center; justify-content: center;
      padding: 2rem 1.5rem; gap: 1.5rem;
    }
    h1 { font-size: 1.3rem; font-weight: 700; color: #fab387;
         letter-spacing: 0.06em; text-transform: uppercase; }
    .grid { display: grid; grid-template-columns: 1fr 1fr;
            gap: 1rem; width: 100%; max-width: 420px; }
    a.card {
      display: flex; flex-direction: column; align-items: center;
      gap: 0.5rem; padding: 1.25rem 0.75rem 1rem;
      background: #313244; border-radius: 16px;
      border: 2px solid #fab387; text-decoration: none;
      transition: background 0.12s;
    }
    a.card:active { background: #45475a; }
    .icon { font-size: 1.4rem; }
    .name { font-size: 0.95rem; font-weight: 700; color: #fab387;
            text-align: center; word-break: break-all; }
    .empty { color: #6c7086; font-size: 0.9rem; }
    .back { font-size: 0.8rem; color: #6c7086; text-decoration: none; align-self: flex-start; }
    .back:active { color: #cdd6f4; }
  </style>
</head>
<body>
  <a class="back" href="https://tools.ffxivbe.org">← tools</a>
  <h1>Git Repos</h1>
  <div class="grid">${cards}</div>
</body>
</html>`;
}

// nosemgrep - listens on 127.0.0.1 only, TLS terminated by Cloudflare tunnel upstream
const server = http.createServer((req, res) => { // nosemgrep
  if (req.url === '/repos' || req.url === '/repos/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(landingPage());
    return;
  }
  // proxy everything else (including /) to ungit so hash routing works
  const opts = { hostname: '127.0.0.1', port: UNGIT_PORT, path: req.url, // nosemgrep - localhost only, TLS terminated by Cloudflare
                 method: req.method, headers: req.headers };
  const proxy = http.request(opts, r => { // nosemgrep - localhost only, TLS terminated by Cloudflare
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  proxy.on('error', () => res.end());
  req.pipe(proxy);
});

// WebSocket passthrough to ungit
server.on('upgrade', (req, socket, head) => {
  const conn = net.connect(UNGIT_PORT, '127.0.0.1', () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(req.headers)) raw += `${k}: ${v}\r\n`;
    raw += '\r\n';
    conn.write(raw);
    if (head && head.length) conn.write(head);
    conn.pipe(socket);
    socket.pipe(conn);
  });
  conn.on('error', () => socket.destroy());
  socket.on('error', () => conn.destroy());
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  console.log(`[git-proxy] 127.0.0.1:${PROXY_PORT} -> ungit:${UNGIT_PORT}`);
});
