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
  <rect x="9" y="11" width="88" height="70" rx="7" fill="black" opacity="0.22"/>

  <!-- Luna silver bezel -->
  <rect x="4" y="6" width="88" height="70" rx="7" fill="url(#bz)"/>
  <!-- bevel highlights -->
  <rect x="4" y="6" width="88" height="3" rx="3" fill="white" opacity="0.55"/>
  <rect x="4" y="6" width="3" height="70" rx="3" fill="white" opacity="0.35"/>
  <rect x="4" y="73" width="88" height="3" rx="3" fill="black" opacity="0.18"/>

  <!-- XP blue Luna stripe (title-bar feel) -->
  <rect x="4" y="6" width="88" height="15" rx="7" fill="url(#xpbar)"/>
  <rect x="4" y="14" width="88" height="7" fill="url(#xpbar)"/>
  <rect x="4" y="6" width="88" height="5" rx="3" fill="white" opacity="0.22"/>
  <rect x="4" y="20" width="88" height="1" fill="#0a3080" opacity="0.5"/>

  <!-- XP 4-color flag on stripe -->
  <rect x="9"  y="9"  width="6" height="4.5" rx="0.8" fill="#ef3030"/>
  <rect x="16" y="9"  width="6" height="4.5" rx="0.8" fill="#30d830"/>
  <rect x="9"  y="14" width="6" height="4.5" rx="0.8" fill="#2858f0"/>
  <rect x="16" y="14" width="6" height="4.5" rx="0.8" fill="#f0d020"/>

  <!-- screen border -->
  <rect x="11" y="22" width="74" height="44" rx="2" fill="#0a0a14"/>
  <!-- sky -->
  <rect x="12" y="23" width="72" height="42" fill="url(#sky)"/>
  <!-- sun -->
  <circle cx="76" cy="27" r="7" fill="#fff4b0" opacity="0.5"/>
  <circle cx="76" cy="27" r="4" fill="white" opacity="0.75"/>
  <!-- hills -->
  <ellipse cx="48" cy="65" rx="46" ry="16" fill="url(#hl)"/>
  <ellipse cx="14" cy="65" rx="18" ry="12" fill="#52c416"/>
  <ellipse cx="84" cy="65" rx="16" ry="10" fill="#48b810"/>
  <!-- cloud 1 -->
  <ellipse cx="24" cy="32" rx="10" ry="6"  fill="white" opacity="0.95"/>
  <ellipse cx="31" cy="29" rx="9"  ry="7"  fill="white" opacity="0.95"/>
  <ellipse cx="38" cy="32" rx="8"  ry="5"  fill="white" opacity="0.95"/>
  <!-- cloud 2 -->
  <ellipse cx="58" cy="36" rx="7"  ry="4"  fill="white" opacity="0.72"/>
  <ellipse cx="64" cy="34" rx="6"  ry="5"  fill="white" opacity="0.72"/>
  <!-- glare -->
  <path d="M12,23 L60,23 L54,31 L12,31Z" fill="white" opacity="0.055"/>

  <!-- XP taskbar -->
  <rect x="12" y="57" width="72" height="8" fill="url(#tb)"/>
  <rect x="12" y="57" width="72" height="2" fill="#60b0ff" opacity="0.45"/>
  <!-- start button -->
  <rect x="13" y="58" width="20" height="6" rx="2.5" fill="url(#sb)"/>
  <rect x="13" y="58" width="20" height="3" rx="2.5" fill="white" opacity="0.2"/>
  <!-- Windows flag on start button -->
  <rect x="14.5" y="59.5" width="3"   height="2.2" rx="0.4" fill="#ff3030"/>
  <rect x="18"   y="59.5" width="3"   height="2.2" rx="0.4" fill="#30e030"/>
  <rect x="14.5" y="62"   width="3"   height="2.2" rx="0.4" fill="#3060f0"/>
  <rect x="18"   y="62"   width="3"   height="2.2" rx="0.4" fill="#f0d020"/>
  <!-- clock -->
  <rect x="67" y="59" width="16" height="5" rx="1" fill="#0c2870" opacity="0.55"/>

  <!-- power LED (XP blue glow) -->
  <circle cx="85" cy="71" r="4"   fill="#0030a8"/>
  <circle cx="85" cy="71" r="2.5" fill="#2060ff"/>
  <circle cx="84" cy="70" r="1"   fill="white" opacity="0.7"/>

  <!-- stand neck -->
  <rect x="38" y="76" width="20" height="12" rx="1" fill="url(#st)"/>
  <rect x="38" y="76" width="5"  height="12" fill="white" opacity="0.22"/>
  <!-- base -->
  <rect x="18" y="88" width="60" height="10" rx="5" fill="url(#st)"/>
  <rect x="18" y="88" width="60" height="3"  rx="5" fill="white" opacity="0.28"/>
  <rect x="18" y="95" width="60" height="3"  rx="5" fill="black" opacity="0.08"/>

  <!-- WRENCH — glossy amber, -42 deg, bottom-right -->
  <g transform="translate(84,80) rotate(-42)">
    <g transform="translate(4,4)" opacity="0.2">
      <rect x="-12" y="-24" width="24" height="24" rx="5" fill="black"/>
      <rect x="-11" y="0"   width="22" height="52" rx="11" fill="black"/>
    </g>
    <rect x="-12" y="-24" width="24" height="24" rx="5"  fill="url(#wr)"/>
    <rect x="-8"  y="-24" width="16" height="17" rx="3"  fill="#181818"/>
    <rect x="-11" y="0"   width="22" height="52" rx="11" fill="url(#wr)"/>
    <rect x="-9"  y="15"  width="18" height="3.5" rx="1.8" fill="#6a3000" opacity="0.3"/>
    <rect x="-9"  y="24"  width="18" height="3.5" rx="1.8" fill="#6a3000" opacity="0.3"/>
    <rect x="-9"  y="33"  width="18" height="3.5" rx="1.8" fill="#6a3000" opacity="0.3"/>
    <rect x="-11" y="-24" width="7"  height="76" rx="3.5" fill="white" opacity="0.28"/>
    <rect x="-10" y="-22" width="3"  height="72" rx="1.5" fill="white" opacity="0.2"/>
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
