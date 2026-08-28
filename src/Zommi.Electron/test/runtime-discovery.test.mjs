import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { RUNTIME_CATALOG, catalogExecutableNames } from '../runtime-catalog.mjs';
import {
  RuntimeDiscovery,
  buildLoginShellWrapper,
  buildPosixDetectionScript,
  commandForTarget,
  enumerateExecutionHosts,
  parseExecutableMatches,
  parseWslDistributions,
  resolveNativeCommand,
  selectDefaultTarget,
  targetsFromMatches,
} from '../runtime-discovery.mjs';

test('catalog exposes unique safe executable names for all initial runtime families', () => {
  const names = catalogExecutableNames();
  assert.deepEqual(names, ['codex', 'pi', 'hermes', 'openclaw', 'claude']);
  assert.ok(RUNTIME_CATALOG.every((entry) => entry.id && entry.adapterId && entry.classification));
});

test('WSL enumeration strips UTF-16 nulls and identifies the starred default distribution', () => {
  const quiet = [...'Ubuntu-20.04\r\nDebian\r\n'].join('\0');
  const verbose = '  NAME STATE VERSION\n* Ubuntu-20.04 Running 2\n  Debian Stopped 2\n';
  assert.deepEqual(parseWslDistributions(quiet, verbose), [
    { name: 'Ubuntu-20.04', isDefault: true },
    { name: 'Debian', isDefault: false },
  ]);
});

test('Windows Execution Hosts retain native Windows when WSL is unavailable', async () => {
  const hosts = await enumerateExecutionHosts({
    platform: 'win32',
    execFile: async () => { throw new Error('WSL is not installed'); },
  });
  assert.deepEqual(hosts.map((host) => host.id), ['native:win32']);
});

test('one quoted login-shell script detects all agents and accepts absolute paths only', () => {
  const script = buildPosixDetectionScript(['codex', 'pi', 'hermes', 'bad;command']);
  assert.equal((script.match(/command -v/g) || []).length, 1);
  assert.match(script, /'codex' 'pi' 'hermes'/);
  assert.doesNotMatch(script, /bad;command/);
  assert.match(buildLoginShellWrapper(script), /getent passwd/);
  assert.deepEqual(parseExecutableMatches([
    'login banner',
    '__ZOMMI_RUNTIME_HOME__/home/user',
    '__ZOMMI_RUNTIME_PATH__codex\t/home/user/bin/codex',
    '__ZOMMI_RUNTIME_PATH__pi\tpi',
    '__ZOMMI_RUNTIME_PATH__hermes\t/usr/local/bin/hermes',
  ].join('\n')), [
    { executableName: 'codex', executablePath: '/home/user/bin/codex', runtimeHome: '/home/user' },
    { executableName: 'hermes', executablePath: '/usr/local/bin/hermes', runtimeHome: '/home/user' },
  ]);
});

