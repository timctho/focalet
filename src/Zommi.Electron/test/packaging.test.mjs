import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const appDirectory = join(dirname(fileURLToPath(import.meta.url)), '..');

test('Electron startup does not await readiness from top-level module evaluation', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.doesNotMatch(main, /\bawait\s+startApplication\s*\(/);
  assert.match(main, /void\s+startApplication\(\)\.catch/);
});

test('sandboxed windows use packaged CommonJS preload bridges', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const selector = await readFile(join(appDirectory, 'image-selector.mjs'), 'utf8');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  assert.match(main, /preload\.cjs/);
  assert.match(selector, /selection.*preload\.cjs/);
  assert.match(packager, /preload\.cjs/);
});

test('Zommi does not override the configured Codex agent permissions or tools', async () => {
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  for (const source of [portableBridge, windowsBridge]) {
    assert.doesNotMatch(source, /approvalPolicy\s*[:=]\s*['"]never/);
    assert.doesNotMatch(source, /sandbox\s*[:=]\s*['"]read-only/);
    assert.match(source, /configured tools, MCP servers, plugins, and permissions remain available/);
  }
});

test('Windows Chrome MCP keeps stdio inside WSL Node and connects over loopback CDP', async () => {
  const wrapper = await readFile(join(appDirectory, '..', '..', 'scripts', 'Zommi.ChromeMcp.sh'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  const chromeHost = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'ChromeDevToolsBrowser.cs'), 'utf8');
  assert.match(wrapper, /exec node/);
  assert.match(wrapper, /--browser-url="http:\/\/127\.0\.0\.1:\$cdp_port"/);
  assert.doesNotMatch(wrapper, /\/init|ELECTRON_RUN_AS_NODE|wslpath/);
  assert.match(windowsBridge, /ChromeDevToolsBrowser\.StartAsync/);
  assert.match(windowsBridge, /mcp_servers\.zommiChrome\.required=true/);
  assert.match(chromeHost, /--headless=new/);
  assert.match(chromeHost, /--remote-debugging-address=127\.0\.0\.1/);
});

test('glass surfaces hide transcript, preview, composer, and chip scrollbars', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(styles, /scrollbar-width:\s*none/);
  assert.match(styles, /\.transcript::\-webkit-scrollbar/);
  assert.match(styles, /\.context-preview pre::\-webkit-scrollbar/);
  assert.match(styles, /\.context-chips::\-webkit-scrollbar/);
});
