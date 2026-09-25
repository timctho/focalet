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
const relayRoot = path.dirname(path.dirname(endpointPath));
const spoolRoot = path.join(relayRoot, 'spool');
const activeSpoolSessions = new Set();

function runtimeEnvironment() {
  const environment = { ...process.env };
  // WSL starts the relay without an interactive shell. The launcher may have
  // found Node in nvm by absolute path, while npm CLIs still use env node.
  // Give both transports the same working interpreter without shell startup
  // scripts, and preserve the rest of the distribution's search path.
  environment.PATH = [path.dirname(process.execPath), environment.PATH].filter(Boolean).join(path.delimiter);
  // Remove a parent application's entire routing namespace, including future
  // keys, while retaining agent credentials and Zommi's own launch settings.
  const contextNamespace = /^(.+?)_(?:AGENT_(?:HOOK|LAUNCH)_|ORCHESTRATION_|PANE_|SHELL_READY_|TAB_|TERMINAL_|USER_DATA_|WORKTREE_|CLI_COMMAND$|CODEX_(?:HOME|LAUNCH_PREFLIGHT)$)/i;
  const namespaces = Object.keys(environment).flatMap((key) => {
    if (key.toUpperCase().startsWith('ZOMMI_')) return [];
    const match = key.match(contextNamespace);
    return match ? [`${match[1].toUpperCase()}_`] : [];
  });
  for (const key of Object.keys(environment)) {
    if (namespaces.some((prefix) => key.toUpperCase().startsWith(prefix))) delete environment[key];
  }
  return environment;
}

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

function appendFrame(outputPath, channel, payload) {
  fs.appendFileSync(outputPath, frame(channel, payload));
}