test('native executable resolution searches PATH and known Windows install directories', async () => {
  const root = await mkdtemp(join(tmpdir(), 'zommi-runtime-discovery-'));
  try {
    const npm = join(root, 'AppData', 'Roaming', 'npm');
    const { mkdir } = await import('node:fs/promises');
    await mkdir(npm, { recursive: true });
    await writeFile(join(npm, 'codex.CMD'), '@echo off\n');
    const resolved = await resolveNativeCommand('codex', {
      platform: 'win32',
      env: { PATH: '', PATHEXT: '.EXE;.CMD', APPDATA: join(root, 'AppData', 'Roaming') },
    });
    assert.equal(resolved.toLowerCase(), join(npm, 'codex.CMD').toLowerCase());
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('matches become stable protocol and compatibility Runtime Targets', () => {
  const host = { id: 'wsl:ubuntu', kind: 'wsl', name: 'Ubuntu', isDefault: true };
  const first = targetsFromMatches(host, [
    { executableName: 'codex', executablePath: '/usr/bin/codex' },
    { executableName: 'hermes', executablePath: '/home/u/bin/hermes' },
    { executableName: 'claude', executablePath: '/home/u/bin/claude' },
  ]);
  const second = targetsFromMatches(host, [
    { executableName: 'codex', executablePath: '/usr/bin/codex' },
  ]);
  assert.equal(first.find((target) => target.adapterId === 'codex-app-server').id, second[0].id);
  assert.deepEqual(first.filter((target) => target.runtimeId === 'hermes').map((target) => target.adapterId), [
    'hermes-acp', 'hermes-gateway',
  ]);
  const openClaw = targetsFromMatches(host, [{ executableName: 'openclaw', executablePath: '/home/u/bin/openclaw' }]);
  assert.deepEqual(openClaw.map((target) => target.adapterId), ['openclaw-acp']);
  assert.equal(openClaw[0].protocolName, 'Gateway via ACP');
  assert.equal(openClaw[0].minimumProtocolVersion, 1);
  assert.deepEqual(openClaw[0].capabilities, []);
  assert.ok(openClaw[0].capabilityHints.includes('session.list.v1'));
  assert.ok(!openClaw[0].capabilityHints.includes('operation.idempotency.v1'));
  assert.equal(first.find((target) => target.runtimeId === 'claude').classification, 'compatible');
});

test('selection preserves an exact binding then prefers protocol targets in default WSL', () => {
  const targets = [
    fakeTarget('native-codex', { kind: 'native', isDefault: false }, 10),
    fakeTarget('wsl-pi', { kind: 'wsl', isDefault: true }, 20),
    fakeTarget('wsl-claude', { kind: 'wsl', isDefault: true }, 1, 'compatible'),
  ];
  assert.equal(selectDefaultTarget(targets).id, 'wsl-pi');
  assert.equal(selectDefaultTarget(targets, { lastSelectedTargetId: 'native-codex' }).id, 'native-codex');
  assert.equal(selectDefaultTarget(targets, {
    boundTargetId: 'wsl-pi',
    lastSelectedTargetId: 'native-codex',
  }).id, 'wsl-pi');
});

test('WSL command construction uses argument vectors and preserves the selected distribution', () => {
  const target = {
    executablePath: '/home/u/.local/bin/codex',
    executionHost: { kind: 'wsl', name: 'Ubuntu 24.04' },
  };
  const entry = RUNTIME_CATALOG.find((candidate) => candidate.adapterId === 'codex-app-server');
  assert.deepEqual(commandForTarget(target, entry), {
    command: 'wsl.exe',
    args: ['-d', 'Ubuntu 24.04', '-e', '/home/u/.local/bin/codex', 'app-server'],
  });
});

test('OpenClaw local discovery launches its runtime-owned credential bridge', () => {
  const host = { id: 'wsl:ubuntu', kind: 'wsl', name: 'Ubuntu', isDefault: true };
  const target = targetsFromMatches(host, [{
    executableName: 'openclaw', executablePath: '/home/u/bin/openclaw', runtimeHome: '/home/u',
  }])[0];
  const entry = RUNTIME_CATALOG.find((candidate) => candidate.adapterId === target.adapterId);
  assert.deepEqual(commandForTarget(target, entry), {
    command: 'wsl.exe',
    args: ['-d', 'Ubuntu', '--cd', '/home/u', '-e', '/home/u/bin/openclaw', 'acp'],
  });
  assert.equal(RUNTIME_CATALOG.find((candidate) => candidate.adapterId === 'openclaw-gateway').executables.length, 0);
});

test('native Windows npm command shims launch through cmd without a shell string', () => {
  const target = {
    executablePath: 'C:\\Users\\User Name\\AppData\\Roaming\\npm\\openclaw.cmd',
    executionHost: { id: 'native:win32', kind: 'native', platform: 'win32', isDefault: false },
  };
  const entry = RUNTIME_CATALOG.find((candidate) => candidate.adapterId === 'openclaw-acp');
  assert.deepEqual(commandForTarget(target, entry), {
    command: 'cmd.exe',
    args: [
      '/d', '/v:off', '/s', '/c',
      'C:\\Users\\User Name\\AppData\\Roaming\\npm\\openclaw.cmd', 'acp',
    ],
  });
});

test('discovery returns eager native/default-WSL results then merges other WSL hosts', async () => {
  const calls = [];
  const execFile = async (command, args) => {
    calls.push([command, ...args]);
    if (args.includes('--quiet')) return { stdout: 'Ubuntu\nDebian\n' };
    if (args.includes('--verbose')) return { stdout: '* Ubuntu Running 2\n  Debian Stopped 2\n' };
    const distro = args[args.indexOf('-d') + 1];
    if (distro === 'Ubuntu') return { stdout: '__ZOMMI_RUNTIME_PATH__codex\t/home/u/bin/codex\n' };
    if (distro === 'Debian') return { stdout: '__ZOMMI_RUNTIME_PATH__pi\t/home/d/bin/pi\n' };
    throw new Error(`Unexpected command: ${command} ${args.join(' ')}`);
  };
  const discovery = new RuntimeDiscovery({
    platform: 'win32',
    execFile,
    resolveNativeCommand: async () => null,
    cacheTtlMs: 0,
  });
  const eager = await discovery.discover();
  assert.ok(eager.some((target) => target.runtimeId === 'codex'));
  assert.ok(!eager.some((target) => target.runtimeId === 'pi'));
  const complete = await discovery.waitForBackground();
  assert.ok(complete.some((target) => target.runtimeId === 'pi'));
  assert.equal(calls.filter((call) => call[0] === 'wsl.exe' && call.includes('Ubuntu')).length, 1);
  assert.equal(calls.filter((call) => call[0] === 'wsl.exe' && call.includes('Debian')).length, 1);
  assert.ok(calls.filter((call) => call[0] === 'wsl.exe' && call.includes('-lc'))
    .every((call) => call.includes('-e') && !call.includes('--')));
});

function fakeTarget(id, executionHost, priority, classification = 'native') {
  return { id, executionHost, priority, classification, status: 'detected' };
}
