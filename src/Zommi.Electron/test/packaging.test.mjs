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

test('packaged acceptance scripts separate Electron options from application flags', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const uiContract = await readFile(join(repositoryRoot, 'scripts', 'test-windows-ui-contract.ps1'), 'utf8');
  const sendAcceptance = await readFile(join(repositoryRoot, 'scripts', 'test-windows-send-acceptance.ps1'), 'utf8');
  assert.match(uiContract, /'--force-renderer-accessibility',\s*'--',\s*'--acceptance-ui-seeded'/);
  assert.match(sendAcceptance, /'--',\s*'--no-auto-launch'/);
});

test('Windows verification and deployment do not inherit Electron host node mode', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const uiContract = await readFile(join(repositoryRoot, 'scripts', 'test-windows-ui-contract.ps1'), 'utf8');
  const deploy = await readFile(join(repositoryRoot, 'scripts', 'deploy-windows-downloads.ps1'), 'utf8');
  for (const source of [uiContract, deploy]) {
    assert.match(source, /Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue/);
  }
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

test('light liquid glass adapts to each display and uses inset alpha-antialiased corners', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(main, /nativeTheme\.themeSource\s*=\s*'light'/);
  assert.match(main, /useContentSize:\s*true/);
  assert.match(main, /zoomFactor:\s*1/);
  assert.match(main, /calculateAdaptiveWindowSize\(display\.workArea, expanded\)/);
  assert.match(main, /screen\.on\('display-metrics-changed'/);
  assert.match(main, /setContentSize\(size\.width, size\.height/);
  assert.match(main, /roundedCorners:\s*true/);
  assert.match(main, /hasShadow:\s*false/);
  assert.match(main, /backgroundColor:\s*'#00000000'/);
  assert.doesNotMatch(main, /\.setShape\(/);
  assert.match(main, /createZommiIcon\(\)/);
  assert.match(main, /image\/svg\+xml/);
  assert.doesNotMatch(main, /iVBORw0KGgoAAAANSUhEUgAAAA4AAAAO/);
  assert.doesNotMatch(main, /setBackgroundMaterial\('acrylic'\)/);
  assert.match(styles, /color-scheme:\s*light/);
  assert.match(styles, /\.glass\s*\{[\s\S]*position:\s*absolute;[\s\S]*inset:\s*8px/);
  assert.doesNotMatch(styles, /clip-path:/);
  assert.doesNotMatch(styles, /backdrop-filter:/);
});

test('scrollbars stay quiet until their scrollable surface is hovered', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(styles, /scrollbar-color:\s*transparent transparent/);
  assert.match(styles, /\.transcript::\-webkit-scrollbar/);
  assert.match(styles, /\.transcript:hover::\-webkit-scrollbar-thumb/);
  assert.match(styles, /\.context-preview pre:hover::\-webkit-scrollbar-thumb/);
  assert.match(styles, /\.context-chips:hover::\-webkit-scrollbar-thumb/);
});

test('conversation history renders user turns in bounded upward-loading pages', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.doesNotMatch(html, /QueryBubble/);
  assert.match(renderer, /HISTORY_PAGE_SIZE = 18/);
  assert.match(renderer, /initialHistoryStart\(historyTurns\.length, HISTORY_PAGE_SIZE\)/);
  assert.match(renderer, /requestAnimationFrame\(loadOlderHistory\)/);
  assert.match(renderer, /transcript\.scrollTop = previousTop \+ transcript\.scrollHeight - previousHeight/);
  assert.match(renderer, /className = 'conversation-turn'/);
  assert.match(renderer, /User message turn \$\{displayTurnNumber\}/);
  assert.match(renderer, /className = `activity-card \$\{kind\}`/);
});

test('model and session controls use Codex app-server catalogs and resumable threads', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  assert.match(html, /id="SessionSidebar"/);
  assert.match(html, /id="ModelPanel"/);
  assert.match(html, /id="ModelSearch"/);
  assert.match(html, /id="ModelList"/);
  assert.match(html, /id="EffortList"/);
  assert.doesNotMatch(html, /id="ModelSelect"|id="EffortSelect"/);
  assert.match(renderer, /window\.zommi\.createSession/);
  assert.match(renderer, /window\.zommi\.switchSession/);
  assert.match(renderer, /toggleSessions\.addEventListener\('mouseenter', openSessionSidebarFromHover\)/);
  assert.match(renderer, /button\.dataset\.status = state/);
  assert.match(renderer, /button\.disabled = sessionBusy \|\| session\.id === activeThreadId/);
  assert.doesNotMatch(renderer, /sessionBusy \|\| turnActive \|\| threadId === activeThreadId/);
  assert.match(renderer, /model:\s*selectedModel/);
  assert.match(renderer, /effort:\s*selectedEffort/);
  for (const source of [portableBridge, windowsBridge]) {
    assert.match(source, /model\/list/);
    assert.match(source, /thread\/list/);
    assert.match(source, /thread\/resume/);
    assert.match(source, /threadSource.*zommi/s);
    assert.match(source, /activeTurns/);
  }
  assert.match(styles, /height:\s*min\(50%, 410px\)/);
});

test('blank glass regions use native dragging without move-time renderer work', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const glassRule = styles.match(/\.glass\s*\{([^}]*)\}/)?.[1];
  assert.ok(glassRule, 'The root glass rule is missing.');
  assert.doesNotMatch(glassRule, /-webkit-app-region/);
  assert.match(styles, /\.titlebar\s*\{[\s\S]*?-webkit-app-region:\s*drag/);
  assert.match(styles, /\.background-drag\s*\{[\s\S]*?inset:\s*0;[\s\S]*?-webkit-app-region:\s*drag/);
  assert.doesNotMatch(styles, /\.edge-drag\s*\{/);
  assert.doesNotMatch(styles, /\.transcript::after/);
  for (const selector of ['.welcome', '.conversation-turn', '.turn-body', '.message-row']) {
    const escaped = selector.replace('.', '\\.');
    const rule = styles.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] || '';
    assert.doesNotMatch(rule, /-webkit-app-region:\s*drag/, `${selector} must remain interactive.`);
  }
  assert.match(styles, /transition:\s*opacity 460ms cubic-bezier/);
  assert.match(styles, /\.glass:hover::after,\s*\.glass\.pointer-over::after\s*\{\s*opacity:\s*0\.58/);
  assert.match(renderer, /glass\.classList\.toggle\('pointer-over', pointerOver\)/);
  assert.doesNotMatch(styles, /window-moving/);
  assert.doesNotMatch(renderer, /updateBackgroundDragSurface|drag-ready/);
  assert.doesNotMatch(main, /mainWindow\.on\('will-move'|mainWindow\.on\('move'/);
});

test('stream updates are frame-batched and thinking changes one status icon in place', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(html, /id="ModelSummary"[\s\S]*id="SendMessage"/);
  assert.match(renderer, /window\.zommi\.onStream\(queueStreamUpdate\)/);
  assert.match(renderer, /requestAnimationFrame\(flushStreamUpdates\)/);
  assert.match(renderer, /activityKey\(kind, update\.itemId, update\.title\)/);
  assert.match(renderer, /setActivityState\(activity\.state, true\)/);
  assert.match(renderer, /replaceChildren\(createUiIcon\(completed \? 'check' : 'spinner'\)\)/);
  assert.doesNotMatch(renderer, /activity\.state\.textContent\s*=/);
});

test('glass rendering avoids full-window blur and culls long offscreen turns', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.doesNotMatch(styles, /backdrop-filter:/);
  assert.doesNotMatch(styles, /(?:^|\n)\s*filter:\s*blur\(/);
  assert.match(styles, /overflow-anchor:\s*none/);
  assert.match(styles, /content-visibility:\s*auto/);
  assert.match(styles, /contain-intrinsic-size:\s*auto 220px/);
});

test('streaming send control becomes a stop control backed by Codex turn interruption', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const preload = await readFile(join(appDirectory, 'preload.cjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const windowsBridge = await readFile(join(appDirectory, '..', 'Zommi.Windows', 'CodexAppServerClient.cs'), 'utf8');
  assert.match(html, /class="ui-icon stop-icon"/);
  assert.match(preload, /interrupt:\s*\(\)\s*=>\s*ipcRenderer\.invoke\('chat:interrupt'\)/);
  assert.match(renderer, /window\.zommi\.interrupt\(\)/);
  assert.match(renderer, /setAttribute\('aria-label', turnActive \? 'Stop response' : 'Send message'\)/);
  assert.match(main, /ipcMain\.handle\('chat:interrupt'/);
  assert.match(portableBridge, /#request\('turn\/interrupt', \{ threadId, turnId \}\)/);
  assert.match(windowsBridge, /"turn\/interrupt"[\s\S]*new \{ threadId, turnId \}/);
});

test('streaming preserves manual scroll position and exposes a latest-message control', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(html, /id="ScrollToLatest"/);
  assert.match(renderer, /if \(!force && !autoFollow\)/);
  assert.match(renderer, /transcript\.addEventListener\('wheel', handleTranscriptWheel/);
  assert.match(renderer, /if \(programmaticScroll && nearBottom\) return/);
  assert.match(renderer, /if \(!event\.deltaY\) return;[\s\S]*autoFollow = false/);
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
