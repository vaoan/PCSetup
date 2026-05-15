'use strict';
const http = require('http');
const net  = require('net');

const BACKENDS = { '/persistent': 7684, '/fresh': 7685 };

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>Terminal</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #1e1e2e;
      color: #cdd6f4;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100dvh;
      padding: 2rem 1.5rem;
      gap: 1rem;
    }
    h1 {
      font-size: 1.4rem;
      font-weight: 700;
      color: #cba6f7;
      letter-spacing: 0.04em;
      margin-bottom: 0.5rem;
    }
    .btn {
      display: flex;
      flex-direction: column;
      width: 100%;
      max-width: 340px;
      padding: 1.2rem 1.5rem;
      border-radius: 14px;
      text-decoration: none;
      background: #313244;
      border: 2px solid transparent;
      transition: background 0.15s, border-color 0.15s;
      gap: 0.3rem;
    }
    .btn:active { background: #45475a; }
    .btn-label {
      font-size: 1.1rem;
      font-weight: 700;
    }
    .btn-desc {
      font-size: 0.82rem;
      color: #a6adc8;
      font-weight: 400;
    }
    .persistent { border-color: #a6e3a1; }
    .persistent .btn-label { color: #a6e3a1; }
    .fresh      { border-color: #89b4fa; }
    .fresh      .btn-label { color: #89b4fa; }
  </style>
</head>
<body>
  <h1>Terminal</h1>
  <a class="btn persistent" href="/persistent/">
    <span class="btn-label">Persistent</span>
    <span class="btn-desc">Reconnects to existing tmux session — history preserved</span>
  </a>
  <a class="btn fresh" href="/fresh/">
    <span class="btn-label">Fresh</span>
    <span class="btn-desc">New shell every time — clean slate</span>
  </a>
</body>
</html>`;

function backendFor(url) {
  for (const [prefix, port] of Object.entries(BACKENDS)) {
    if (url === prefix || url.startsWith(prefix + '/') || url.startsWith(prefix + '?')) {
      return port;
    }
  }
  return null;
}

// Listens on 127.0.0.1 only — TLS is terminated by the Cloudflare tunnel upstream. nosemgrep
const server = http.createServer((req, res) => { // nosemgrep
  const url = req.url || '/';
  if (url === '/' || url === '') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(LANDING_HTML);
  }
  const port = backendFor(url);
  if (!port) { res.writeHead(404); return res.end('Not found'); }

  const proxy = http.request( // nosemgrep
    { host: '127.0.0.1', port, path: url, method: req.method, headers: req.headers },
    (pr) => { res.writeHead(pr.statusCode, pr.headers); pr.pipe(res); }
  );
  proxy.on('error', () => { res.writeHead(502); res.end('Backend unavailable'); });
  req.pipe(proxy);
});

server.on('upgrade', (req, socket, head) => {
  const port = backendFor(req.url);
  if (!port) { socket.destroy(); return; }

  const conn = net.connect(port, '127.0.0.1', () => {
    let reqLine = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(req.headers)) reqLine += `${k}: ${v}\r\n`;
    reqLine += '\r\n';
    conn.write(reqLine);
    if (head && head.length) conn.write(head);
    conn.pipe(socket);
    socket.pipe(conn);
  });
  conn.on('error', () => socket.destroy());
  socket.on('error', () => conn.destroy());
});

server.listen(7683, '127.0.0.1', () => {
  console.log('[ttyd-proxy] 127.0.0.1:7683  =>  persistent:7684, fresh:7685');
});
