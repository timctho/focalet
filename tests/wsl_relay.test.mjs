import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const TOKEN = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

async function waitForEndpoint(endpointPath) {
  const deadline = Date.now() + 5_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return JSON.parse(await readFile(endpointPath, 'utf8'));
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
  throw lastError ?? new Error('Relay endpoint was not written.');
}

function runRuntime(endpoint) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: endpoint.host, port: endpoint.port });
    let buffer = Buffer.alloc(0);
    let handshakeRead = false;
    const stdout = [];
    const stderr = [];
    socket.once('error', reject);
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!handshakeRead) {
        const newline = buffer.indexOf(0x0a);
        if (newline < 0) return;
        const response = JSON.parse(buffer.subarray(0, newline).toString('utf8'));
        assert.equal(response.ok, true);
        buffer = buffer.subarray(newline + 1);
        handshakeRead = true;
      }
      while (buffer.length >= 5) {
        const channel = buffer[0];
        const length = buffer.readUInt32BE(1);
        if (buffer.length < 5 + length) return;
        const payload = buffer.subarray(5, 5 + length);
        buffer = buffer.subarray(5 + length);
        if (channel === 1) stdout.push(payload);
        else if (channel === 2) stderr.push(payload);
        else if (channel === 3) {
          assert.equal(payload.length, 4);
          resolve({
            exitCode: payload.readInt32BE(0),
            stdout: Buffer.concat(stdout).toString('utf8'),
            stderr: Buffer.concat(stderr).toString('utf8'),
          });
        } else reject(new Error(`Unknown relay channel ${channel}.`));
      }
    });
    socket.once('connect', () => {
      const request = {
        op: 'spawn',
        token: TOKEN,
        transportVersion: 2,
        command: '/bin/sh',
        args: ['-c', 'read value; printf "out:%s\\n" "$value"; printf "err:%s\\n" "$value" >&2; exit 7'],
        cwd: '/',
      };
      socket.end(`${JSON.stringify(request)}\nrelay-input\n`);
    });
  });
}

function runRustProxy(endpointPath) {
  return new Promise((resolve, reject) => {
    const targetRoot = process.env.CARGO_TARGET_DIR || 'target';
    const executable = path.resolve(targetRoot, 'debug', `zommi-core-host${process.platform === 'win32' ? '.exe' : ''}`);
    const child = spawn(executable, [
      '--wsl-proxy',
      '--distribution', 'test',
      '--cwd', '/',
      '--', '/bin/sh', '-c',
      'read value; printf "proxy-out:%s\\n" "$value"; printf "proxy-err:%s\\n" "$value" >&2; exit 9',
    ], {
      env: { ...process.env, ZOMMI_WSL_RELAY_ENDPOINT: endpointPath },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on('data', (chunk) => stdout.push(chunk));
    child.stderr.on('data', (chunk) => stderr.push(chunk));
    child.once('error', reject);
    child.once('close', (code) => resolve({
      code,
      stdout: Buffer.concat(stdout).toString('utf8'),
      stderr: Buffer.concat(stderr).toString('utf8'),
    }));
    child.stdin.end('proxy-input\n');
  });
}

test('persistent WSL relay authenticates and frames runtime stdio', async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'zommi-wsl-relay-'));
  const endpointPath = path.join(temporary, 'endpoint.json');
  const relay = spawn(process.execPath, [
    'scripts/zommi-wsl-relay.js',
    '--endpoint', endpointPath,
    '--token', TOKEN,
    '--version', '2',
    '--distribution', 'test',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  const diagnostics = [];
  relay.stderr.on('data', (chunk) => diagnostics.push(chunk));
  try {
    const endpoint = await waitForEndpoint(endpointPath);
    assert.equal(endpoint.schemaVersion, 1);
    assert.equal(endpoint.transportVersion, 2);
    assert.equal(endpoint.distribution, 'test');
    assert.ok(net.isIP(endpoint.host));
    assert.equal(endpoint.token, TOKEN);

    const result = await runRuntime(endpoint);
    assert.equal(result.exitCode, 7);
    assert.equal(result.stdout, 'out:relay-input\n');
    assert.equal(result.stderr, 'err:relay-input\n');

    const proxy = await runRustProxy(endpointPath);
    assert.equal(proxy.code, 9);
    assert.equal(proxy.stdout, 'proxy-out:proxy-input\n');
    assert.equal(proxy.stderr, 'proxy-err:proxy-input\n');
  } finally {
    relay.kill('SIGTERM');
    await Promise.race([
      new Promise((resolve) => relay.once('exit', resolve)),
      new Promise((resolve) => setTimeout(resolve, 1_000)),
    ]);
    await rm(temporary, { recursive: true, force: true });
  }
  assert.equal(Buffer.concat(diagnostics).toString('utf8'), '');
});
