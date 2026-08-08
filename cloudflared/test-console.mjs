import { chromium } from 'playwright';
import http from 'http';
import net from 'net';

// Tiny relay on port 7690: forwards to console-proxy (7681) with Host: console.ffxiv.be
// so sshwifty accepts the request without needing CF Access.
const relay = http.createServer((req, res) => {
  const opts = {
    hostname: '127.0.0.1', port: 7681,
    path: req.url, method: req.method,
    headers: { ...req.headers, host: 'console.ffxiv.be' }
  };
  const proxy = http.request(opts, pr => { // nosemgrep
    res.writeHead(pr.statusCode, pr.headers);
    pr.pipe(res);
  });
  proxy.on('error', () => { res.writeHead(502); res.end(); });
  req.pipe(proxy);
});
relay.on('upgrade', (req, socket, head) => {
  const conn = net.connect(7681, '127.0.0.1', () => {
    const hdrs = { ...req.headers, host: 'console.ffxiv.be' };
    let hs = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(hdrs)) hs += `${k}: ${v}\r\n`;
    hs += '\r\n';
    conn.write(hs);
    if (head?.length) conn.write(head);
    conn.pipe(socket); socket.pipe(conn);
  });
  conn.on('error', () => socket.destroy());
  socket.on('error', () => conn.destroy());
});
await new Promise(r => relay.listen(7690, '127.0.0.1', r));
console.log('Relay listening on 127.0.0.1:7690 -> 127.0.0.1:7681 (Host: console.ffxiv.be)');

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
page.on('pageerror', e => console.log('[page-error]', e.message));

console.log('\nNavigating to relay...');
try {
  const res = await page.goto('http://127.0.0.1:7690/', { timeout: 20000, waitUntil: 'domcontentloaded' });
  console.log('HTTP status:', res.status());
  console.log('Title:', await page.title());
} catch (e) {
  console.log('Navigation failed:', e.message);
  await browser.close(); relay.close(); process.exit(1);
}

// Wait for sshwifty app to load (#home-hd-title is the logo/trigger)
console.log('Waiting for sshwifty app to load...');
try {
  await page.waitForSelector('#home-hd-title', { timeout: 20000 });
  console.log('App loaded.');
} catch (e) {
  console.log('App did not load:', e.message);
  await page.screenshot({ path: 'console-loaded.png', fullPage: true });
  await browser.close(); relay.close(); process.exit(1);
}
await page.screenshot({ path: 'console-loaded.png', fullPage: true });

const presetTitles = [
  'Libra (Persistent)',
  'Libra (Fresh)',
  'Eclipse-con (Persistent)',
  'Eclipse-con (Fresh)',
  'Puck (Persistent)',
  'Puck (Fresh)',
  'AeleOS (Persistent)',
  'AeleOS (Fresh)',
  'PCSetup (Persistent)',
  'PCSetup (Fresh)',
];

console.log('\nVerifying quick-connect buttons...');
await page.click('#home-hd-title');
await page.waitForTimeout(500);
await page.evaluate(() => {
  const popup = document.getElementById('ql-popup');
  if (popup) popup.style.display = 'block';
});
await page.waitForTimeout(300);

for (const title of presetTitles) {
  const btn = page.locator(`[title="${title}"]`);
  const found = await btn.count() > 0;
  console.log(`${title} button found:`, found);
  if (!found) {
    const allText = await page.evaluate(() =>
      [...document.querySelectorAll('button,a,li,h1,h2,h3,[class*="item"],[class*="panel"],[class*="btn"]')]
        .map(e => e.textContent?.trim()).filter(t => t && t.length < 80)
        .filter((v,i,a) => a.indexOf(v) === i)
    );
    console.log('Visible elements:', allText.slice(0, 40));
    throw new Error(`Preset "${title}" not found`);
  }
}

await page.screenshot({ path: 'console-presets.png', fullPage: true });

await browser.close();
relay.close();
