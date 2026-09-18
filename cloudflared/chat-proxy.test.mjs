// Tests for chat-proxy.js - run with:  node --test cloudflared\chat-proxy.test.mjs
//
// The fake origin below does what the ChatAnywhere plugin's server really does
// (confirmed with pktmon on 2026-09-15): it answers with Content-Length and
// then ends the connection with a TCP RST instead of a FIN. A reader that has
// not drained the socket by the time the RST lands loses the tail of the body.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import http from 'node:http';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { createProxy } = require('./chat-proxy.js');

const BIG = Buffer.alloc(462 * 1024, 'x'); // same size as the real JS bundle

// A raw-TCP fake origin. `handler(req, socket, hit)` gets the parsed request
// line + headers and the socket, and decides what bytes to write and how to
// end the connection.
function startOrigin(handler) {
    const state = { hits: 0, sockets: new Set() };
    const server = net.createServer((socket) => {
        state.sockets.add(socket);
        socket.on('close', () => state.sockets.delete(socket));
        socket.on('error', () => {});
        let buf = '';
        socket.on('data', (d) => {
            buf += d.toString('latin1');
            const end = buf.indexOf('\r\n\r\n');
            if (end < 0) return;
            const head = buf.slice(0, end);
            buf = '';
            const [reqLine, ...headerLines] = head.split('\r\n');
            const [method, path] = reqLine.split(' ');
            const headers = {};
            for (const l of headerLines) {
                const i = l.indexOf(':');
                if (i > 0) headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim();
            }
            state.hits += 1;
            handler({ method, path, headers }, socket, state.hits);
        });
    });
    return new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => {
            resolve({
                port: server.address().port,
                state,
                close: () => new Promise((r) => { for (const s of state.sockets) s.destroy(); server.close(() => r()); }),
            });
        });
    });
}

function startProxy(originPort, opts = {}) {
    const server = createProxy({ upstreamHost: '127.0.0.1', upstreamPort: originPort, retryDelayMs: 5, log: () => {}, ...opts });
    return new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => {
            resolve({ port: server.address().port, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }) });
        });
    });
}

function fetchRaw(port, { method = 'GET', path = '/', body = null } = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port, method, path, headers: body ? { 'content-length': Buffer.byteLength(body) } : {} }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks), complete: res.complete }));
            res.on('error', reject);
        });
        req.on('error', reject);
        if (body) req.write(body);
        req.end();
    });
}

function writeHead(socket, status, headers) {
    const lines = [`HTTP/1.1 ${status}`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), 'Connection: close', '', ''];
    socket.write(lines.join('\r\n'));
}

// Sends the whole body then RSTs - the plugin's normal, successful behaviour.
// The RST is delayed a few ms: cross-process the reader almost always drains
// the socket before the reset lands (36/40 against the real origin), whereas
// in-process an immediate RST beats the reader's event loop every time and
// Windows then discards the entire unread receive buffer, headers included.
// The delayed form is the realistic one; the immediate form is the failure
// case, exercised by partialBodyThenReset below.
function fullBodyThenReset(socket, body, contentType = 'application/javascript') {
    writeHead(socket, '200 OK', { 'Content-Length': body.length, 'Content-Type': contentType });
    socket.write(body, () => setTimeout(() => socket.resetAndDestroy(), 20));
}

// Announces the whole body, sends only part of it, then RSTs - what cloudflared
// saw 6 times out of 10.
function partialBodyThenReset(socket, body) {
    writeHead(socket, '200 OK', { 'Content-Length': body.length, 'Content-Type': 'application/javascript' });
    socket.write(body.subarray(0, Math.floor(body.length / 3)), () => socket.resetAndDestroy());
}

test('delivers the full body with a correct Content-Length when the origin resets after writing everything', async () => {
    const origin = await startOrigin((req, socket) => fullBodyThenReset(socket, BIG));
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { path: '/assets/index.js' });
        assert.equal(res.status, 200);
        assert.equal(res.headers['content-length'], String(BIG.length));
        assert.equal(res.body.length, BIG.length);
        assert.ok(res.complete);
    } finally { await proxy.close(); await origin.close(); }
});

test('retries a GET the origin truncated and serves the complete second attempt', async () => {
    const origin = await startOrigin((req, socket, hit) => {
        if (hit === 1) partialBodyThenReset(socket, BIG); else fullBodyThenReset(socket, BIG);
    });
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { path: '/assets/index.js' });
        assert.equal(res.status, 200);
        assert.equal(res.body.length, BIG.length);
        assert.equal(origin.state.hits, 2);
    } finally { await proxy.close(); await origin.close(); }
});

