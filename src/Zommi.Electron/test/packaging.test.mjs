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
  assert.match(windowsBridge, /CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_cli_rs exec codex app-server/);
  assert.match(portableBridge, /CODEX_INTERNAL_ORIGINATOR_OVERRIDE:[\s\S]*codex_cli_rs/);
});

test('Zommi source and packager do not contain a product-owned browser tool runtime', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  const windowsPackager = await readFile(join(repositoryRoot, 'scripts', 'package-windows.ps1'), 'utf8');
  assert.doesNotMatch(packager, /browser-mcp|chrome-devtools-mcp/i);
  assert.doesNotMatch(windowsPackager, /browser-mcp|chrome-devtools-mcp|Zommi\.ChromeMcp/i);
  assert.match(windowsPackager, /resources\/app\/main\.mjs/);
  assert.match(windowsPackager, /resources\/app\/renderer\/renderer\.mjs/);
  assert.match(windowsPackager, /--artifacts-path \$dotnetArtifactsDirectory/);
  assert.match(windowsPackager, /wsl\.exe -d \$wslDistro -e sh -lc/);
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

test('light liquid glass adapts to each display and clips the native window corners', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(main, /nativeTheme\.themeSource\s*=\s*'light'/);
  assert.match(main, /useContentSize:\s*true/);
  assert.match(main, /zoomFactor:\s*1/);
  assert.match(main, /calculateAdaptiveWindowSize\(display\.workArea, expanded\)/);
  assert.match(main, /screen\.on\('display-metrics-changed'/);
  assert.match(main, /setContentSize\(size\.width, size\.height/);
  assert.match(main, /roundedCorners:\s*false/);
  assert.match(main, /hasShadow:\s*false/);
  assert.match(main, /mainWindow\.setShape\(rectangles\)/);
  assert.doesNotMatch(main, /setBackgroundMaterial\('acrylic'\)/);
  assert.match(styles, /color-scheme:\s*light/);
  assert.match(styles, /\.glass\s*\{[\s\S]*width:\s*100%[\s\S]*height:\s*100%/);
  assert.doesNotMatch(styles, /\.glass\s*\{[\s\S]{0,200}margin:\s*12px/);
});

test('scrollbars stay quiet until their scrollable surface is hovered', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(styles, /scrollbar-color:\s*transparent transparent/);
  assert.match(styles, /\.transcript::\-webkit-scrollbar/);
  assert.match(styles, /\.transcript:hover::\-webkit-scrollbar-thumb/);
  assert.match(styles, /\.context-preview pre:hover::\-webkit-scrollbar-thumb/);
  assert.match(styles, /\.context-chips:hover::\-webkit-scrollbar-thumb/);
});

test('conversation history renders every user turn without a singleton overlay', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.doesNotMatch(html, /QueryBubble/);
  assert.match(renderer, /turnNumber \+= 1/);
  assert.match(renderer, /className = 'conversation-turn'/);
  assert.match(renderer, /User message turn \$\{turnNumber\}/);
  assert.match(renderer, /className = `activity-card \$\{kind\}`/);
});

test('model and session controls use Codex app-server catalogs and resumable threads', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  assert.match(html, /id="SessionSidebar"/);
  assert.match(html, /id="ModelPanel"/);
  assert.match(renderer, /window\.zommi\.createSession/);
  assert.match(renderer, /window\.zommi\.switchSession/);
  assert.match(renderer, /model:\s*selectedModel/);
  assert.match(renderer, /effort:\s*selectedEffort/);
  for (const source of [portableBridge, windowsBridge]) {
    assert.match(source, /model\/list/);
    assert.match(source, /thread\/list/);
    assert.match(source, /thread\/resume/);
    assert.match(source, /threadSource.*zommi/s);
  }
});

test('blank glass regions use native dragging and movement turns off expensive blur', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.match(styles, /\.glass\s*\{[\s\S]*-webkit-app-region:\s*drag/);
  assert.match(styles, /\.drag-ready\s*\{\s*-webkit-app-region:\s*drag/);
  assert.match(styles, /body\.window-moving[\s\S]*backdrop-filter:\s*none/);
  assert.match(renderer, /updateBackgroundDragSurface/);
  assert.match(main, /mainWindow\.on\('will-move'/);
});

test('streaming preserves manual scroll position and exposes a latest-message control', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(html, /id="ScrollToLatest"/);
  assert.match(renderer, /if \(!force && !autoFollow\)/);
  assert.match(renderer, /isNearBottom\(transcript\)/);
});

test('Alt+Shift+A combines the selected image with shortcut-time pointer context', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(main, /Alt\+Shift\+A[\s\S]*includePointerContext:\s*true/);
  assert.match(main, /pointerContext = await capturePointerContext\(\)/);
  assert.match(main, /snapshot:\s*pointerContext\?\.snapshot \|\| null/);
  assert.match(renderer, /attachment\.snapshot && !attachment\.imageDataUrl/);
  assert.match(renderer, /previewText\.hidden = !attachment\.previewText/);
});
