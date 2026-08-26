import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
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

test('Zommi launches Codex without overriding agent tools, providers, or permissions', async () => {
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  for (const source of [portableBridge, windowsBridge]) {
    assert.doesNotMatch(source, /approvalPolicy\s*[:=]\s*['"]never/);
    assert.doesNotMatch(source, /sandbox\s*[:=]\s*['"]read-only/);
    assert.doesNotMatch(source, /mcp_servers\.|model_providers\.|zommiChrome|ChromeDevToolsBrowser/);
  }
  assert.match(portableBridge, /spawnProcess\(command, \['app-server'\]/);
  assert.match(windowsBridge, /ArgumentList\.Add\("cd \\"\$HOME\\" && exec codex app-server"\)/);
});

test('Zommi source and packager do not contain a product-owned browser tool runtime', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  const windowsPackager = await readFile(join(repositoryRoot, 'scripts', 'package-windows.ps1'), 'utf8');
  assert.doesNotMatch(packager, /browser-mcp|chrome-devtools-mcp/i);
  assert.doesNotMatch(windowsPackager, /browser-mcp|chrome-devtools-mcp|Zommi\.ChromeMcp/i);
  await assert.rejects(access(join(appDirectory, 'browser-mcp', 'package.json')));
  await assert.rejects(access(join(repositoryRoot, 'scripts', 'Zommi.ChromeMcp.sh')));
  await assert.rejects(access(join(appDirectory, '..', 'Zommi.Windows', 'ChromeDevToolsBrowser.cs')));
});

test('Codex startup timeouts reset the connection and preserve actionable errors', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  assert.match(windowsBridge, /StartupRequestTimeout\s*=\s*TimeSpan\.FromSeconds\(120\)/);
  assert.match(windowsBridge, /ResetConnection\(candidate\)/);
  assert.match(windowsBridge, /did not respond to '\{method\}'/);
  assert.match(main, /isWarningStatus\(status\)/);
  assert.match(renderer, /!status\.classList\.contains\('warning'\)/);
});

test('glass surfaces hide transcript, preview, composer, and chip scrollbars', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(styles, /scrollbar-width:\s*none/);
  assert.match(styles, /\.transcript::\-webkit-scrollbar/);
  assert.match(styles, /\.context-preview pre::\-webkit-scrollbar/);
  assert.match(styles, /\.context-chips::\-webkit-scrollbar/);
});