function tryAppendFrame(outputPath, channel, payload) {
  try {
    appendFrame(outputPath, channel, payload);
    return true;
  } catch {
    return false;
  }
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
    env: runtimeEnvironment(),
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

function validSpawnRequest(request) {
  return tokenMatches(request?.token)
    && request?.transportVersion === transportVersion
    && request?.op === 'spawn'
    && typeof request.command === 'string'
    && request.command.startsWith('/')
    && !request.command.includes('\0')
    && Array.isArray(request.args)
    && request.args.every((value) => typeof value === 'string' && !value.includes('\0'))
    && typeof request.cwd === 'string'
    && request.cwd.startsWith('/')
    && !request.cwd.includes('\0');
}

function failSpoolSession(sessionDirectory, message) {
  const outputPath = path.join(sessionDirectory, 'output.bin');
  try {
    tryAppendFrame(outputPath, CHANNEL_STDERR, Buffer.from(`${message}\n`));
    const payload = Buffer.allocUnsafe(4);
    payload.writeInt32BE(70, 0);
    tryAppendFrame(outputPath, CHANNEL_EXIT, payload);
  } finally {
    activeSpoolSessions.delete(sessionDirectory);
    const cleanup = setTimeout(
      () => fs.rmSync(sessionDirectory, { recursive: true, force: true }),
      60_000,
    );
    cleanup.unref();
  }
}

function handleSpoolSession(sessionDirectory, requestPath) {
  // Several distributions or overlapping relay instances share this spool.
  // Only the intended relay may claim a request; claiming first lets another
  // instance consume it and return an authentication failure to a valid client.
  try {
    const pending = JSON.parse(fs.readFileSync(requestPath, 'utf8'));
    if (!tokenMatches(pending?.token)) return;
  } catch {
    return;
  }
  const claimedPath = path.join(sessionDirectory, 'request.claimed.json');
  try {
    fs.renameSync(requestPath, claimedPath);
  } catch {
    return;
  }
  activeSpoolSessions.add(sessionDirectory);
  let request;
  try {
    request = JSON.parse(fs.readFileSync(claimedPath, 'utf8'));
  } catch (error) {
    failSpoolSession(sessionDirectory, `Relay request is invalid: ${error.message}`);
    return;
  }
  if (request.op === 'ping' && tokenMatches(request.token)
      && request.transportVersion === transportVersion
      && typeof request.nonce === 'string' && /^[a-f0-9]{32}$/.test(request.nonce)) {
    try {
      fs.writeFileSync(path.join(sessionDirectory, 'ready.json'), JSON.stringify({
        nonce: request.nonce, pid: process.pid, transportVersion,
      }));
    } finally {
      activeSpoolSessions.delete(sessionDirectory);
      const cleanup = setTimeout(() => fs.rmSync(sessionDirectory, { recursive: true, force: true }), 10_000);
      cleanup.unref();
    }
    return;
  }
  if (!validSpawnRequest(request)) {
    failSpoolSession(sessionDirectory, 'Relay authentication or spawn request failed.');
    return;
  }

  const inputPath = path.join(sessionDirectory, 'stdin.bin');
  const inputClosedPath = path.join(sessionDirectory, 'stdin.closed');
  const clientHeartbeatPath = path.join(sessionDirectory, 'client-heartbeat');
  const outputPath = path.join(sessionDirectory, 'output.bin');
  const child = spawn(request.command, request.args, {
    cwd: request.cwd,
    env: runtimeEnvironment(),
    detached: true,
    shell: false,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let started = false;
  let finished = false;
  let stdoutClosed = false;
  let stderrClosed = false;
  let exitCode = null;
  let inputOffset = 0;
  let inputPaused = false;
  let inputFinished = false;
  let committedInputLength = null;
  let inputTimer;
  let heartbeatValue = null;
  let heartbeatSeenAt = performance.now();
  let heartbeatCheckedAt = -Infinity;
  let heartbeatError = null;
  let relayHeartbeatAt = -Infinity;

  const stopInput = () => {
    inputFinished = true;
  };
  const stopMonitoring = () => {
    stopInput();
    if (inputTimer) clearInterval(inputTimer);
    inputTimer = undefined;
  };

  const maybeFinish = () => {
    if (!started || finished || exitCode === null || !stdoutClosed || !stderrClosed) return;
    finished = true;
    stopMonitoring();
    const payload = Buffer.allocUnsafe(4);
    payload.writeInt32BE(exitCode, 0);
    tryAppendFrame(outputPath, CHANNEL_EXIT, payload);
    activeSpoolSessions.delete(sessionDirectory);
    const cleanup = setTimeout(() => fs.rmSync(sessionDirectory, { recursive: true, force: true }), 60_000);
    cleanup.unref();
  };

  inputTimer = setInterval(() => {
    if (!started || finished) return;
    try {
      const now = performance.now();
      if (now - relayHeartbeatAt >= 500) {
        fs.writeFileSync(path.join(sessionDirectory, 'relay-heartbeat'), String(process.hrtime.bigint()));
        relayHeartbeatAt = now;
      }
      if (now - heartbeatCheckedAt >= 250) {
        heartbeatCheckedAt = now;
        try {
          // Windows file timestamps can lag across the WSL mount. Observe
          // changing heartbeat contents using our own monotonic clock instead.
          // A concurrent truncate/write or transient read error is not an exit.
          const value = fs.readFileSync(clientHeartbeatPath, 'utf8').trim();
          if (/^\d+$/.test(value) && value !== heartbeatValue) {
            heartbeatValue = value;
            heartbeatSeenAt = now;
            heartbeatError = null;
          }
        } catch (error) {
          heartbeatError = error.code;
        }
      }
      if (now - heartbeatSeenAt > 5_000) {
        tryAppendFrame(outputPath, CHANNEL_STDERR, Buffer.from(
          `WSL runtime client heartbeat stopped for 5s${heartbeatError ? ` (${heartbeatError})` : ''}.\n`,
        ));
        stopMonitoring();
        killProcessGroup(child);
        return;
      }
      // EOF and stdin backpressure must not disable client liveness checks.
      if (inputFinished || inputPaused) return;
      const size = fs.statSync(inputPath).size;
      if (committedInputLength === null && fs.existsSync(inputClosedPath)) {
        const committed = fs.readFileSync(inputClosedPath, 'utf8').trim();
        if (/^\d+$/.test(committed)) {
          const parsed = Number(committed);
          if (Number.isSafeInteger(parsed) && parsed >= 0) committedInputLength = parsed;
        }
      }
      if (size > inputOffset) {
        const length = Math.min(64 * 1024, size - inputOffset);
        const input = Buffer.allocUnsafe(length);
        const descriptor = fs.openSync(inputPath, 'r');
        try { fs.readSync(descriptor, input, 0, length, inputOffset); } finally { fs.closeSync(descriptor); }
        inputOffset += length;
        if (child.stdin.destroyed || child.stdin.writableEnded) {
          stopInput();
        } else if (!child.stdin.write(input)) {
          inputPaused = true;
          child.stdin.once('drain', () => { inputPaused = false; });
        }
      }
      if (committedInputLength !== null
          && size >= committedInputLength
          && inputOffset >= committedInputLength) {
        stopInput();
        child.stdin.end();
      }
    } catch (error) {
      tryAppendFrame(outputPath, CHANNEL_STDERR, Buffer.from(
        `WSL runtime input relay failed (${error.code || 'I/O error'}).\n`,
      ));
      stopMonitoring();
      killProcessGroup(child);
    }
  }, 5);
  inputTimer.unref();

  child.stdin.on('error', (error) => {
    stopInput();
    if (error.code !== 'EPIPE' && error.code !== 'ERR_STREAM_DESTROYED') {
      stopMonitoring();
      tryAppendFrame(outputPath, CHANNEL_STDERR, Buffer.from(`WSL runtime input failed: ${error.message}\n`));
      killProcessGroup(child);
    }
  });

  child.once('error', (error) => {
    tryAppendFrame(outputPath, CHANNEL_STDERR, Buffer.from(`Could not start WSL runtime: ${error.message}\n`));
    if (!started) {
      started = true;
      stdoutClosed = true;
      stderrClosed = true;
      exitCode = 70;
      maybeFinish();
    }
  });
  child.once('spawn', () => {
    started = true;
    child.stdout.on('data', (chunk) => {
      if (!tryAppendFrame(outputPath, CHANNEL_STDOUT, chunk)) killProcessGroup(child);
    });
    child.stderr.on('data', (chunk) => {
      if (!tryAppendFrame(outputPath, CHANNEL_STDERR, chunk)) killProcessGroup(child);
    });
    child.stdout.once('close', () => { stdoutClosed = true; maybeFinish(); });
    child.stderr.once('close', () => { stderrClosed = true; maybeFinish(); });
  });
  child.once('close', (code, signal) => {
    exitCode = Number.isInteger(code) ? code : signal ? 128 : 1;
    maybeFinish();
  });
}

function scanSpool() {
  let entries;
  try {
    fs.mkdirSync(spoolRoot, { recursive: true });
    entries = fs.readdirSync(spoolRoot, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const sessionDirectory = path.join(spoolRoot, entry.name);
    if (activeSpoolSessions.has(sessionDirectory)) continue;
    const requestPath = path.join(sessionDirectory, 'request.json');
    if (fs.existsSync(requestPath)) {
      try {
        handleSpoolSession(sessionDirectory, requestPath);
      } catch (error) {
        failSpoolSession(sessionDirectory, `Relay could not handle request: ${error.message}`);
      }
    }
  }
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
    heartbeatMs: Date.now(),
  };
  const writeEndpoint = (required = false) => {
    const temporary = `${endpointPath}.${process.pid}.tmp`;
    try {
      // A replacement relay owns discovery now. Existing sessions can finish
      // on this instance using their own heartbeat, without endpoint flapping.
      if (!required) {
        const current = JSON.parse(fs.readFileSync(endpointPath, 'utf8'));
        if (!tokenMatches(current.token)) return;
      }
      endpoint.heartbeatMs = Date.now();
      fs.mkdirSync(path.dirname(endpointPath), { recursive: true });
      fs.writeFileSync(temporary, `${JSON.stringify(endpoint, null, 2)}\n`, { mode: 0o600 });
      fs.renameSync(temporary, endpointPath);
    } catch (error) {
      try { fs.rmSync(temporary, { force: true }); } catch { /* best effort */ }
      if (required) throw error;
    }
  };
  writeEndpoint(true);
  const heartbeat = setInterval(writeEndpoint, 1_000);
  heartbeat.unref();
  const scanner = setInterval(scanSpool, 10);
  scanner.unref();
});
