import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { recordNativeDiagnostic } from '../adapter-diagnostics.mjs';

test('native diagnostic retention is bounded and redacts credentials and content while keeping identity', () => {
  const adapter = new EventEmitter();
  for (let index = 0; index < 130; index += 1) {
    recordNativeDiagnostic(adapter, 'fixture', 'future.event', {
      sessionId: 'session-safe', runId: `run-${index}`, status: 'future',
      token: 'runtime-secret', message: 'captured private context', nested: { output: 'tool private output' },
    });
  }
  assert.equal(adapter.nativeDiagnostics.length, 128);
  const serialized = JSON.stringify(adapter.nativeDiagnostics.at(-1));
  assert.match(serialized, /session-safe/);
  assert.match(serialized, /run-129/);
  assert.doesNotMatch(serialized, /runtime-secret|captured private context|tool private output/);
});
