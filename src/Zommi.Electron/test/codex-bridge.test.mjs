import assert from 'node:assert/strict';
import test from 'node:test';
import { buildTurnText, compactAccessibilityTree } from '../codex-bridge.mjs';

test('structured browser context remains nested JSON without inferred markdown', () => {
  const context = buildTurnText('what is this?', [{
    observedAtUtc: '2026-08-25T00:00:00Z',
    surfaceKind: 'Browser',
    application: 'Edge',
    windowTitle: 'Usage',
    locator: { kind: 'URL', value: 'https://example.test/report' },
    selection: ['SELECTED_TEXT_IS_PRIMARY'],
    visibleText: ['flat fallback must not duplicate'],
    accessibilityTree: {
      source: 'windows-uia-control-view', nodeCount: 2, truncated: false,
      roots: [{ role: 'Table', name: 'Accounts', children: [{ role: 'DataItem', name: 'example', row: 1, column: 0 }] }],
    },
  }]);
  assert.match(context, /PRIMARY SELECTION/);
  assert.match(context, /"role": "Table"/);
  assert.match(context, /"row": 1/);
  assert.doesNotMatch(context, /windows-uia-control-view/);
  assert.doesNotMatch(context, /nodeCount/);
  assert.doesNotMatch(context, /flat fallback must not duplicate/);
  assert.doesNotMatch(context, /\|\s*Accounts\s*\|/);
  assert.doesNotMatch(context, /image regions attached/i);
});

test('accessibility payload keeps semantic structure while dropping capture metadata', () => {
  const compact = compactAccessibilityTree({
    source: 'windows-uia-control-view', nodeCount: 9, truncated: true,
    roots: [{
      role: 'Table', name: 'Accounts', value: 'Accounts', automationId: 'grid-42',
      bounds: '1,2,300,400', isOffscreen: false, rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', row: 1, column: 0, rowSpan: 1 }],
    }],
  });
  assert.deepEqual(compact, {
    roots: [{
      role: 'Table', name: 'Accounts', rowCount: 2, columnCount: 2,
      children: [{ role: 'DataItem', name: 'example', row: 1, column: 0 }],
    }],
    truncated: true,
  });
});

test('image note appears only for explicit selected images', () => {
  const withoutImage = buildTurnText('hello', [], 0);
  assert.equal(withoutImage, 'hello');
  const withImage = buildTurnText('hello', [], 1);
  assert.match(withImage, /User-selected image regions attached: 1/);
});
