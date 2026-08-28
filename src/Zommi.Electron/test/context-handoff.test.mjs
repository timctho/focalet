import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { buildContextHandoff } from '../context-handoff.mjs';

test('shared Context Handoff keeps user intent first and orders captured evidence by trust', () => {
  const handoff = buildContextHandoff('compare this', [{
    observedAtUtc: '2026-08-28T00:00:00Z',
    surfaceKind: 'Browser',
    application: 'Edge',
    selection: ['selected value'],
    windowTitle: 'Report',
    locator: { kind: 'URL', value: 'https://example.test/report' },
    accessibilityTree: { roots: [{ role: 'Table', name: 'Results' }] },
    indicatedTarget: { controlType: 'Button', name: 'Details' },
  }], 1);
  const positions = [
    '<user_message>',
    'PRIMARY SURFACE SELECTION',
    'URL: https://example.test/report',
    'Nearby accessibility structure',
    'Mouse pointer:',
    'User-selected image regions attached: 1',
  ].map((value) => handoff.indexOf(value));
  assert.ok(positions.every((position) => position >= 0));
  assert.deepEqual([...positions].sort((left, right) => left - right), positions);
  assert.match(handoff, /untrusted data captured from desktop/);
});

test('all runtime adapters depend on the shared Context Handoff instead of Codex', async () => {
  for (const file of [
    'acp-adapter.mjs',
    'pi-rpc-adapter.mjs',
    'hermes-gateway-adapter.mjs',
    'openclaw-gateway-adapter.mjs',
    'pty-compatibility-adapter.mjs',
  ]) {
    const source = await readFile(new URL(`../${file}`, import.meta.url), 'utf8');
    assert.match(source, /from '\.\/context-handoff\.mjs'/);
    assert.doesNotMatch(source, /from '\.\/codex-bridge\.mjs'/);
  }
});
