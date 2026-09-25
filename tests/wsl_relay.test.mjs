import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rename, rm, unlink, utimes, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

const TOKEN = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TRANSPORT_VERSION = 9;

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

function runRuntime(endpoint, invocation = {}) {
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
        transportVersion: TRANSPORT_VERSION,
        command: '/bin/sh',
        args: [
          '-c',
          'read value; printf "out:%s\\n" "$value"; [ -z "${PARENT_APP_LEAK_PROBE+x}" ] || printf "parent-env-leaked\\n"; printf "err:%s\\n" "$value" >&2; exit 7',
        ],
        cwd: '/',
        ...invocation,
      };
      socket.end(`${JSON.stringify(request)}\nrelay-input\n`);
    });
  });
}

test('configured npm CLI launches when Node is absent from the WSL PATH', async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'zommi-wsl-node-'));
  const endpointPath = path.join(temporary, 'endpoints', 'test.json');
  const cli = path.join(temporary, 'codex with spaces');
  await writeFile(cli, `#!/usr/bin/env node
process.stdin.resume();
process.stdin.on('end', () => console.log(JSON.stringify({
  args: process.argv.slice(2),
  home: process.env.CODEX_HOME,
  providerKey: process.env.PUBLIC_API_KEY,
  fixtureHome: process.env.ZOMMI_FAKE_CODEX_HOME,
  leaked: process.env.PARENT_APP_LEAK_PROBE,
})));
`, { mode: 0o755 });
  const relay = spawn(process.execPath, [
    'scripts/zommi-wsl-relay.js', '--endpoint', endpointPath,
    '--token', TOKEN, '--version', String(TRANSPORT_VERSION), '--distribution', 'test',
  ], {
    // The relay can find Node by absolute path, just like the launcher does for
    // nvm installations. Its children still need Node for npm CLI shebangs.
    env: { ...process.env, PATH: temporary, PUBLIC_API_KEY: 'fixture-provider-key',
      ZOMMI_FAKE_CODEX_HOME: '/fixture',
      PARENT_APP_AGENT_HOOK_ENDPOINT: 'http://127.0.0.1:1', PARENT_APP_LEAK_PROBE: 'must-not-reach-runtime' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  try {
    const endpoint = await waitForEndpoint(endpointPath);
    const result = await runRuntime(endpoint, {
      command: '/usr/bin/env',
      args: ['CODEX_HOME=/home/test/Agent Data', cli, 'app-server'],
    });
    assert.equal(result.exitCode, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      args: ['app-server'], home: '/home/test/Agent Data', providerKey: 'fixture-provider-key',
      fixtureHome: '/fixture',
    });
    const proxy = await runRustProxy(endpointPath, [
      '/usr/bin/env', 'CODEX_HOME=/home/test/Agent Data', cli, 'app-server',
    ]);
    assert.equal(proxy.code, 0, proxy.stderr);
    assert.deepEqual(JSON.parse(proxy.stdout), JSON.parse(result.stdout));
  } finally {
    if (relay.exitCode === null && relay.signalCode === null) {
      const exited = new Promise((resolve) => relay.once('exit', resolve));
      relay.kill('SIGTERM');
      await exited;
    }
    await rm(temporary, { recursive: true, force: true });
  }
});

