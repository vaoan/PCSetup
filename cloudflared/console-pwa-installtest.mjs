// console-pwa-installtest.mjs — verify console.ffxiv.be is an installable PWA.
//
// Chrome only shows the "Install app" icon when the page meets ALL installability
// criteria: a valid, fetched manifest (name + start_url + display + 192/512 icons),
// an active service worker with a fetch handler, and a secure context. This test
// drives real Chrome (via Playwright) and reads Chrome's own signals through the
// DevTools Protocol — Page.getAppManifest and Page.getInstallabilityErrors — so it
// is a faithful proxy for "will the icon appear".
//
// LOCAL mode (default): the console sits behind Cloudflare Access AND sshwifty only
// serves requests whose Host header is "console.ffxiv.be" (it 403s anything else).
// To test faithfully WITHOUT Cloudflare/Access, we point Chrome's host resolver at
// the local proxy and treat that origin as secure:
//   --host-resolver-rules="MAP console.ffxiv.be 127.0.0.1:<proxyPort>"
//   --unsafely-treat-insecure-origin-as-secure="http://console.ffxiv.be"
// This gives sshwifty the Host it wants (200, not 403), a secure context for the
// service worker, and serves our real injected manifest — all locally.
//
// PUBLIC mode: pass a full URL + a Cloudflare Access JWT to test the real hostname
// end-to-end through Access (get the JWT with:
//   cloudflared access token --app=https://console.ffxiv.be ).
//
// Usage:
//   node console-pwa-installtest.mjs                         # local, proxy on 7681
//   node console-pwa-installtest.mjs --proxy-port 7681       # local, explicit port
//   node console-pwa-installtest.mjs --headed                # watch it in a window
//   node console-pwa-installtest.mjs https://console.ffxiv.be/ --cf-cookie <JWT>
//
// Exit code 0 = installable, 1 = not (details printed).
import { chromium } from 'playwright';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import http from 'node:http';

function flag(name) { return process.argv.includes(name); }
function opt(name, def = null) {
  const i = process.argv.indexOf(name);
  return i !== -1 ? process.argv[i + 1] : def;
}

const HOSTNAME   = 'console.ffxiv.be';
const publicUrl  = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : null;
const proxyPort  = Number(opt('--proxy-port', '7681'));
const cfCookie   = opt('--cf-cookie');
const headed     = flag('--headed');

const isLocal = !publicUrl;

// LOCAL mode: start a Host-rewriting shim on 127.0.0.1 that forwards to the proxy
// with Host: console.ffxiv.be. The browser then talks to 127.0.0.1 (a secure
// context, so the service worker registers) while sshwifty gets the Host it
// demands (200, not 403). The manifest/icons/SW are served by the proxy directly
// regardless of Host, so rewriting it on every request is harmless.
let shim = null, shimPort = null;
if (isLocal) {
  shim = http.createServer((creq, cres) => {
    const opts = {
      hostname: '127.0.0.1', port: proxyPort, path: creq.url, method: creq.method,
      headers: { ...creq.headers, host: HOSTNAME },
    };
    const preq = http.request(opts, pres => {
      cres.writeHead(pres.statusCode, pres.headers);
      pres.pipe(cres);
    });
    preq.on('error', e => { cres.writeHead(502); cres.end('shim error: ' + e.message); });
    creq.pipe(preq);
  });
  await new Promise(res => shim.listen(0, '127.0.0.1', res));
  shimPort = shim.address().port;
}

const targetUrl = publicUrl || `http://127.0.0.1:${shimPort}/`;

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pwa-installtest-'));
const context = await chromium.launchPersistentContext(userDataDir, { headless: !headed, args: [] });

if (cfCookie) {
  await context.addCookies([{
    name: 'CF_Authorization', value: cfCookie,
    domain: new URL(targetUrl).hostname, path: '/', httpOnly: true, secure: true, sameSite: 'Lax',
  }]);
}

const page = context.pages()[0] || await context.newPage();
const client = await context.newCDPSession(page);

const logs = [];
const responses = [];
page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));
page.on('response', r => responses.push({ status: r.status(), url: r.url() }));

console.log(`Target: ${targetUrl}  (${isLocal ? 'local shim -> Host ' + HOSTNAME + ' -> 127.0.0.1:' + proxyPort : 'public'})`);

