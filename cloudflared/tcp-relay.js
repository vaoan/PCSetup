'use strict';

const { spawn } = require('child_process');
const net = require('net');

const LISTEN_HOST = '127.0.0.1';
const DISTRO = 'Ubuntu-24.04';

function readArg(name) {
  const prefix = `--${name}=`;
  const arg = process.argv.find(value => value.startsWith(prefix));
  return arg ? arg.slice(prefix.length) : '';
}

const listenPort = Number(readArg('listen-port'));
const targetPort = Number(readArg('target-port'));

if (!Number.isInteger(listenPort) || !Number.isInteger(targetPort) || listenPort <= 0 || targetPort <= 0) {
  console.error('[tcp-relay] Missing or invalid --listen-port / --target-port');
  process.exit(1);
}

const server = net.createServer((client) => {
  const upstream = spawn('wsl', ['-d', DISTRO, '--user', 'root', '--', 'nc', '127.0.0.1', String(targetPort)], {
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });

  let closed = false;
  const closeBoth = () => {
    if (closed) return;
    closed = true;
    upstream.kill();
    client.destroy();
  };

  client.setNoDelay(true);
  upstream.stdout.setNoDelay?.(true);

  client.pipe(upstream.stdin);
  upstream.stdout.pipe(client);

  upstream.stderr.on('data', (chunk) => {
    process.stderr.write(`[tcp-relay:${listenPort}] ${chunk.toString('utf8')}`);
  });

  upstream.on('error', (error) => {
    process.stderr.write(`[tcp-relay:${listenPort}] upstream error: ${error.message}\n`);
    closeBoth();
  });

  upstream.on('close', () => {
    closeBoth();
  });

  client.on('error', closeBoth);
  client.on('close', closeBoth);
});

server.on('error', (error) => {
  process.stderr.write(`[tcp-relay:${listenPort}] listen error: ${error.message}\n`);
  process.exit(1);
});

server.listen(listenPort, LISTEN_HOST, () => {
  process.stderr.write(`[tcp-relay:${listenPort}] ${LISTEN_HOST}:${listenPort} -> WSL 127.0.0.1:${targetPort}\n`);
});
