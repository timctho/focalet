import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline';
import test, { after, before } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildContextHandoff } from '../context-handoff.mjs';

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const executable = join(repositoryRoot, 'target', 'debug', process.platform === 'win32' ? 'zommi-core-host.exe' : 'zommi-core-host');
let core;
let nextId = 0;
const pending = new Map();

before(() => {
  assert.ok(existsSync(executable), 'Build zommi-core-host before running Electron parity tests.');
  core = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  createInterface({ input: core.stdout }).on('line', (line) => {
    const response = JSON.parse(line);
    const completion = pending.get(response.id);
    if (!completion) return;
    pending.delete(response.id);
    if (response.ok) completion.resolve(response.result);
    else completion.reject(new Error(`${response.error?.code}: ${response.error?.message}`));
  });
  core.once('exit', (code) => {
    for (const completion of pending.values()) completion.reject(new Error(`Rust core exited with ${code}.`));
    pending.clear();
  });
});

after(async () => {
  if (!core || core.exitCode !== null) return;
  await request('core.shutdown');
});

test('Rust Context Handoff is byte-identical to the JavaScript contract fixtures', async () => {
  const fixtures = [
    { message: '  plain question  ', snapshots: [], imageCount: 0 },
    {
      message: 'compare this',
      snapshots: [{
        observedAtUtc: '2026-08-28T00:00:00Z',
        surfaceKind: 'Browser',
        application: 'Edge',
        selection: ['selected value'],
        windowTitle: 'Report',
        locator: { kind: 'URL', value: 'https://example.test/report' },
        accessibilityTree: { roots: [{ role: 'Table', name: 'Results' }] },
        indicatedTarget: { controlType: 'Button', name: 'Details' },
      }],
      imageCount: 1,
    },
    {
      message: 'inspect selection',
      snapshots: [{
        surfaceKind: 'Window',
        application: 'Sheets',
        selectionElements: [{
          controlType: 'GoogleSheetsRange', name: 'B2:C3', value: '42', formula: '=SUM(A1:A2)', bounds: '10,20 40x50', row: 2, column: 2,
        }],
        selectionElementCount: 3,
        accessibilityTree: {
          truncated: true,
          roots: [{ role: 'Pane', children: [{ role: 'Table', name: 'Budget', rowCount: 4 }] }],
        },
        visibleText: ['Budget', 'Additional value'],
      }],
      imageCount: 0,
    },
    {
      message: 'compare contexts',
      snapshots: [
        { surfaceKind: 'Window', application: 'Editor', visibleText: ['safe\u0000\u202e value'] },
        { surfaceKind: 'Browser', application: 'Chrome', indicatedTarget: { controlType: 'Cell', row: 4, bounds: '1,2 3x4' } },
      ],
      imageCount: 2,
    },
  ];

  for (const fixture of fixtures) {
    const expected = buildContextHandoff(fixture.message, fixture.snapshots, fixture.imageCount);
    const result = await request('context.buildHandoff', fixture);
    assert.equal(result.text, expected);
  }
});

function request(operation, payload = {}) {
  const id = String(++nextId);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    core.stdin.write(`${JSON.stringify({ id, protocolVersion: 1, operation, payload })}\n`, (error) => {
      if (!error) return;
      pending.delete(id);
      reject(error);
    });
  });
}
