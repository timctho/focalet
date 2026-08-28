import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import test from 'node:test';
import {
  PtyCompatibilityAdapter,
  buildPtyCompatibilityLaunch,
  stripTerminalControls,
} from '../pty-compatibility-adapter.mjs';

test('PTY compatibility streams a profile-driven fixture while advertising only degraded capability', async () => {
  const fixture = terminalFixture();
  const adapter = new PtyCompatibilityAdapter({
    target: target(),
    profile: profile(),
    spawnProcess: () => fixture.terminal,
    completionSettleMs: 5,
  });
  const state = await adapter.getChatState();
  assert.equal(state.historyAuthority, 'none');
  assert.deepEqual(adapter.capabilities, ['turn.stream.v1']);
  const stream = once(adapter, 'streamUpdate');
  const completion = once(adapter, 'turnCompleted');
  const accepted = await adapter.startTurn(
    'hello', [], [], { clientOperationId: 'client:pty-compatible-turn' },
  );
  assert.equal(accepted.acknowledgement, 'transport-only');
  assert.match(fixture.writes[0], /^\x1b\[200~/);
  assert.match((await stream)[0].text, /fixture answer/);
  assert.deepEqual(await completion, [{
    threadId: accepted.threadId,
    turnId: accepted.turnId,
    clientOperationId: 'client:pty-compatible-turn',
    status: 'completed',
    evidence: 'terminal-prompt-heuristic',
  }]);
  await assert.rejects(adapter.interruptTurn(), /does not advertise reliable interruption/);
  adapter.stop();
});

test('PTY compatibility wraps WSL with util-linux script and refuses unproven native Windows pipes', () => {
  const launch = buildPtyCompatibilityLaunch(target({
    executionHost: { kind: 'wsl', platform: 'linux', name: 'Ubuntu' },
    runtimeHome: '/home/u',
  }), profile());
  assert.deepEqual(launch.args.slice(0, 5), ['-d', 'Ubuntu', '--cd', '/home/u', '-e']);
  assert.deepEqual(launch.args.slice(5, 7), ['script', '-qefc']);
  assert.match(launch.args[7], /exec '\/usr\/bin\/fixture'/);
  assert.throws(() => buildPtyCompatibilityLaunch(target({
    executionHost: { kind: 'native', platform: 'win32' },
  }), profile()), /ConPTY backend/);
});

test('PTY compatibility strips ANSI control traffic without removing Unicode output', () => {
  assert.equal(stripTerminalControls('\x1b[31mhello 世界\x1b[0m\r\n'), 'hello 世界\r\n');
});

function target(overrides = {}) {
  return {
    adapterId: 'pty-compatibility', runtimeId: 'fixture', executablePath: '/usr/bin/fixture',
    runtimeHome: '/work', executionHost: { kind: 'native', platform: 'linux' }, ...overrides,
  };
}

function profile() {
  return {
    id: 'fixture', displayName: 'Fixture CLI', launchArgs: [], startupTimeoutMs: 100,
    completionSettleMs: 5, readyPatterns: [/FIXTURE>\s*$/], promptPatterns: [/FIXTURE>\s*$/],
    inputMode: 'bracketed-paste',
  };
}

function terminalFixture() {
  const terminal = new EventEmitter();
  const writes = [];
  let onData = null;
  terminal.killed = false;
  terminal.onData = (callback) => {
    onData = callback;
    queueMicrotask(() => onData('\x1b[32mFIXTURE> \x1b[0m'));
  };
  terminal.onExit = () => {};
  terminal.write = (value) => {
    writes.push(value);
    queueMicrotask(() => onData('\r\nfixture answer\r\nFIXTURE> '));
  };
  terminal.kill = () => { terminal.killed = true; };
  return { terminal, writes };
}
