// chat-proxy.js - buffering proxy between cloudflared and the ChatAnywhere origin.
//
//   cloudflared (chat.ffxiv.be) -> 127.0.0.1:7543 (this) -> 127.0.0.1:3000 (ChatAnywhere)
//
// WHY THIS EXISTS. chat.ffxiv.be is served by the ChatAnywhere Dalamud plugin
// from inside the FFXIV game process (WatsonWebserver.Lite over CavemanTcp).
// pktmon on 2026-09-15 showed that server ends EVERY connection with a TCP RST,
// not a FIN, right after writing the response. A reader that has not drained
// the socket by the time the RST lands loses whatever is still unread - and
// Windows discards unread receive-buffer data on RST. cloudflared reads the
// origin at the pace the Cloudflare edge accepts, so the 462 KB JS bundle
// arrived truncated 6 times out of 10 (curl exit 92), while a reader on the
// same machine that drains at loopback speed got it intact 10 of 10.
//
// So this proxy reads each origin response as fast as the loopback allows,
// buffers it whole, checks it is complete (Content-Length or the chunked
// terminator), and only then hands it to cloudflared with a fresh
// Content-Length. If the origin still truncated it, idempotent requests
// (GET/HEAD/OPTIONS) are retried; POST/PUT/DELETE are never retried, so a chat
// message cannot be sent twice - a truncated one gets a 502 instead.
//
// The exception is Server-Sent Events: /sse (or anything answering with
// text/event-stream) is a stream that stays open for hours, so it is piped
// through untouched, and the origin request is torn down when the client
// disconnects so the plugin drops that SSE client.
//
// HTTP on loopback is intentional: TLS is terminated by the Cloudflare tunnel.
// Started by start-console.ps1, kept alive by console-health.ps1, checked by
// verify-console.ps1. Tests: node --test cloudflared\chat-proxy.test.mjs
'use strict';

const http = require('http');

const PROXY_PORT = 7543;
const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = 3000;
const HEALTH_PATH = '/.chat-proxy/health';

const IDEMPOTENT = new Set(['GET', 'HEAD', 'OPTIONS']);
// Hop-by-hop headers must not be forwarded in either direction (RFC 7230 6.1).
const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer']);

function stripHopByHop(headers) {
    const out = {};
    for (const [k, v] of Object.entries(headers)) {
        if (!HOP_BY_HOP.has(k.toLowerCase())) out[k] = v;
    }
    return out;
}

function defaultLog(msg) {
    console.error(`[chat-proxy] ${new Date().toISOString()} ${msg}`);
}

function readAll(stream) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        stream.on('data', (c) => chunks.push(c));
        stream.on('end', () => resolve(Buffer.concat(chunks)));
        stream.on('error', reject);
    });
}

function isEventStream(headers) {
    return String(headers['content-type'] || '').toLowerCase().startsWith('text/event-stream');
}

// One attempt against the origin. Resolves to
//   { status, headers, body }                 - a complete buffered response, or
//   { status, headers, stream: IncomingMessage } - an SSE response to pipe.
// Rejects with err.truncated = true when the origin closed before the body was
// complete, or with the connection error otherwise.
function attempt({ upstreamHost, upstreamPort, timeoutMs }, { method, path, headers, body }) {
    return new Promise((resolve, reject) => {
        let settled = false;
        const done = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };
        const truncated = (why) => { const e = new Error(why); e.truncated = true; return e; };

        const proxyReq = http.request({
            host: upstreamHost,
            port: upstreamPort,
            method,
            path,
            headers,
            agent: false,          // the origin sends Connection: close anyway; never reuse its sockets
        });
        proxyReq.setTimeout(timeoutMs, () => proxyReq.destroy(new Error(`origin did not answer within ${timeoutMs} ms`)));
        proxyReq.on('error', (err) => done(reject, err));

        proxyReq.on('response', (proxyRes) => {
            const resHeaders = stripHopByHop(proxyRes.headers);
            if (isEventStream(resHeaders)) {
                done(resolve, { status: proxyRes.statusCode, headers: resHeaders, stream: proxyRes, req: proxyReq });
                return;
            }
            const chunks = [];
            proxyRes.on('data', (c) => chunks.push(c));
            proxyRes.on('end', () => {
                if (proxyRes.complete) done(resolve, { status: proxyRes.statusCode, headers: resHeaders, body: Buffer.concat(chunks) });
                else done(reject, truncated('origin closed before the response was complete'));
            });
            // A RST surfaces here (and as 'aborted') before 'end' when the body is short.
            proxyRes.on('error', () => done(reject, truncated('origin connection reset before the response was complete')));
            proxyRes.on('aborted', () => done(reject, truncated('origin aborted the response')));
        });

        if (body && body.length) proxyReq.write(body);
        proxyReq.end();
    });
}