function runRustProxy(endpointPath, runtime = [
  '/bin/sh', '-c',
  'read first; printf "proxy-out:%s\\n" "$first"; read second; printf "proxy-err:%s\\n" "$second" >&2; exit 9',
]) {
  return new Promise((resolve, reject) => {
    const targetRoot = process.env.CARGO_TARGET_DIR || 'target';
    const executable = path.resolve(targetRoot, 'debug', `zommi-core-host${process.platform === 'win32' ? '.exe' : ''}`);
    const child = spawn(executable, [
      '--wsl-proxy',
      '--distribution', 'test',
      '--cwd', '/',
      '--', ...runtime,
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
    child.stdin.write('proxy-input-one\n');
    setTimeout(() => child.stdin.end('proxy-input-two\n'), 50);
  });
}

test('persistent WSL relay authenticates and frames runtime stdio', async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'zommi-wsl-relay-'));
  const endpointPath = path.join(temporary, 'endpoints', 'test.json');
  const relay = spawn(process.execPath, [
    'scripts/zommi-wsl-relay.js',
    '--endpoint', endpointPath,
    '--token', TOKEN,
    '--version', String(TRANSPORT_VERSION),
    '--distribution', 'test',
  ], {
    env: { ...process.env, PARENT_APP_AGENT_HOOK_ENDPOINT: 'http://127.0.0.1:1',
      PARENT_APP_LEAK_PROBE: 'must-not-reach-runtime' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const diagnostics = [];
  relay.stderr.on('data', (chunk) => diagnostics.push(chunk));
  try {
    const endpoint = await waitForEndpoint(endpointPath);
    assert.equal(endpoint.schemaVersion, 1);
    assert.equal(endpoint.transportVersion, TRANSPORT_VERSION);
    assert.equal(endpoint.distribution, 'test');
    assert.ok(net.isIP(endpoint.host));
    assert.equal(endpoint.token, TOKEN);

    const result = await runRuntime(endpoint);
    assert.equal(result.exitCode, 7);
    assert.equal(result.stdout, 'out:relay-input\n');
    assert.equal(result.stderr, 'err:relay-input\n');

    const proxy = await runRustProxy(endpointPath);
    assert.equal(proxy.code, 9);
    assert.equal(proxy.stdout, 'proxy-out:proxy-input-one\n');
    assert.equal(proxy.stderr, 'Zommi: preparing WSL transport.\nZommi: WSL transport ready; launching agent.\nproxy-err:proxy-input-two\n');
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

for (const inputMode of ['open', 'closed', 'backpressure']) {
  test(`spool heartbeat handles stale timestamps, transient reads, and lost clients with ${inputMode} stdin`, async () => {
    const temporary = await mkdtemp(path.join(os.tmpdir(), 'zommi-heartbeat-'));
    const endpointPath = path.join(temporary, 'endpoints', 'test.json');
    const relay = spawn(process.execPath, [
      'scripts/zommi-wsl-relay.js', '--endpoint', endpointPath,
      '--token', TOKEN, '--version', String(TRANSPORT_VERSION), '--distribution', 'test',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    const diagnostics = [];
    relay.stderr.on('data', (chunk) => diagnostics.push(chunk));
    const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    try {
      await waitForEndpoint(endpointPath);
      const session = path.join(temporary, 'spool', 'session-heartbeat-test');
      await mkdir(session, { recursive: true });
      const heartbeat = path.join(session, 'client-heartbeat');
      const beat = async (value) => {
        await writeFile(heartbeat, String(value));
        await utimes(heartbeat, 1, 1); // stale Windows/WSL metadata
      };
      await writeFile(path.join(session, 'stdin.bin'), inputMode === 'backpressure' ? Buffer.alloc(1024 * 1024, 120) : '');
      if (inputMode === 'closed') await writeFile(path.join(session, 'stdin.closed'), '0');
      await writeFile(path.join(session, 'output.bin'), '');
      await beat(1);
      await writeFile(path.join(session, 'request.tmp'), JSON.stringify({
        op: 'spawn', token: TOKEN, transportVersion: TRANSPORT_VERSION,
        command: process.execPath, cwd: temporary,
        args: ['-e', 'setInterval(() => console.log("alive"), 50); setTimeout(() => process.exit(0), 15000)'],
      }));
      await rename(path.join(session, 'request.tmp'), path.join(session, 'request.json'));
      const output = async () => {
        const data = await readFile(path.join(session, 'output.bin'));
        const result = { stdout: '', stderr: '', exit: null };
        for (let offset = 0; offset + 5 <= data.length;) {
          const length = data.readUInt32BE(offset + 1);
          if (offset + 5 + length > data.length) break;
          const payload = data.subarray(offset + 5, offset + 5 + length);
          if (data[offset] === 1) result.stdout += payload.toString();
          if (data[offset] === 2) result.stderr += payload.toString();
          if (data[offset] === 3) result.exit = payload.readInt32BE(0);
          offset += 5 + length;
        }
        return result;
      };
      for (let i = 2; i < 7; i++) {
        await pause(150);
        await beat(i);
      }
      assert.ok((await output()).stdout.includes('alive'));
      assert.equal((await output()).exit, null);
      await unlink(heartbeat);
      await pause(400);
      await beat(7);
      await pause(300);
      assert.equal((await output()).exit, null, 'a transient heartbeat read must not kill Codex');
      const deadline = Date.now() + 8_000;
      let stopped;
      do {
        await pause(50);
        stopped = await output();
      } while (stopped.exit === null && Date.now() < deadline);
      assert.equal(stopped.exit, 128);
      assert.match(stopped.stderr, /client heartbeat stopped for 5s/);
    } finally {
      relay.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => relay.once('exit', resolve)), pause(1_000),
      ]);
      await rm(temporary, { recursive: true, force: true });
    }
    assert.equal(Buffer.concat(diagnostics).toString(), '');
  });
}

test('overlapping relays leave foreign requests for their authenticated owner', async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'zommi-relay-ownership-'));
  const firstEndpoint = path.join(temporary, 'endpoints', 'first.json');
  const secondEndpoint = path.join(temporary, 'endpoints', 'second.json');
  const secondToken = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  const relays = [];
  const diagnostics = [];
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const start = (endpoint, token) => {
    const relay = spawn(process.execPath, [
      'scripts/zommi-wsl-relay.js', '--endpoint', endpoint, '--token', token,
      '--version', String(TRANSPORT_VERSION), '--distribution', 'test',
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    relay.stderr.on('data', (chunk) => diagnostics.push(chunk));
    relays.push(relay);
    return waitForEndpoint(endpoint);
  };
  try {
    await start(firstEndpoint, TOKEN);
    const session = path.join(temporary, 'spool', 'session-foreign-owner');
    await mkdir(session, { recursive: true });
    await writeFile(path.join(session, 'stdin.bin'), '');
    await writeFile(path.join(session, 'stdin.closed'), '0');
    await writeFile(path.join(session, 'output.bin'), '');
    await writeFile(path.join(session, 'client-heartbeat'), String(Date.now()));
    const request = JSON.stringify({
      op: 'spawn', token: secondToken, transportVersion: TRANSPORT_VERSION,
      command: '/bin/sh', args: ['-c', 'printf owned-request'], cwd: '/',
    });
    await writeFile(path.join(session, 'request.tmp'), request);
    await rename(path.join(session, 'request.tmp'), path.join(session, 'request.json'));
    await pause(250);
    assert.equal(await readFile(path.join(session, 'request.json'), 'utf8'), request,
      'a different relay must not claim a request it cannot authenticate');
    assert.equal((await readFile(path.join(session, 'output.bin'))).length, 0);

    await start(secondEndpoint, secondToken);
    const deadline = Date.now() + 5_000;
    let output;
    do {
      output = await readFile(path.join(session, 'output.bin'));
      if (output.includes(Buffer.from('owned-request'))) break;
      await pause(25);
    } while (Date.now() < deadline);
    assert.ok(output.includes(Buffer.from('owned-request')));
    assert.equal(await readFile(path.join(session, 'request.claimed.json'), 'utf8'), request);
    for (let round = 0; round < 3; round++) {
      const results = await Promise.all([runRustProxy(firstEndpoint), runRustProxy(secondEndpoint)]);
      for (const result of results) {
        assert.equal(result.code, 9);
        assert.equal(result.stdout, 'proxy-out:proxy-input-one\n');
        assert.equal(result.stderr, 'Zommi: preparing WSL transport.\nZommi: WSL transport ready; launching agent.\nproxy-err:proxy-input-two\n');
      }
    }
  } finally {
    await Promise.all(relays.map(async (relay) => {
      relay.kill('SIGTERM');
      await Promise.race([new Promise((resolve) => relay.once('exit', resolve)), pause(1_000)]);
    }));
    await rm(temporary, { recursive: true, force: true });
  }
  assert.equal(Buffer.concat(diagnostics).toString(), '');
});
