// ssh-proxy.js - simple TCP relay for SSHwifty
// Listens on 127.0.0.1:2222 and forwards raw TCP to the current WSL SSH host.
'use strict';

const { spawn } = require('child_process');
const net = require('net');

const LISTEN_HOST = '127.0.0.1';
const LISTEN_PORT = 2222;

function parseTarget(value) {
  const idx = value.lastIndexOf(':');
  if (idx <= 0) throw new Error('Invalid target: ' + value);
  return { host: value.slice(0, idx), port: Number(value.slice(idx + 1)) };
}

const targetArg = process.argv.find(arg => arg.startsWith('--target='));
if (!targetArg) {
  console.error('[ssh-proxy] Missing --target=HOST:PORT');
  process.exit(1);
}

const target = parseTarget(targetArg.slice('--target='.length));

const server = net.createServer((client) => {
  const wslArgs = ['-d', 'Ubuntu-24.04', '--user', 'root', '--', 'nc', '127.0.0.1', '22'];
  const upstream = spawn('wsl', wslArgs, {
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });

  let settled = false;

  const cleanup = () => {
    if (settled) return;
    settled = true;
    upstream.kill();
    client.destroy();
  };

  process.stderr.write('[ssh-proxy] spawning WSL loopback relay -> 127.0.0.1:22\n');

  client.setNoDelay(true);
  upstream.stdout.setNoDelay?.(true);

  client.pipe(upstream.stdin);
  upstream.stdout.pipe(client);

  upstream.stderr.on('data', (chunk) => {
    process.stderr.write(`[ssh-proxy] wsl nc: ${chunk.toString('utf8')}`);
  });

  upstream.on('error', (err) => {
    process.stderr.write(`[ssh-proxy] upstream error: ${err.message}\n`);
    cleanup();
  });

  upstream.on('close', (code, signal) => {
    if (settled) return;
    settled = true;
    process.stderr.write(`[ssh-proxy] upstream closed (code=${code}, signal=${signal ?? 'none'})\n`);
    client.destroy();
  });

  client.on('error', cleanup);
  client.on('close', cleanup);
});

server.on('error', (err) => {
  process.stderr.write(`[ssh-proxy] listen error: ${err.message}\n`);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  process.stderr.write(`[ssh-proxy] ${LISTEN_HOST}:${LISTEN_PORT} -> ${target.host}:${target.port}\n`);
});
