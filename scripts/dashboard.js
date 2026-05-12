'use strict';
const http = require('http');

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>Dev Tools</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #1e1e2e;
      color: #cdd6f4;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      min-height: 100dvh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 2rem 1.5rem;
      gap: 1.5rem;
    }
    h1 {
      font-size: 1.3rem;
      font-weight: 700;
      color: #cba6f7;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }
    .grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 1rem;
      width: 100%;
      max-width: 420px;
    }
    a.card {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.5rem;
      padding: 1.5rem 0.75rem 1.25rem;
      background: #313244;
      border-radius: 16px;
      border: 2px solid transparent;
      text-decoration: none;
      transition: background 0.12s;
    }
    a.card:active { background: #45475a; }
    .icon {
      font-size: 1.4rem;
      font-family: 'Courier New', monospace;
      font-weight: 700;
      letter-spacing: -0.05em;
    }
    .name {
      font-size: 1rem;
      font-weight: 700;
    }
    .desc {
      font-size: 0.73rem;
      color: #a6adc8;
      text-align: center;
      line-height: 1.4;
    }
    .console  { border-color: #f38ba8; }
    .console  .icon, .console  .name { color: #f38ba8; }
    .code     { border-color: #89b4fa; }
    .code     .icon, .code     .name { color: #89b4fa; }
    .terminal { border-color: #a6e3a1; }
    .terminal .icon, .terminal .name { color: #a6e3a1; }
    .ssh      { border-color: #f9e2af; }
    .ssh      .icon, .ssh      .name { color: #f9e2af; }
    .git      { border-color: #fab387; }
    .git      .icon, .git      .name { color: #fab387; }
  </style>
</head>
<body>
  <h1>Dev Tools</h1>
  <div class="grid">
    <a class="card console" href="https://console.ffxivbe.org" target="_blank" rel="noopener">
      <span class="icon">&gt;_</span>
      <span class="name">Console</span>
      <span class="desc">SSH presets via sshwifty</span>
    </a>
    <a class="card code" href="https://code.ffxivbe.org" target="_blank" rel="noopener">
      <span class="icon">&lt;/&gt;</span>
      <span class="name">Code</span>
      <span class="desc">VS Code in browser</span>
    </a>
    <a class="card terminal" href="https://ttyd.ffxivbe.org" target="_blank" rel="noopener">
      <span class="icon">$_</span>
      <span class="name">Terminal</span>
      <span class="desc">Mobile tmux terminal</span>
    </a>
    <a class="card ssh" href="https://dev.ffxivbe.org" target="_blank" rel="noopener">
      <span class="icon">ssh</span>
      <span class="name">SSH</span>
      <span class="desc">Direct SSH to WSL</span>
    </a>
    <a class="card git" href="https://git.ffxivbe.org" target="_blank" rel="noopener">
      <span class="icon">⎇</span>
      <span class="name">Git</span>
      <span class="desc">Visual branch browser</span>
    </a>
  </div>
</body>
</html>`;

// nosemgrep - listens on 127.0.0.1 only, TLS terminated by Cloudflare tunnel upstream
http.createServer((req, res) => { // nosemgrep
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(HTML);
}).listen(7686, '127.0.0.1', () => {
  console.log('[dashboard] 127.0.0.1:7686');
});
