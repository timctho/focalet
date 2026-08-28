import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { AcpAdapter } from '../src/Zommi.Electron/acp-adapter.mjs';
import { HermesGatewayAdapter } from '../src/Zommi.Electron/hermes-gateway-adapter.mjs';
import { PiRpcAdapter } from '../src/Zommi.Electron/pi-rpc-adapter.mjs';

const outputArgument = process.argv.find((value) => value.startsWith('--output='));
const outputPath = outputArgument?.slice('--output='.length) || null;
const openclawSessionArgument = process.argv.find((value) => value.startsWith('--openclaw-session='));
const openclawSession = openclawSessionArgument?.slice('--openclaw-session='.length) || null;
const runtimeArguments = process.argv
  .filter((value) => value.startsWith('--runtime='))
  .map((value) => value.slice('--runtime='.length));
const selectedRuntimes = new Set(runtimeArguments);
const shouldRun = (name) => selectedRuntimes.size === 0 || selectedRuntimes.has(name);
const results = { observedAtUtc: new Date().toISOString(), runtimes: [] };

if (shouldRun('hermes-acp')) await verifyRuntime('hermes-acp', new AcpAdapter({
  command: 'hermes', commandArgs: ['acp'], cwd: process.cwd(),
}));
if (shouldRun('hermes-gateway')) await verifyRuntime('hermes-gateway', new HermesGatewayAdapter({
  command: 'hermes', commandArgs: ['serve'], cwd: process.cwd(), executionHost: { kind: 'native' },
}));
if (shouldRun('pi-rpc')) await verifyRuntime('pi-rpc', new PiRpcAdapter({
  command: 'pi', commandArgs: ['--mode', 'rpc'], cwd: process.cwd(),
}), { model: 'github-copilot/gpt-5.5' });
if (shouldRun('openclaw-acp')) await verifyRuntime('openclaw-acp', new AcpAdapter({
  command: 'openclaw', commandArgs: ['acp', ...(openclawSession ? ['--session', openclawSession] : [])], cwd: process.cwd(),
  runtimeDisplayName: 'OpenClaw', signInHint: 'run openclaw onboard',
}));

const rendered = `${JSON.stringify(results, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, rendered, 'utf8');
process.stdout.write(rendered);

async function verifyRuntime(name, adapter, turnOptions = {}) {
  const token = `ZOMMI_${name.replaceAll('-', '_').toUpperCase()}_${randomUUID().replaceAll('-', '').slice(0, 10).toUpperCase()}`;
  let assistantText = '';
  const onStream = (update) => {
    if (update.kind !== 'assistant') return;
    assistantText = update.replace ? String(update.text || '') : `${assistantText}${update.text || ''}`;
  };
  adapter.on('streamUpdate', onStream);
  const startedAt = performance.now();
  try {
    await withTimeout(adapter.ensureStarted(), 60_000, `${name} startup timed out`);
    const startupMilliseconds = Math.round(performance.now() - startedAt);
    const state = await adapter.getChatState();
    const completion = once(adapter, 'turnCompleted');
    const turnStartedAt = performance.now();
    const accepted = await withTimeout(adapter.startTurn(
      `Reply with exactly ${token} and nothing else.`, [], [],
      { ...turnOptions, clientOperationId: `zommi:real-${name}-${randomUUID()}` },
    ), 10_000, `${name} did not acknowledge the turn`);
    const acceptedMilliseconds = Math.round(performance.now() - turnStartedAt);
    const [terminal] = await withTimeout(completion, 60_000, `${name} turn did not complete`);
    const completedMilliseconds = Math.round(performance.now() - turnStartedAt);
    assert.equal(terminal.threadId, accepted.threadId);
    assert.equal(terminal.turnId, accepted.turnId);
    assert.equal(terminal.status, 'completed');
    assert.ok(assistantText.includes(token), `${name} response omitted ${token}: ${assistantText}`);
    results.runtimes.push({
      name,
      protocolVersion: adapter.protocolVersion,
      runtimeVersion: adapter.runtimeVersion,
      sessionId: accepted.threadId,
      turnId: accepted.turnId,
      modelCount: state.models?.length || 0,
      activeModel: state.activeModel || null,
      sessionCount: state.sessions?.length || 0,
      startupMilliseconds,
      acceptedMilliseconds,
      completedMilliseconds,
      exactTokenPassed: true,
    });
  } finally {
    adapter.off('streamUpdate', onStream);
    adapter.stop();
  }
}

async function withTimeout(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
