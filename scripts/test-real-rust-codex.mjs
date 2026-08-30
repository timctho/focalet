import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const expected = 'ZOMMI_RUST_CODEX_LIVE_OK';
const repositoryRoot = resolve(import.meta.dirname, '..');
const executable = process.platform === 'win32'
  ? join(repositoryRoot, 'target', 'debug', 'zommi-core-host.exe')
  : join(repositoryRoot, 'target', 'debug', 'zommi-core-host');
const temporary = await mkdtemp(join(tmpdir(), 'zommi-rust-codex-live-'));
const child = spawn(executable, [], {
  cwd: repositoryRoot,
  env: {
    ...process.env,
    ZOMMI_CORE_STATE_PATH: join(temporary, 'session-binding.json'),
  },
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
});
let nextId = 0;
let stderr = '';
let assistant = '';
const pending = new Map();
let turnCompletion;
const completed = new Promise((resolveCompletion, rejectCompletion) => {
  turnCompletion = { resolve: resolveCompletion, reject: rejectCompletion };
});
const timeout = setTimeout(() => {
  turnCompletion.reject(new Error('Live Rust/Codex turn did not complete within 120 seconds.'));
}, 120_000);

child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => {
  stderr = `${stderr}${chunk}`.slice(-4_000);
});
child.once('exit', (code) => {
  const error = new Error(`Rust core host exited with code ${code}. ${stderr}`);
  for (const completion of pending.values()) completion.reject(error);
  pending.clear();
  turnCompletion.reject(error);
});
createInterface({ input: child.stdout }).on('line', (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.event) {
    const event = message.event;
    if (event.name === 'item.update' && event.payload?.kind === 'assistant') {
      assistant = event.payload.replace
        ? String(event.payload.text || '')
        : `${assistant}${String(event.payload.text || '')}`;
    }
    if (event.name === 'turn.completed') turnCompletion.resolve(event);
    return;
  }
  const completion = pending.get(String(message.id));
  if (!completion) return;
  pending.delete(String(message.id));
  if (message.ok) completion.resolve(message.result || {});
  else completion.reject(new Error(`${message.error?.code || 'core-failed'}: ${message.error?.message || 'unknown error'}`));
});

function request(operation, payload = {}) {
  const id = String(++nextId);
  return new Promise((resolveRequest, rejectRequest) => {
    pending.set(id, { resolve: resolveRequest, reject: rejectRequest });
    child.stdin.write(`${JSON.stringify({
      id,
      protocolVersion: 1,
      operation,
      payload,
    })}\n`);
  });
}

try {
  const core = await request('core.initialize');
  assert.ok(core.capabilities.includes('codex.appServer.v1'));
  const discovery = await request('runtime.discover');
  assert.ok(discovery.selectedTargetId, 'Rust discovery did not find Codex.');
  const connection = await request('runtime.connect', {
    runtimeTargetId: discovery.selectedTargetId,
    cwd: repositoryRoot,
  });
  const receipt = await request('turn.start', {
    runtimeTargetId: connection.runtimeTargetId,
    sessionId: connection.sessionId,
    message: `Reply with ${expected} and nothing else.`,
    clientOperationId: 'client:rust-codex-live',
  });
  const completion = await completed;
  assert.equal(completion.runtimeTargetId, receipt.runtimeTargetId);
  assert.equal(completion.sessionId, receipt.sessionId);
  assert.equal(completion.turnId, receipt.turnId);
  assert.equal(completion.clientOperationId, receipt.clientOperationId);
  assert.equal(completion.payload?.status, 'completed');
  assert.equal(assistant.trim(), expected);
  await request('core.shutdown');
  console.log(JSON.stringify({
    ok: true,
    coreVersion: core.coreVersion,
    runtimeVersion: connection.runtimeVersion,
    runtimeTargetId: receipt.runtimeTargetId,
    sessionId: receipt.sessionId,
    turnId: receipt.turnId,
    response: assistant.trim(),
  }, null, 2));
} finally {
  clearTimeout(timeout);
  if (!child.killed) child.kill();
  await rm(temporary, { recursive: true, force: true });
}
