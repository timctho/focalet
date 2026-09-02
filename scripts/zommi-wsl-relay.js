#!/usr/bin/env node

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const MAX_HANDSHAKE_BYTES = 64 * 1024;
const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const CHANNEL_STDOUT = 1;
const CHANNEL_STDERR = 2;
const CHANNEL_EXIT = 3;

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`Missing ${name}.`);
  }
  return process.argv[index + 1];
}

const endpointPath = argument('--endpoint');
const token = argument('--token');
const transportVersion = Number(argument('--version'));
const distribution = argument('--distribution');

if (!Number.isSafeInteger(transportVersion) || transportVersion < 1) {
  throw new Error('Invalid transport version.');
}
if (token.length < 32 || token.length > 256) {
  throw new Error('Invalid relay token.');
}

function tokenMatches(candidate) {
  if (typeof candidate !== 'string') return false;
  const expected = Buffer.from(token, 'utf8');
  const actual = Buffer.from(candidate, 'utf8');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

function writeJsonLine(socket, value) {
  socket.write(`${JSON.stringify(value)}\n`);
}

function frame(channel, payload) {
  const bytes = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  if (bytes.length > MAX_FRAME_BYTES) {
    throw new Error(`Relay frame exceeds ${MAX_FRAME_BYTES} bytes.`);
  }
  const header = Buffer.allocUnsafe(5);
  header[0] = channel;
  header.writeUInt32BE(bytes.length, 1);
  return Buffer.concat([header, bytes]);
}

function killProcessGroup(child) {
  if (!child?.pid) return;
  try {
    process.kill(-child.pid, 'SIGKILL');
  } catch {
    try { child.kill('SIGKILL'); } catch { /* already gone */ }
  }
}

function handleSpawn(socket, request, trailingInput) {
  const command = typeof request.command === 'string' ? request.command : '';
  const args = Array.isArray(request.args) && request.args.every((value) => typeof value === 'string')
    ? request.args
    : null;
  const cwd = typeof request.cwd === 'string' && request.cwd.startsWith('/')
    ? request.cwd
    : undefined;
  if (!command.startsWith('/') || !args || command.includes('\0')) {
    writeJsonLine(socket, { ok: false, message: 'Relay spawn request is invalid.' });
    socket.end();
    return;
  }

  const child = spawn(command, args, {
    cwd,
    env: process.env,
    detached: true,
    shell: false,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let started = false;
  let finished = false;
  let stdoutClosed = false;
  let stderrClosed = false;
  let exitCode = null;

  const maybeFinish = () => {
    if (!started || finished || exitCode === null || !stdoutClosed || !stderrClosed) return;
    finished = true;
    const payload = Buffer.allocUnsafe(4);
    payload.writeInt32BE(exitCode, 0);
    socket.end(frame(CHANNEL_EXIT, payload));
  };

  const forward = (channel, source) => {
    source.on('data', (chunk) => {
      try {
        if (!socket.write(frame(channel, chunk))) {
          source.pause();
          socket.once('drain', () => source.resume());
        }
      } catch {
        killProcessGroup(child);
        socket.destroy();
      }
    });
  };

  child.once('error', (error) => {
    if (!started) {
      writeJsonLine(socket, { ok: false, message: `Could not start WSL runtime: ${error.message}` });
      socket.end();
      return;
    }
    try { socket.write(frame(CHANNEL_STDERR, Buffer.from(`${error.message}\n`))); } catch { /* closed */ }
  });
  child.once('spawn', () => {
    started = true;
    writeJsonLine(socket, { ok: true, pid: child.pid });
    forward(CHANNEL_STDOUT, child.stdout);
    forward(CHANNEL_STDERR, child.stderr);
    child.stdout.once('close', () => { stdoutClosed = true; maybeFinish(); });
    child.stderr.once('close', () => { stderrClosed = true; maybeFinish(); });

    if (trailingInput.length > 0) child.stdin.write(trailingInput);
    socket.on('data', (chunk) => {
      if (!child.stdin.write(chunk)) {
        socket.pause();
        child.stdin.once('drain', () => socket.resume());
      }
    });
    socket.once('end', () => child.stdin.end());
    socket.resume();
  });
  child.once('close', (code, signal) => {
    exitCode = Number.isInteger(code) ? code : signal ? 128 : 1;
    maybeFinish();
  });
  socket.once('close', () => {
    if (!finished) killProcessGroup(child);
  });
}

function handleClient(socket) {
  socket.setNoDelay(true);
  socket.setTimeout(10_000, () => socket.destroy());
  socket.pause();
  let buffered = Buffer.alloc(0);

  const onHandshakeData = (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    if (buffered.length > MAX_HANDSHAKE_BYTES) {
      socket.destroy();
      return;
    }
    const newline = buffered.indexOf(0x0a);
    if (newline < 0) return;
    socket.off('data', onHandshakeData);
    socket.setTimeout(0);
    let request;
    try {
      request = JSON.parse(buffered.subarray(0, newline).toString('utf8'));
    } catch {
      writeJsonLine(socket, { ok: false, message: 'Relay handshake is not valid JSON.' });
      socket.end();
      return;
    }
    if (!tokenMatches(request.token) || request.transportVersion !== transportVersion) {
      writeJsonLine(socket, { ok: false, message: 'Relay authentication or version failed.' });
      socket.end();
      return;
    }
    if (request.op === 'ping') {
      writeJsonLine(socket, { ok: true, transportVersion });
      socket.end();
      return;
    }
    if (request.op !== 'spawn') {
      writeJsonLine(socket, { ok: false, message: 'Relay operation is unsupported.' });
      socket.end();
      return;
    }
    handleSpawn(socket, request, buffered.subarray(newline + 1));
  };
  socket.on('data', onHandshakeData);
  socket.resume();
}

function relayHost() {
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses || []) {
      if (address.family === 'IPv4' && !address.internal) return address.address;
    }
  }
  return '127.0.0.1';
}

const host = relayHost();
const server = net.createServer({ allowHalfOpen: true }, handleClient);
server.on('error', (error) => {
  process.stderr.write(`[zommi-wsl-relay] ${error.message}\n`);
  process.exit(1);
});
server.listen({ host: '0.0.0.0', port: 0 }, () => {
  const address = server.address();
  const endpoint = {
    schemaVersion: 1,
    transportVersion,
    distribution,
    host,
    port: address.port,
    token,
    pid: process.pid,
  };
  fs.mkdirSync(path.dirname(endpointPath), { recursive: true });
  const temporary = `${endpointPath}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(endpoint, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, endpointPath);
});
