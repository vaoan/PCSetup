'use strict';
const http = require('http');

const FAVICON = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="bz" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#f8f4ec"/><stop offset="35%" stop-color="#e4e0d8"/>
      <stop offset="70%" stop-color="#ccc8c0"/><stop offset="100%" stop-color="#a4a09a"/>
    </linearGradient>
    <linearGradient id="xpbar" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#1c6cd8"/><stop offset="50%" stop-color="#0e50b4"/>
      <stop offset="100%" stop-color="#0a3e96"/>
    </linearGradient>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#a8e4ff"/><stop offset="50%" stop-color="#48aaee"/>
      <stop offset="100%" stop-color="#1870cc"/>
    </linearGradient>
    <linearGradient id="hl" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#7ee830"/><stop offset="100%" stop-color="#2e8808"/>
    </linearGradient>
    <linearGradient id="tb" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#3484dc"/><stop offset="100%" stop-color="#0c3080"/>
    </linearGradient>
    <linearGradient id="sb" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#68d040"/><stop offset="50%" stop-color="#30960c"/>
      <stop offset="100%" stop-color="#1e7004"/>
    </linearGradient>
    <linearGradient id="wr" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffe060"/><stop offset="40%" stop-color="#f08818"/>
      <stop offset="100%" stop-color="#a84800"/>
    </linearGradient>
    <linearGradient id="st" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#aaa8a0"/><stop offset="35%" stop-color="#dedad2"/>
      <stop offset="100%" stop-color="#a8a49c"/>
    </linearGradient>
  </defs>

  <!-- shadow -->
  <rect x="7" y="7" width="120" height="90" rx="10" fill="black" opacity="0.22"/>

  <!-- Luna silver bezel -->
  <rect x="2" y="2" width="120" height="90" rx="8" fill="url(#bz)"/>
  <!-- bevel highlights -->
  <rect x="2" y="2" width="120" height="4" rx="4" fill="white" opacity="0.55"/>
  <rect x="2" y="2" width="4" height="90" rx="4" fill="white" opacity="0.35"/>
  <rect x="2" y="89" width="120" height="3" rx="3" fill="black" opacity="0.18"/>

  <!-- XP blue Luna stripe (title-bar feel) -->
  <rect x="2" y="2" width="120" height="21" rx="8" fill="url(#xpbar)"/>
  <rect x="2" y="14" width="120" height="9" fill="url(#xpbar)"/>
  <rect x="2" y="2" width="120" height="6" rx="4" fill="white" opacity="0.22"/>
  <rect x="2" y="22" width="120" height="1" fill="#0a3080" opacity="0.5"/>

  <!-- XP 4-color flag on stripe -->
  <rect x="10"  y="5"  width="8" height="6" rx="1" fill="#ef3030"/>
  <rect x="19"  y="5"  width="8" height="6" rx="1" fill="#30d830"/>
  <rect x="10"  y="12" width="8" height="6" rx="1" fill="#2858f0"/>
  <rect x="19"  y="12" width="8" height="6" rx="1" fill="#f0d020"/>

  <!-- screen border -->
  <rect x="12" y="24" width="98" height="56" rx="2" fill="#0a0a14"/>
  <!-- sky -->
  <rect x="13" y="25" width="96" height="54" fill="url(#sky)"/>
  <!-- sun -->
  <circle cx="97" cy="30" r="10" fill="#fff4b0" opacity="0.5"/>
  <circle cx="97" cy="30" r="6"  fill="white" opacity="0.75"/>
  <!-- hills -->
  <ellipse cx="61"  cy="79" rx="60" ry="20" fill="url(#hl)"/>
  <ellipse cx="17"  cy="79" rx="22" ry="14" fill="#52c416"/>
  <ellipse cx="107" cy="79" rx="20" ry="12" fill="#48b810"/>
  <!-- cloud 1 -->
  <ellipse cx="30" cy="33" rx="14" ry="8"  fill="white" opacity="0.95"/>
  <ellipse cx="42" cy="30" rx="12" ry="9"  fill="white" opacity="0.95"/>
  <ellipse cx="52" cy="34" rx="11" ry="7"  fill="white" opacity="0.95"/>
  <!-- cloud 2 -->
  <ellipse cx="74" cy="38" rx="10" ry="6"  fill="white" opacity="0.72"/>
  <ellipse cx="84" cy="35" rx="8"  ry="7"  fill="white" opacity="0.72"/>
  <!-- glare -->
  <path d="M13,25 L77,25 L69,37 L13,37Z" fill="white" opacity="0.055"/>

  <!-- XP taskbar -->
  <rect x="13" y="69" width="96" height="10" fill="url(#tb)"/>
  <rect x="13" y="69" width="96" height="3"  fill="#60b0ff" opacity="0.45"/>
  <!-- start button -->
  <rect x="14" y="70" width="27" height="8" rx="3" fill="url(#sb)"/>
  <rect x="14" y="70" width="27" height="4" rx="3" fill="white" opacity="0.2"/>
  <!-- Windows flag on start button -->
  <rect x="16"   y="71.5" width="4.5" height="3"   rx="0.5" fill="#ff3030"/>
  <rect x="21.5" y="71.5" width="4.5" height="3"   rx="0.5" fill="#30e030"/>
  <rect x="16"   y="75.5" width="4.5" height="3"   rx="0.5" fill="#3060f0"/>
  <rect x="21.5" y="75.5" width="4.5" height="3"   rx="0.5" fill="#f0d020"/>
  <!-- clock -->
  <rect x="90" y="71" width="17" height="6" rx="1" fill="#0c2870" opacity="0.55"/>

  <!-- power LED (XP blue glow) -->
  <circle cx="116" cy="87" r="5"   fill="#0030a8"/>
  <circle cx="116" cy="87" r="3"   fill="#2060ff"/>
  <circle cx="115" cy="86" r="1.2" fill="white" opacity="0.7"/>

  <!-- stand neck -->
  <rect x="48" y="92" width="28" height="14" rx="1" fill="url(#st)"/>
  <rect x="48" y="92" width="7"  height="14" fill="white" opacity="0.22"/>
  <!-- base -->
  <rect x="18" y="106" width="90" height="12" rx="6" fill="url(#st)"/>
  <rect x="18" y="106" width="90" height="3"  rx="6" fill="white" opacity="0.28"/>
  <rect x="18" y="115" width="90" height="3"  rx="6" fill="black" opacity="0.08"/>

  <!-- WRENCH — glossy amber, -42 deg, bottom-right -->
  <g transform="translate(80,87) rotate(-42)">
    <g transform="translate(5,5)" opacity="0.2">
      <rect x="-14" y="-28" width="28" height="28" rx="6" fill="black"/>
      <rect x="-13" y="0"   width="26" height="56" rx="13" fill="black"/>
    </g>
    <rect x="-14" y="-28" width="28" height="28" rx="6"  fill="url(#wr)"/>
    <rect x="-9"  y="-28" width="18" height="20" rx="4"  fill="#181818"/>
    <rect x="-13" y="0"   width="26" height="56" rx="13" fill="url(#wr)"/>
    <rect x="-10" y="16"  width="20" height="4"  rx="2"  fill="#6a3000" opacity="0.3"/>
    <rect x="-10" y="28"  width="20" height="4"  rx="2"  fill="#6a3000" opacity="0.3"/>
    <rect x="-10" y="40"  width="20" height="4"  rx="2"  fill="#6a3000" opacity="0.3"/>
    <rect x="-13" y="-28" width="8"  height="88" rx="4"  fill="white" opacity="0.28"/>
    <rect x="-12" y="-26" width="3"  height="84" rx="1.5" fill="white" opacity="0.2"/>
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
