import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { NativeHostClient } from '../native-host.mjs';

function createFakeChild() {
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.killed = false;
  child.kill = () => { child.killed = true; child.emit('exit', 0); };
  return child;
}

test('native host correlates responses and forwards events', async () => {
  const child = createFakeChild();
  const client = new NativeHostClient('native-host.exe', { spawnProcess: () => child });
  let requestLine = '';
  child.stdin.setEncoding('utf8');
  child.stdin.on('data', (chunk) => { requestLine += chunk; });

  const pending = client.request('ping');
  await new Promise((resolve) => setImmediate(resolve));
  const request = JSON.parse(requestLine.trim());
  assert.equal(request.method, 'ping');
  child.stdout.write(`${JSON.stringify({ type: 'response', id: request.id, ok: true, result: { platform: 'windows' } })}\n`);
  assert.deepEqual(await pending, { platform: 'windows' });

  const eventPromise = once(client, 'status');
  child.stdout.write(`${JSON.stringify({ type: 'event', event: 'status', data: 'ready' })}\n`);
  assert.deepEqual(await eventPromise, ['ready']);
});

test('native host rejects failed responses', async () => {
  const child = createFakeChild();
  const client = new NativeHostClient('native-host.exe', { spawnProcess: () => child });
  let requestLine = '';
  child.stdin.setEncoding('utf8');
  child.stdin.on('data', (chunk) => { requestLine += chunk; });
  const pending = client.request('capture');
  await new Promise((resolve) => setImmediate(resolve));
  const request = JSON.parse(requestLine.trim());
  child.stdout.write(`${JSON.stringify({ type: 'response', id: request.id, ok: false, error: 'capture failed' })}\n`);
  await assert.rejects(pending, /capture failed/);
});

test('native capture preserves the shortcut-time pointer coordinates', async () => {
  const child = createFakeChild();
  const client = new NativeHostClient('native-host.exe', { spawnProcess: () => child });
  let requestLine = '';
  child.stdin.setEncoding('utf8');
  child.stdin.on('data', (chunk) => { requestLine += chunk; });
  const pending = client.request('capture', { point: { x: 123, y: 456 } });
  await new Promise((resolve) => setImmediate(resolve));
  const request = JSON.parse(requestLine.trim());
  assert.deepEqual(request.params.point, { x: 123, y: 456 });
  child.stdout.write(`${JSON.stringify({ type: 'response', id: request.id, ok: true, result: { snapshot: null } })}\n`);
  assert.deepEqual(await pending, { snapshot: null });
});

test('native host requests cannot leave the renderer loading forever', async () => {
  const child = createFakeChild();
  const client = new NativeHostClient('native-host.exe', {
    spawnProcess: () => child,
    requestTimeoutMs: 20,
  });
  const requestError = once(client, 'requestError');
  await assert.rejects(
    client.request('getChatState'),
    /did not respond to 'getChatState' within 1 seconds\. Retry to reconnect\./,
  );
  assert.equal((await requestError)[0].method, 'getChatState');
  assert.equal(client.pending.size, 0);
});
