/**
 * ffxiv.be link shortener — replaces Rebrandly.
 *
 * Deployed as a Cloudflare Worker on ffxiv.be/* and www.ffxiv.be/*.
 * Slugs live in the LINKS map below; there are few enough that KV would be
 * more moving parts than it's worth. To add one, edit the map and redeploy:
 *
 *   cloudflared\deploy-shortener.ps1
 *
 * Imported from Rebrandly on 2026-07-31 (see rebrandly-links-export.csv).
 * Redirects are 302, matching Rebrandly's behaviour — 301 gets cached hard by
 * browsers and would make a destination change effectively unfixable.
 */

const LINKS = {
  s:      'https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/main/run-all.ps1',
  yul:    'https://yul-sanjaa.carrd.co/',
  truth:  'https://forgiventruth.carrd.co',
  carrd:  'https://forgiventruth.carrd.co',
  flist:  'https://www.f-list.net/c/forgiven%20truth/',
  ENL1:   'https://www.mediafire.com/file/k7nla0wvkxyl91t/Eorzean-Nightlife.pmp/file',
  ENL2:   'https://www.mediafire.com/file/zfu8ucaas4l581e/Eorzean-Nightlife-V2.pmp/file',
  rvv:    'https://pastebin.com/HJxju30x',
  b5126c: 'https://filedn.com/leGgCrrYIXV0YvzNNKbdzBb/ffxiv_dx11_SGTAjRvWnI.png',
  '3ec10c': 'https://filedn.com/leGgCrrYIXV0YvzNNKbdzBb/ffxiv_dx11_SGTAjRvWnI.png',
};

// Case-insensitive lookup table. Rebrandly treated slugs case-sensitively, but
// ENL1/ENL2 are the kind of thing people retype in lowercase from a screenshot.
const LOWER = new Map(Object.entries(LINKS).map(([k, v]) => [k.toLowerCase(), v]));

const HOME = `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ffxiv.be</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
         background:#0f1115; color:#d7dae0; }
  @media (prefers-color-scheme: light) { body { background:#fafafa; color:#24262b; } }
  main { text-align:center; padding:2rem; }
  h1 { font-size:1.5rem; margin:0 0 .25rem; letter-spacing:-.02em; }
  p { margin:0; opacity:.55; font-size:.875rem; }
</style>
<main>
  <h1>ffxiv.be</h1>
  <p>short links only</p>
</main>`;

const NOT_FOUND = `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>404 — ffxiv.be</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
         font:16px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
         background:#0f1115; color:#d7dae0; }
  @media (prefers-color-scheme: light) { body { background:#fafafa; color:#24262b; } }
  main { text-align:center; padding:2rem; }
  h1 { font-size:1.5rem; margin:0 0 .25rem; }
  p { margin:0; opacity:.55; font-size:.875rem; }
</style>
<main>
  <h1>404</h1>
  <p>no such link</p>
</main>`;

const html = (body, status) =>
  new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': status === 404 ? 'no-store' : 'public, max-age=3600',
    },
  });

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const slug = decodeURIComponent(url.pathname.slice(1).replace(/\/+$/, ''));

    if (!slug) return html(HOME, 200);
    if (slug === 'robots.txt') {
      return new Response('User-agent: *\nDisallow: /\n', {
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }
    if (slug === 'favicon.ico') return new Response(null, { status: 204 });

    const target = LINKS[slug] ?? LOWER.get(slug.toLowerCase());
    if (!target) return html(NOT_FOUND, 404);

    // Carry the query string through so tracking params on a shared link survive.
    const dest = new URL(target);
    for (const [k, v] of url.searchParams) {
      if (!dest.searchParams.has(k)) dest.searchParams.append(k, v);
    }

    return Response.redirect(dest.toString(), 302);
  },
};
