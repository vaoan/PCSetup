'use strict';

const net = require('net');

const LISTEN_HOST = '127.0.0.1';

function readArg(name) {
  const prefix = `--${name}=`;
  const arg = process.argv.find(value => value.startsWith(prefix));
  return arg ? arg.slice(prefix.length) : '';
}

const listenPort = Number(readArg('listen-port'));
const targetPort = Number(readArg('target-port'));
const targetHost = readArg('target-host') || '127.0.0.1';

if (!Number.isInteger(listenPort) || !Number.isInteger(targetPort) || listenPort <= 0 || targetPort <= 0) {
  console.error('[tcp-relay] Missing or invalid --listen-port / --target-port');
  process.exit(1);
}

const server = net.createServer((client) => {
  const upstream = net.connect({ host: targetHost, port: targetPort });

  client.setNoDelay(true);
  upstream.setNoDelay(true);

  upstream.on('error', (error) => {
    process.stderr.write(`[tcp-relay:${listenPort}] upstream error: ${error.message}\n`);
    client.destroy();
  });

  client.on('error', () => {
    upstream.destroy();
  });

  client.on('close', () => upstream.destroy());
  upstream.on('close', () => client.destroy());

  client.pipe(upstream);
  upstream.pipe(client);
});

server.on('error', (error) => {
  process.stderr.write(`[tcp-relay:${listenPort}] listen error: ${error.message}\n`);
  process.exit(1);
});

server.listen(listenPort, LISTEN_HOST, () => {
  process.stderr.write(`[tcp-relay:${listenPort}] ${LISTEN_HOST}:${listenPort} -> ${targetHost}:${targetPort}\n`);
});