test('answers 502 after three truncated attempts instead of forwarding a short body', async () => {
    const origin = await startOrigin((req, socket) => partialBodyThenReset(socket, BIG));
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { path: '/assets/index.js' });
        assert.equal(res.status, 502);
        assert.equal(origin.state.hits, 3);
    } finally { await proxy.close(); await origin.close(); }
});

test('never retries a POST: a truncated /send is answered 502 after one attempt', async () => {
    const origin = await startOrigin((req, socket) => partialBodyThenReset(socket, Buffer.from('{"ok":true,"padding":"' + 'p'.repeat(200) + '"}')));
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { method: 'POST', path: '/send', body: '{"message":"hi"}' });
        assert.equal(res.status, 502);
        assert.equal(origin.state.hits, 1);
    } finally { await proxy.close(); await origin.close(); }
});

test('forwards the request method, path, query and body to the origin unchanged', async () => {
    let seen = null;
    let seenBody = '';
    const origin = await startOrigin((req, socket) => {
        seen = req;
        socket.on('data', (d) => { seenBody += d.toString(); });
        // The body may already be in the same segment as the headers; read what follows.
        setTimeout(() => fullBodyThenReset(socket, Buffer.from('{"sent":true}'), 'application/json'), 30);
    });
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { method: 'POST', path: '/send?x=1', body: '{"message":"hi"}' });
        assert.equal(res.status, 200);
        assert.equal(seen.method, 'POST');
        assert.equal(seen.path, '/send?x=1');
        assert.equal(seen.headers['content-length'], '16');
        assert.equal(res.body.toString(), '{"sent":true}');
    } finally { await proxy.close(); await origin.close(); }
});

test('streams /sse: the first event reaches the client while the origin connection is still open', async () => {
    let originSocket = null;
    const origin = await startOrigin((req, socket) => {
        originSocket = socket;
        writeHead(socket, '200 OK', { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Transfer-Encoding': 'chunked' });
        const ev = 'data: {"type":"ping"}\n\n';
        socket.write(`${ev.length.toString(16)}\r\n${ev}\r\n`);
        // ...and then nothing: a real SSE stream stays open for hours.
    });
    const proxy = await startProxy(origin.port);
    try {
        const firstChunk = await new Promise((resolve, reject) => {
            const req = http.request({ host: '127.0.0.1', port: proxy.port, path: '/sse' }, (res) => {
                assert.equal(res.statusCode, 200);
                assert.equal(res.headers['content-type'], 'text/event-stream');
                res.once('data', (c) => { resolve(c.toString()); req.destroy(); });
            });
            req.on('error', () => {});
            req.end();
        });
        assert.equal(firstChunk, 'data: {"type":"ping"}\n\n');
        assert.ok(originSocket && !originSocket.destroyed, 'origin connection was still open when the first event arrived');
    } finally { await proxy.close(); await origin.close(); }
});

test('closes the origin connection when the SSE client goes away', async () => {
    let originClosed = null;
    const origin = await startOrigin((req, socket) => {
        originClosed = new Promise((r) => socket.on('close', r));
        writeHead(socket, '200 OK', { 'Content-Type': 'text/event-stream', 'Transfer-Encoding': 'chunked' });
        const ev = 'data: {"type":"ping"}\n\n';
        socket.write(`${ev.length.toString(16)}\r\n${ev}\r\n`);
    });
    const proxy = await startProxy(origin.port);
    try {
        await new Promise((resolve) => {
            const req = http.request({ host: '127.0.0.1', port: proxy.port, path: '/sse' }, (res) => {
                res.once('data', () => { req.destroy(); resolve(); });
            });
            req.on('error', () => {});
            req.end();
        });
        const closed = await Promise.race([originClosed.then(() => true), new Promise((r) => setTimeout(() => r(false), 2000))]);
        assert.ok(closed, 'origin socket should be closed within 2s of the client disconnecting');
    } finally { await proxy.close(); await origin.close(); }
});

test('answers its own health probe with 200 without contacting the origin', async () => {
    // console-health.ps1 probes this. A 502 from a healthy proxy whose origin
    // (the game) is simply closed must not look like a wedged proxy.
    const origin = await startOrigin((req, socket) => fullBodyThenReset(socket, Buffer.from('never')));
    const proxy = await startProxy(origin.port);
    try {
        const res = await fetchRaw(proxy.port, { path: '/.chat-proxy/health' });
        assert.equal(res.status, 200);
        assert.equal(res.body.toString().trim(), 'ok');
        assert.equal(origin.state.hits, 0);
    } finally { await proxy.close(); await origin.close(); }
});

test('answers 502 when the origin is not listening at all', async () => {
    const dead = await startOrigin(() => {});
    const port = dead.port;
    await dead.close();
    const proxy = await startProxy(port);
    try {
        const res = await fetchRaw(proxy.port, { path: '/' });
        assert.equal(res.status, 502);
    } finally { await proxy.close(); }
});