let docStatus = null;
try {
  const resp = await page.goto(targetUrl, { waitUntil: 'load', timeout: 30000 });
  docStatus = resp ? resp.status() : null;
} catch (e) {
  console.log(`Navigation failed: ${e.message}`);
}

// Wait for the service worker to register + activate.
let swState = 'unknown';
try {
  swState = await page.evaluate(async () => {
    if (!('serviceWorker' in navigator)) return 'unsupported';
    const deadline = Date.now() + 8000;
    let reg = await navigator.serviceWorker.getRegistration();
    while (!reg && Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 300));
      reg = await navigator.serviceWorker.getRegistration();
    }
    if (!reg) return 'no-registration';
    await navigator.serviceWorker.ready;
    return reg.active ? 'active' : (reg.installing ? 'installing' : 'waiting');
  });
} catch (e) { swState = 'err:' + e.message; }

await page.waitForTimeout(1500);

const manifest = await client.send('Page.getAppManifest').catch(e => ({ error: e.message }));
const install  = await client.send('Page.getInstallabilityErrors').catch(e => ({ error: e.message }));
const errs = install.installabilityErrors || [];

// Page.getAppManifest returns the raw manifest JSON in `.data`; parse that for the
// authoritative fields (`.parsed` only exposes scope; `.manifest` uses enum-ish values).
let manifestData = {};
try { manifestData = manifest.data ? JSON.parse(manifest.data) : {}; } catch {}
const parsedName = manifestData.name;
const display = manifestData.display;
const icons = Array.isArray(manifestData.icons) ? manifestData.icons : [];
const iconSizes = icons.map(i => String(i.sizes || '')).join(' | ');
const manifestFetched = !!manifest.url && Array.isArray(manifest.errors) && manifest.errors.length === 0;

// Verify the manifest link the browser actually used carries crossorigin=use-credentials
// (required behind Cloudflare Access; harmless locally).
let linkInfo = 'n/a';
try {
  linkInfo = await page.evaluate(() => {
    const l = document.querySelector('link[rel="manifest"]');
    return l ? `${new URL(l.href).pathname} crossorigin=${l.getAttribute('crossorigin')}` : 'NO LINK';
  });
} catch {}

console.log(`Document       : HTTP ${docStatus}`);
console.log(`Manifest link  : ${linkInfo}`);
console.log(`Manifest URL   : ${manifest.url || '(not fetched)'}`);
console.log(`Manifest name  : ${parsedName || '(unparsed)'}`);
console.log(`Manifest display: ${display || '(none)'}`);
console.log(`Manifest icons : ${icons.length} (${iconSizes || 'none'})`);
if (manifest.errors && manifest.errors.length) console.log(`Manifest errors: ${JSON.stringify(manifest.errors)}`);
console.log(`Service worker : ${swState}`);
console.log(`Installability : ${errs.length === 0 ? 'no errors' : JSON.stringify(errs)}`);

// Robust verdict: don't trust an empty installability list alone (it reads empty
// on error pages where no manifest was evaluated). Require the positive signals too.
const checks = {
  'document 200':            docStatus === 200,
  'manifest fetched':        manifestFetched,
  'manifest name = SSH Console': parsedName === 'SSH Console',
  'display = standalone':     display === 'standalone',
  'has 192 & 512 icons':     iconSizes.includes('192') && iconSizes.includes('512'),
  'service worker active':   swState === 'active',
  'no installability errors': Array.isArray(errs) && errs.length === 0,
};
console.log('\nChecks:');
for (const [k, v] of Object.entries(checks)) console.log(`  ${v ? '✅' : '❌'} ${k}`);

const failed = Object.entries(checks).filter(([, v]) => !v).map(([k]) => k);
if (failed.length) {
  const bad = responses.filter(r => r.status >= 400);
  if (bad.length) console.log(`\nNon-2xx responses:\n  ${bad.map(r => r.status + ' ' + r.url).join('\n  ')}`);
  if (logs.length) console.log(`\nPage logs:\n  ${logs.join('\n  ')}`);
}

await context.close();
if (shim) await new Promise(res => shim.close(res));
try { fs.rmSync(userDataDir, { recursive: true, force: true }); } catch {}

console.log(`\nRESULT: ${failed.length === 0 ? 'INSTALLABLE ✅' : 'NOT INSTALLABLE ❌ (' + failed.join('; ') + ')'}`);
process.exit(failed.length === 0 ? 0 : 1);