function createProxy(options = {}) {
    const cfg = {
        upstreamHost: UPSTREAM_HOST,
        upstreamPort: UPSTREAM_PORT,
        maxAttempts: 3,
        retryDelayMs: 50,
        timeoutMs: 30000,
        log: defaultLog,
        ...options,
    };
    const log = cfg.log;

    const server = http.createServer(async (req, res) => {
        const method = req.method.toUpperCase();

        // Liveness probe for console-health.ps1 / verify-console.ps1. Answered
        // here, never forwarded: with the game closed the origin is down and '/'
        // legitimately 502s, which must not look like a wedged proxy.
        if (req.url === HEALTH_PATH) {
            res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
            res.end('ok\n');
            return;
        }
        const headers = stripHopByHop(req.headers);
        let body;
        try {
            body = await readAll(req);
        } catch (err) {
            log(`client body read failed for ${method} ${req.url}: ${err.message}`);
            res.destroy();
            return;
        }

        const maxAttempts = IDEMPOTENT.has(method) ? cfg.maxAttempts : 1;
        let lastErr = null;
        for (let n = 1; n <= maxAttempts; n++) {
            // The client gave up while we were retrying. NOT req.destroyed: an
            // IncomingMessage auto-destroys as soon as its body has been read,
            // so that is true for every request by this point.
            if (res.destroyed) return;
            let result;
            try {
                result = await attempt(cfg, { method, path: req.url, headers, body });
            } catch (err) {
                lastErr = err;
                if (n < maxAttempts) {
                    log(`${method} ${req.url}: attempt ${n} failed (${err.message}) - retrying`);
                    await new Promise((r) => setTimeout(r, cfg.retryDelayMs));
                }
                continue;
            }

            if (result.stream) {
                // SSE: pipe through, and tear the origin request down when the client leaves.
                res.writeHead(result.status, result.headers);
                result.stream.pipe(res);
                const abort = () => { result.req.destroy(); result.stream.destroy(); };
                req.on('close', abort);
                res.on('close', abort);
                result.stream.on('error', () => res.destroy());
                return;
            }

            const outHeaders = { ...result.headers };
            if (method !== 'HEAD') outHeaders['content-length'] = String(result.body.length);
            res.writeHead(result.status, outHeaders);
            res.end(method === 'HEAD' ? undefined : result.body);
            return;
        }

        const why = lastErr ? lastErr.message : 'unknown error';
        log(`${method} ${req.url}: giving up after ${maxAttempts} attempt(s): ${why}`);
        if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
        }
        res.end(`chat-proxy: origin ${cfg.upstreamHost}:${cfg.upstreamPort} failed: ${why}\n`);
    });

    return server;
}

module.exports = { createProxy, PROXY_PORT, UPSTREAM_HOST, UPSTREAM_PORT, HEALTH_PATH };

if (require.main === module) {
    createProxy().listen(PROXY_PORT, '127.0.0.1', () => {
        defaultLog(`listening on http://127.0.0.1:${PROXY_PORT} -> http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
    });
}
