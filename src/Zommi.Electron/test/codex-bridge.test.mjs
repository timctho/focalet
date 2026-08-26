import assert from 'node:assert/strict';
import test from 'node:test';
import { buildAppServerArguments, buildTurnText } from '../codex-bridge.mjs';

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
  assert.doesNotMatch(context, /flat fallback must not duplicate/);
  assert.doesNotMatch(context, /\|\s*Accounts\s*\|/);
  assert.doesNotMatch(context, /image regions attached/i);
});

test('packaged Codex app-server receives the bundled Chrome MCP configuration', () => {
  const args = buildAppServerArguments({
    electronExecutable: '/Applications/Zommi.app/Contents/MacOS/Zommi',
    browserMcpScript: '/Applications/Zommi.app/Contents/Resources/browser-mcp/chrome-devtools-mcp.js',
  });
  assert.equal(args[0], 'app-server');
  assert.ok(args.some((value) => value.includes('mcp_servers.zommiChrome.command=')));
  assert.ok(args.some((value) => value.includes('ELECTRON_RUN_AS_NODE')));
  assert.ok(args.includes('mcp_servers.zommiChrome.required=true'));
  assert.ok(args.includes('mcp_servers.zommiChrome.tool_timeout_sec=120'));
});

test('image note appears only for explicit selected images', () => {
  const withoutImage = buildTurnText('hello', [], 0);
  assert.equal(withoutImage, 'hello');
  const withImage = buildTurnText('hello', [], 1);
  assert.match(withImage, /User-selected image regions attached: 1/);
});
