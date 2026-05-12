'use strict';
const http = require('http');

const FAVICON = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="bz" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#eae6de"/><stop offset="100%" stop-color="#b8b4ac"/></linearGradient>
    <linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#7dcef8"/><stop offset="100%" stop-color="#2e88d0"/></linearGradient>
    <linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#6ed42a"/><stop offset="100%" stop-color="#3a9010"/></linearGradient>
    <linearGradient id="wr" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#ffc84a"/><stop offset="100%" stop-color="#d06a08"/></linearGradient>
    <linearGradient id="st" x1="0" y1="0" x2="1" y2="0"><stop offset="0%" stop-color="#c0bcb4"/><stop offset="40%" stop-color="#dedad2"/><stop offset="100%" stop-color="#b0aca4"/></linearGradient>
  </defs>
  <!-- drop shadow -->
  <rect x="8" y="10" width="88" height="68" rx="6" fill="black" opacity="0.18"/>
  <!-- bezel -->
  <rect x="4" y="6" width="88" height="68" rx="6" fill="url(#bz)"/>
  <!-- bezel top highlight -->
  <rect x="4" y="6" width="88" height="6" rx="6" fill="white" opacity="0.25"/>
  <!-- screen border -->
  <rect x="12" y="13" width="72" height="52" rx="2" fill="#111"/>
  <!-- sky -->
  <rect x="13" y="14" width="70" height="50" fill="url(#sk)"/>
  <!-- rolling hill -->
  <ellipse cx="48" cy="64" rx="45" ry="16" fill="url(#hl)"/>
  <ellipse cx="16" cy="64" rx="20" ry="12" fill="#4ab818"/>
  <!-- cloud 1 -->
  <ellipse cx="26" cy="24" rx="10" ry="6" fill="white" opacity="0.92"/>
  <ellipse cx="33" cy="21" rx="9" ry="7" fill="white" opacity="0.92"/>
  <ellipse cx="40" cy="24" rx="8" ry="5" fill="white" opacity="0.92"/>
  <!-- cloud 2 -->
  <ellipse cx="60" cy="30" rx="7" ry="4" fill="white" opacity="0.72"/>
  <ellipse cx="66" cy="28" rx="6" ry="5" fill="white" opacity="0.72"/>
  <!-- XP taskbar -->
  <rect x="13" y="56" width="70" height="8" fill="#1b5494"/>
  <rect x="13" y="56" width="70" height="2" fill="#2d7fcc" opacity="0.6"/>
  <!-- start button -->
  <rect x="14" y="57" width="16" height="6" rx="2" fill="#3c8a2e"/>
  <rect x="14" y="57" width="16" height="3" rx="2" fill="#50b040" opacity="0.5"/>
  <!-- screen glare -->
  <rect x="13" y="14" width="70" height="8" fill="white" opacity="0.05"/>
  <!-- power LED -->
  <circle cx="87" cy="72" r="3.5" fill="#0050c8"/>
  <circle cx="87" cy="72" r="2" fill="#4488ff"/>
  <!-- stand neck -->
  <rect x="40" y="74" width="16" height="13" rx="1" fill="url(#st)"/>
  <rect x="40" y="74" width="4" height="13" fill="white" opacity="0.18"/>
  <!-- base -->
  <rect x="22" y="87" width="52" height="11" rx="4" fill="url(#st)"/>
  <rect x="22" y="87" width="52" height="3" rx="4" fill="white" opacity="0.22"/>
  <!-- WRENCH — bottom-right, rotated -42deg -->
  <g transform="translate(82,80) rotate(-42)">
    <!-- head outer -->
    <rect x="-11" y="-22" width="22" height="22" rx="5" fill="url(#wr)"/>
    <!-- head cutout (box-end opening) -->
    <rect x="-7" y="-22" width="14" height="15" rx="3" fill="#1a1a1a"/>
    <!-- handle -->
    <rect x="-10" y="0" width="20" height="50" rx="10" fill="url(#wr)"/>
    <!-- grip lines -->
    <rect x="-8" y="14" width="16" height="3" rx="1.5" fill="#7a3a00" opacity="0.35"/>
    <rect x="-8" y="22" width="16" height="3" rx="1.5" fill="#7a3a00" opacity="0.35"/>
    <rect x="-8" y="30" width="16" height="3" rx="1.5" fill="#7a3a00" opacity="0.35"/>
    <!-- highlight -->
    <rect x="-9" y="-22" width="5" height="72" rx="2.5" fill="white" opacity="0.22"/>
  </g>
</svg>`).toString('base64');

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>Dev Tools</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,${FAVICON}">
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
    <a class="card git" href="https://git.ffxivbe.org/repos" target="_blank" rel="noopener">
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
