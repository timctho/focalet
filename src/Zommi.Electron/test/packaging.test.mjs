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

test('application resume triggers TTL-aware runtime rediscovery without blocking capture', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const broker = await readFile(join(appDirectory, 'runtime-broker.mjs'), 'utf8');
  assert.match(main, /powerMonitor\.on\('resume', powerResumeHandler\)/);
  assert.match(main, /backend\.rediscoverTargets\(\)/);
  assert.match(broker, /discovery\.discover\(\{ force: false \}\)/);
});

test('packaged acceptance scripts separate Electron options from application flags', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const uiContract = await readFile(join(repositoryRoot, 'scripts', 'test-windows-ui-contract.ps1'), 'utf8');
  const sendAcceptance = await readFile(join(repositoryRoot, 'scripts', 'test-windows-send-acceptance.ps1'), 'utf8');
  const runtimeAcceptance = await readFile(join(repositoryRoot, 'scripts', 'test-windows-electron-runtime.ps1'), 'utf8');
  assert.match(uiContract, /'--force-renderer-accessibility',\s*'--',\s*'--acceptance-ui-seeded'/);
  assert.match(sendAcceptance, /'--force-renderer-accessibility'/);
  assert.doesNotMatch(sendAcceptance, /--no-auto-launch/);
  assert.match(sendAcceptance, /single-instance activation/);
  assert.match(runtimeAcceptance, /--user-data-dir=\$zommiProfile/);
  assert.match(runtimeAcceptance, /zeroConfigCodexDiscovery/);
});

test('Windows verification and deployment do not inherit Electron host node mode', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const uiContract = await readFile(join(repositoryRoot, 'scripts', 'test-windows-ui-contract.ps1'), 'utf8');
  const deploy = await readFile(join(repositoryRoot, 'scripts', 'deploy-windows-downloads.ps1'), 'utf8');
  for (const source of [uiContract, deploy]) {
    assert.match(source, /Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue/);
  }
});

test('Windows deployment stops the capture host before replacing its package directory', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const deploy = await readFile(join(repositoryRoot, 'scripts', 'deploy-windows-downloads.ps1'), 'utf8');
  assert.match(deploy, /function Get-TargetDirectoryProcesses/);
  assert.match(deploy, /\.StartsWith\(\s*\$directoryPrefix,\s*\[StringComparison\]::OrdinalIgnoreCase\)/);
  assert.match(deploy, /\$targetProcesses = @\(Get-TargetDirectoryProcesses \$targetDirectory\)/);
  assert.match(deploy, /if \(@\(Get-TargetDirectoryProcesses \$targetDirectory\)\.Count -ne 0\)/);
  assert.match(deploy, /foreach \(\$process in \(Get-TargetDirectoryProcesses \$targetDirectory\)\)/);
});

test('sandboxed windows use packaged CommonJS preload bridges', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const selector = await readFile(join(appDirectory, 'image-selector.mjs'), 'utf8');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  assert.match(main, /preload\.cjs/);
  assert.match(selector, /selection.*preload\.cjs/);
  assert.match(selector, /show:\s*false/);
  assert.match(selector, /setAlwaysOnTop\(true, 'screen-saver'\)/);
  assert.match(packager, /preload\.cjs/);
});

test('structured runtime questions cross the main and renderer boundary without losing target identity', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const preload = await readFile(join(appDirectory, 'preload.cjs'), 'utf8');
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(main, /backend\.on\('questionRequested'.*question:requested/);
  assert.match(main, /ipcMain\.handle\('question:resolve'/);
  assert.match(preload, /resolveQuestion:.*question:resolve/);
  assert.match(preload, /onQuestionRequested:.*question:requested/);
  assert.match(html, /id="QuestionPanel"[\s\S]*id="QuestionInput"/);
  assert.match(html, /id="QuestionSecretInput"[\s\S]*type="password"/);
  assert.match(renderer, /runtimeTargetId: request\.runtimeTargetId/);
  assert.match(renderer, /method === 'confirm'[\s\S]*method === 'select'/);
  assert.match(renderer, /renderStructuredQuestions/);
  assert.match(renderer, /update\.replace \? update\.text/);
});

test('Zommi launches Codex without overriding agent tools, providers, or permissions', async () => {
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const runtimeCatalog = await readFile(join(appDirectory, 'runtime-catalog.mjs'), 'utf8');
  const runtimeBroker = await readFile(join(appDirectory, 'runtime-broker.mjs'), 'utf8');
  for (const source of [portableBridge, runtimeCatalog, runtimeBroker]) {
    assert.doesNotMatch(source, /approvalPolicy\s*[:=]\s*['"]never/);
    assert.doesNotMatch(source, /sandbox\s*[:=]\s*['"]read-only/);
    assert.doesNotMatch(source, /mcp_servers\.|model_providers\.|zommiChrome|ChromeDevToolsBrowser/);
  }
  assert.match(runtimeCatalog, /id: 'codex-app-server'[\s\S]*launchArgs: Object\.freeze\(\['app-server'\]\)/);
  assert.match(runtimeBroker, /commandForTarget\(target, entry\)/);
  assert.match(portableBridge, /CODEX_INTERNAL_ORIGINATOR_OVERRIDE:[\s\S]*codex_exec/);
  assert.doesNotMatch(portableBridge, /codex_cli_rs/);
});

test('Zommi source and packager do not contain a product-owned browser tool runtime', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  const windowsPackager = await readFile(join(repositoryRoot, 'scripts', 'package-windows.ps1'), 'utf8');
  assert.doesNotMatch(packager, /browser-mcp|chrome-devtools-mcp/i);
  assert.doesNotMatch(windowsPackager, /browser-mcp|chrome-devtools-mcp|Zommi\.ChromeMcp/i);
  assert.match(windowsPackager, /resources\/app\/main\.mjs/);
  assert.match(windowsPackager, /resources\/app\/window-layout\.mjs/);
  assert.match(windowsPackager, /resources\/app\/renderer\/styles\.css/);
  assert.match(windowsPackager, /resources\/app\/renderer\/renderer\.mjs/);
  assert.match(packager, /runtime-catalog\.mjs/);
  assert.match(packager, /runtime-discovery\.mjs/);
  assert.match(packager, /runtime-settings\.mjs/);
  assert.match(packager, /runtime-broker\.mjs/);
  assert.match(packager, /broker-protocol\.mjs/);
  assert.match(packager, /context-handoff\.mjs/);
  assert.match(packager, /protocol-framing\.mjs/);
  assert.match(packager, /adapter-diagnostics\.mjs/);
  assert.match(packager, /transport-metrics\.mjs/);
  assert.match(packager, /hermes-gateway-adapter\.mjs/);
  assert.match(packager, /openclaw-gateway-adapter\.mjs/);
  assert.match(packager, /pty-compatibility-adapter\.mjs/);
  assert.match(packager, /pty-profiles\.mjs/);
  assert.match(packager, /copyRuntimeDependencies/);
  assert.doesNotMatch(packager, /WSL_DISTRO_NAME|wsl-distro\.txt/);
  assert.match(windowsPackager, /--artifacts-path \$dotnetArtifactsDirectory/);
  assert.doesNotMatch(windowsPackager, /IncludeNativeLibrariesForSelfExtract=true/);
  assert.doesNotMatch(windowsPackager, /PublishSingleFile=true/);
  assert.match(windowsPackager, /wsl\.exe -d \$wslDistro -e sh -lc/);
  assert.match(windowsPackager, /resources\/app\/runtime-catalog\.mjs/);
  assert.match(windowsPackager, /resources\/app\/runtime-discovery\.mjs/);
  assert.match(windowsPackager, /resources\/app\/runtime-settings\.mjs/);
  assert.match(windowsPackager, /resources\/app\/runtime-broker\.mjs/);
  assert.match(windowsPackager, /resources\/app\/broker-protocol\.mjs/);
  assert.match(windowsPackager, /resources\/app\/context-handoff\.mjs/);
  assert.match(windowsPackager, /resources\/app\/protocol-framing\.mjs/);
  assert.match(windowsPackager, /resources\/app\/adapter-diagnostics\.mjs/);
  assert.match(windowsPackager, /resources\/app\/transport-metrics\.mjs/);
  assert.match(windowsPackager, /resources\/app\/hermes-gateway-adapter\.mjs/);
  assert.match(windowsPackager, /resources\/app\/openclaw-gateway-adapter\.mjs/);
  assert.match(windowsPackager, /resources\/app\/pty-compatibility-adapter\.mjs/);
  assert.match(windowsPackager, /resources\/app\/pty-profiles\.mjs/);
  await assert.rejects(access(join(appDirectory, 'browser-mcp', 'package.json')));
  await assert.rejects(access(join(repositoryRoot, 'scripts', 'Zommi.ChromeMcp.sh')));
  await assert.rejects(access(join(appDirectory, '..', 'Zommi.Windows', 'ChromeDevToolsBrowser.cs')));
});

test('Codex startup timeouts reset the connection and preserve actionable errors', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const nativeHost = await readFile(join(appDirectory, 'native-host.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const portableBridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const runtimeBroker = await readFile(join(appDirectory, 'runtime-broker.mjs'), 'utf8');
  assert.match(portableBridge, /DEFAULT_REQUEST_TIMEOUT_MS\s*=\s*30_000/);
  assert.match(portableBridge, /did not respond to '\$\{method\}'/);
  assert.match(portableBridge, /this\.startPromise = null/);
  assert.match(runtimeBroker, /classifyRuntimeError\(error\)/);
  assert.match(runtimeBroker, /discovery\.invalidateTarget\(target\)/);
  assert.match(nativeHost, /DEFAULT_REQUEST_TIMEOUT_MS\s*=\s*30_000/);
  assert.match(nativeHost, /did not respond to '\$\{method\}'/);
  assert.match(main, /runtime-status/);
  assert.match(main, /chatControlsLeaveLoading/);
  assert.match(main, /zommi-runtime\.log/);
  assert.match(main, /writeRuntimeLog\('chat-state'/);
  assert.match(main, /writeRuntimeLog\('chat-send'/);
  assert.match(main, /writeRuntimeLog\('turn-completed'/);
  assert.match(renderer, /modelSummaryLabel\.textContent = chatControlsLoading \? 'Connecting…' : 'Retry'/);
  const initializeControls = renderer.match(/async function initializeChatControls\(\)[\s\S]*?\n\}/)?.[0] || '';
  assert.doesNotMatch(initializeControls, /composer\.disabled\s*=\s*true/);
  assert.doesNotMatch(renderer, /composer\.disabled\s*=\s*(?:true|[^;]*turnActive)/);
  assert.match(main, /composerEditableWhileStreaming/);
  assert.match(main, /composerAcceptsDraftWhileStreaming/);
  assert.match(renderer, /No agent session is ready\. Choose or refresh an agent/);
  assert.match(renderer, /\\bready\\b/);
  assert.match(renderer, /!status\.classList\.contains\('warning'\)/);
});

test('light liquid glass adapts to each display and uses inset alpha-antialiased corners', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  assert.match(main, /nativeTheme\.themeSource\s*=\s*'light'/);
  assert.match(main, /useContentSize:\s*true/);
  assert.match(main, /zoomFactor:\s*1/);
  assert.match(main, /calculateAdaptiveWindowSize\(display\.workArea, largePanel\)/);
  assert.match(main, /calculateAnchoredWindowBounds\(initialDisplay\.workArea, initialSize\)/);
  assert.match(main, /setIgnoreMouseEvents\(true, \{ forward: true \}\)/);
  assert.match(main, /calculateAnchoredWindowBounds\(display\.workArea, size\)/);
  assert.match(main, /screen\.on\('display-metrics-changed'/);
  assert.match(main, /mainWindow\.setBounds\(interpolateWindowBounds\(start, target, eased\), false\)/);
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
  assert.match(html, /id="SessionSidebar"/);
  assert.match(html, /id="ModelPanel"/);
  assert.match(html, /id="ModelSearch"/);
  assert.match(html, /id="ModelList"/);
  assert.match(html, /id="EffortList"/);
  assert.doesNotMatch(html, /id="ModelSelect"|id="EffortSelect"/);
  assert.ok(html.indexOf('id="RuntimeSummary"') < html.indexOf('id="ModelSummary"'));
  assert.ok(html.indexOf('id="ModelSummary"') < html.indexOf('class="drag-region"'));
  assert.ok(html.indexOf('id="ModelSummary"') < html.indexOf('class="composer-shell"'));
  assert.match(renderer, /window\.zommi\.createSession/);
  assert.match(renderer, /window\.zommi\.switchSession/);
  assert.match(renderer, /toggleSessions\.addEventListener\('mouseenter', openSessionSidebarFromHover\)/);
  assert.doesNotMatch(renderer, /toggleSessions\.addEventListener\('click'|sessionPanelPinned|toggleSessionSidebar/);
  assert.match(renderer, /button\.dataset\.status = state/);
  assert.match(renderer, /button\.disabled = sessionBusy \|\| session\.id === activeThreadId/);
  assert.doesNotMatch(renderer, /sessionBusy \|\| turnActive \|\| threadId === activeThreadId/);
  assert.match(renderer, /model:\s*selectedModel/);
  assert.match(renderer, /effort:\s*selectedEffort/);
  for (const source of [portableBridge]) {
    assert.match(source, /model\/list/);
    assert.match(source, /thread\/list/);
    assert.match(source, /thread\/resume/);
    assert.match(source, /threadSource.*zommi/s);
    assert.match(source, /activeTurns/);
  }
  assert.match(styles, /height:\s*min\(50%, 410px\)/);
});

test('zero-config runtime UX exposes discovery, deterministic selection, refresh, and sign-in recovery without a wizard', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const preload = await readFile(join(appDirectory, 'preload.cjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  for (const id of ['RuntimeSummary', 'RuntimePanel', 'RuntimeList', 'RefreshRuntimes', 'RuntimeSignIn']) {
    assert.match(html, new RegExp(`id="${id}"`));
  }
  assert.match(preload, /getRuntimeState:[\s\S]*runtime:state/);
  assert.match(preload, /refreshRuntimes:[\s\S]*runtime:refresh/);
  assert.match(preload, /selectRuntime:[\s\S]*runtime:select/);
  assert.match(preload, /signInRuntime:[\s\S]*runtime:sign-in/);
  assert.match(preload, /saveRuntimeOverride:[\s\S]*runtime:override-save/);
  assert.match(preload, /removeRuntimeOverride:[\s\S]*runtime:override-remove/);
  assert.match(preload, /probeTransport:[\s\S]*runtime:transport-probe/);
  assert.match(renderer, /window\.zommi\.getRuntimeState\(\)/);
  assert.match(renderer, /window\.zommi\.selectRuntime\(targetId\)/);
  assert.match(renderer, /target\.classification === 'compatible'/);
  assert.match(renderer, /activeCapabilities\.has\('model\.select\.v1'\)/);
  assert.match(renderer, /No supported agent found\. Capture remains available/);
  assert.match(renderer, /saveRuntimeTargetOverride/);
  assert.match(renderer, /removeRuntimeTargetOverride/);
  assert.match(main, /acceptance-transport-evidence/);
  assert.match(main, /rendererToProtocolWriteMilliseconds/);
  assert.doesNotMatch(`${html}\n${renderer}`, /setup wizard|first[- ]run wizard/i);
  assert.match(main, /new RuntimeDiscovery/);
  assert.match(main, /new RuntimeBroker/);
  assert.match(main, /forceDiscoveryOnInitialize:\s*true/);
  assert.match(main, /runtime-preferences\.json/);
});

test('Windows capture binds the exact shortcut-time pointer before showing the panel', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.match(main, /globalShortcut\.register\('Alt\+A', \(\) => captureContext\(\{ point: screen\.getCursorScreenPoint\(\) \}\)\)/);
  assert.match(main, /async function captureContext\(\{ point = screen\.getCursorScreenPoint\(\) \} = \{\}\)/);
  assert.match(main, /captureHost\.request\('capture', point \? \{ point \} : \{\}\)/);
  assert.match(main, /captureHost\.start\(\)/);
  assert.match(main, /captureHost\.request\('ping'\)/);
});

test('fixed translucent panel drags from whitespace without a visible handle or interactive regressions', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const preload = await readFile(join(appDirectory, 'preload.cjs'), 'utf8');
  const glassRule = styles.match(/\.glass\s*\{([^}]*)\}/)?.[1];
  const panelContentRule = styles.match(/\.panel-content\s*\{([^}]*)\}/)?.[1];
  assert.ok(glassRule, 'The root glass rule is missing.');
  assert.ok(panelContentRule, 'The panel content rule is missing.');
  assert.doesNotMatch(glassRule, /-webkit-app-region/);
  assert.doesNotMatch(panelContentRule, /-webkit-app-region/);
  assert.match(styles, /\.background-drag\s*\{[\s\S]*-webkit-app-region:\s*drag/);
  assert.match(styles, /\.titlebar\s*\{[\s\S]*position:\s*absolute/);
  assert.match(html, /class="panel-shell"/);
  assert.match(html, /id="ZommiOrb"/);
  assert.match(styles, /\.edge-drag\s*\{[\s\S]*-webkit-app-region:\s*drag/);
  assert.match(styles, /\.edge-drag-right\s*\{[^}]*width:\s*14px/);
  assert.match(styles, /\.edge-drag-left\s*\{[^}]*width:\s*14px/);
  assert.doesNotMatch(html, /edge-drag-top/);
  assert.doesNotMatch(styles, /\.edge-drag-top/);
  assert.match(html, /id="SessionSidebar" class="session-sidebar no-drag"/);
  assert.doesNotMatch(styles, /\.transcript::after/);
  for (const selector of ['.welcome', '.conversation-turn', '.turn-body', '.message-row']) {
    const escaped = selector.replace('.', '\\.');
    const rule = styles.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`))?.[1] || '';
    assert.doesNotMatch(rule, /-webkit-app-region:\s*drag/, `${selector} must remain interactive.`);
  }
  assert.match(styles, /\.panel-surface::after\s*\{[\s\S]*?opacity:\s*0\.24/);
  assert.doesNotMatch(styles, /\.(?:glass|panel-surface):hover::(?:before|after)/);
  assert.match(main, /setInterval\(\(\) => \{[\s\S]*screen\.getCursorScreenPoint\(\)[\s\S]*setWindowHovered\(inside\)[\s\S]*\}, 100\)/);
  assert.match(main, /send\('window:bounds-settled', \{ open: panelOpen \}\)/);
  assert.match(renderer, /panelContent\.addEventListener\('mousedown', startWhitespaceWindowDrag\)/);
  assert.match(renderer, /document\.addEventListener\('mousemove', queueWhitespaceWindowDrag\)/);
  assert.match(renderer, /event\.button !== 0 \|\| event\.target !== panelContent/);
  assert.match(renderer, /window\.zommi\.moveWindowDrag\(pendingWhitespaceDragPoint\)/);
  assert.doesNotMatch(renderer, /topDragHandle|edge-drag-top/);
  assert.match(preload, /beginWindowDrag:[\s\S]*window:drag-start/);
  assert.match(main, /ipcMain\.on\('window:drag-start'[\s\S]*beginManualWindowDrag/);
  assert.match(main, /whitespaceDragMovesWindow/);
  assert.doesNotMatch(renderer, /window\.zommi\.setWindowHovered\(pointerOver\)/);
  assert.match(renderer, /glass\.classList\.toggle\('is-compact', !open\)/);
  assert.doesNotMatch(styles, /window-moving/);
  assert.doesNotMatch(renderer, /updateBackgroundDragSurface/);
  assert.doesNotMatch(main, /mainWindow\.on\('will-move'|mainWindow\.on\('move'/);
});

test('Alt+A expands the anchored panel without cursor-relative window movement', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.match(main, /showWindow\(\{ openPanel: true, focusComposer: true \}\)/);
  const showWindowBody = main.match(/function showWindow\([^]*?\n\}/)?.[0] || '';
  assert.doesNotMatch(showWindowBody, /getCursorScreenPoint|setPosition/);
  assert.match(main, /HOVER_COLLAPSE_DELAY_MS\s*=\s*500/);
  assert.match(main, /setTimeout\(\(\) => setPanelOpen\(false\), HOVER_COLLAPSE_DELAY_MS\)/);
  assert.match(main, /const hitBounds = panelOpen \? bounds : compactHitBounds\(bounds\)/);
  const panelOpenBody = main.match(/function setPanelOpen\([^]*?\n\}/)?.[0] || '';
  assert.match(panelOpenBody, /if \(position\) mainWindow\.setBounds\(target, false\)/);
  assert.doesNotMatch(panelOpenBody, /!open\).*setBounds|if \([^)]*!open[^)]*\) mainWindow\.setBounds/);
});

test('generated images and HTML artifacts cross the adapter boundary into sandboxed chat previews', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const preload = await readFile(join(appDirectory, 'preload.cjs'), 'utf8');
  const bridge = await readFile(join(appDirectory, 'codex-bridge.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  assert.match(bridge, /artifactsFromThreadItem\(item, options\)/);
  assert.match(main, /ipcMain\.handle\('artifact:preview'/);
  assert.match(preload, /loadArtifactPreview:.*artifact:preview/);
  assert.match(renderer, /renderArtifacts\(update\.artifacts/);
  assert.match(renderer, /frame\.setAttribute\('sandbox', ''\)/);
  assert.match(html, /id="ArtifactViewer"/);
  assert.match(packager, /'artifacts\.mjs', 'artifact-preview\.mjs'/);
});

test('expanded artifact previews clear the top runtime and model selection controls', async () => {
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.match(styles, /\.artifact-viewer\s*\{[\s\S]*?inset:\s*64px 30px 30px/);
  assert.match(main, /artifactViewerClearsTopSelectionIcons/);
});

test('assistant messages render safe Markdown from the packaged renderer dependency', async () => {
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const markdown = await readFile(join(appDirectory, 'renderer', 'markdown.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const packager = await readFile(join(appDirectory, 'scripts', 'package-electron.mjs'), 'utf8');
  assert.match(renderer, /import \{ renderMarkdown \} from '\.\/markdown\.mjs'/);
  assert.match(renderer, /assistantElement\.innerHTML = renderMarkdown\(assistantText\)/);
  assert.match(renderer, /text\.innerHTML = renderMarkdown\(message\)/);
  assert.match(markdown, /marked\.esm\.js/);
  assert.match(markdown, /html\(\{ text \}\)[\s\S]*escapeHtml\(text\)/);
  assert.match(markdown, /\['http', 'https', 'mailto'\]/);
  assert.match(styles, /\.markdown-content pre code/);
  assert.match(packager, /copyRuntimeDependencies/);
});

test('compact orb uses the selected 05 WebGL material and panel morphs from its bottom-center anchor', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  const orbRenderer = await readFile(join(appDirectory, 'renderer', 'orb-renderer.mjs'), 'utf8');
  const styles = await readFile(join(appDirectory, 'renderer', 'styles.css'), 'utf8');
  const layout = await readFile(join(appDirectory, 'window-layout.mjs'), 'utf8');
  assert.match(html, /class="panel-surface"/);
  assert.match(html, /canvas id="ZommiOrbCanvas" class="orb-art" width="126" height="126"/);
  assert.doesNotMatch(html, /<svg class="orb-art"|orb-aura|orb-spectrum-rim|orb-glass-rim/);
  assert.match(styles, /\.compact-orb\s*\{[\s\S]*?width:\s*42px;[\s\S]*?height:\s*42px/);
  assert.match(styles, /\.compact-orb \.orb-art\s*\{[\s\S]*?image-rendering:\s*auto/);
  assert.doesNotMatch(styles, /\.compact-orb[^{]*\{[^}]*filter:/);
  assert.match(styles, /\.compact-orb\s*\{[\s\S]*?box-shadow:\s*none/);
  assert.match(styles, /\.panel-shell\s*\{[\s\S]*?transform-origin:\s*50% 100%/);
  assert.match(styles, /\.glass\.is-compact \.panel-shell\s*\{[\s\S]*?scale\(var\(--orb-scale-x\), var\(--orb-scale-y\)\);[\s\S]*?visibility:\s*hidden/);
  assert.match(renderer, /orbSize \/ panelWidth/);
  assert.match(renderer, /const working = activeTurns\.size > 0/);
  assert.match(renderer, /compactOrb\.classList\.toggle\('is-working', working\)/);
  assert.match(renderer, /compactOrbRenderer\.setWorking\(working\)/);
  assert.match(orbRenderer, /05 \/ Nebula Liquid Glass/);
  assert.match(orbRenderer, /canvas\.dataset\.material = '05-nebula-liquid-glass'/);
  assert.match(orbRenderer, /float nebulaWarp = nebulaNoise/);
  assert.match(orbRenderer, /float workingHalo = exp/);
  assert.match(orbRenderer, /if \(working\) frameRequest = requestAnimationFrame\(draw\)/);
  assert.doesNotMatch(styles, /orb-working-orbit|orb-nebula-drift|orb-halo-tempo/);
  assert.match(main, /compactOrbIdleIsStill/);
  assert.match(main, /compactOrbWorkingAnimationRuns/);
  assert.match(main, /compactOrbHasNoLegacySurfaceOrGrayRim/);
  assert.match(renderer, /new ResizeObserver\(syncPanelMorphGeometry\)\.observe\(glass\)/);
  assert.match(layout, /COMPACT_WINDOW_SIZE\s*=\s*56/);
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
  assert.match(renderer, /activityOpenState\(\{/);
  assert.match(renderer, /isReadingExpandedThinking\(\)/);
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
  assert.match(html, /class="ui-icon stop-icon"/);
  assert.match(preload, /interrupt:\s*\(identity\)\s*=>\s*ipcRenderer\.invoke\('chat:interrupt', identity\)/);
  assert.match(renderer, /window\.zommi\.interrupt\(\{[\s\S]*runtimeTargetId:\s*activeRuntimeTargetId,[\s\S]*sessionId:\s*activeThreadId,[\s\S]*turnId:\s*activeTurnId/);
  assert.match(renderer, /canInterrupt \? 'Stop response' : 'Response running'/);
  assert.match(main, /ipcMain\.handle\('chat:interrupt'/);
  assert.match(portableBridge, /#request\('turn\/interrupt', \{ threadId, turnId \}\)/);
});

test('streaming preserves manual scroll position and exposes a latest-message control', async () => {
  const html = await readFile(join(appDirectory, 'renderer', 'index.html'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(html, /id="ScrollToLatest"/);
  assert.match(renderer, /if \(!force && !autoFollow\)/);
  assert.match(renderer, /transcript\.addEventListener\('wheel', handleTranscriptWheel, \{ passive: false \}\)/);
  assert.match(renderer, /if \(programmaticScroll && nearBottom\) return/);
  assert.match(renderer, /event\.preventDefault\(\)/);
  assert.match(renderer, /transcript\.scrollTop = Math\.max\(0, Math\.min\(maximumScrollTop, transcript\.scrollTop \+ event\.deltaY\)\)/);
  assert.match(renderer, /autoFollow = event\.deltaY > 0 && isNearBottom\(transcript\)/);
  assert.match(main, /wheelDownAfterUpReturnsToBottom/);
  assert.match(renderer, /isNearBottom\(transcript\)/);
});

test('Alt+Shift+A combines the selected image with shortcut-time pointer context', async () => {
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  const renderer = await readFile(join(appDirectory, 'renderer', 'renderer.mjs'), 'utf8');
  assert.match(main, /Alt\+Shift\+A[\s\S]*includePointerContext:\s*true/);
  assert.match(main, /pointerContext = await capturePointerContext\(\)/);
  assert.match(main, /return await selectImageRegion\(\)/);
  assert.match(main, /image-selector-fallback/);
  assert.match(main, /return captureHost\.request\('selectImage'\)/);
  assert.match(main, /snapshot:\s*pointerContext\?\.snapshot \|\| null/);
  assert.match(renderer, /attachment\.snapshot && !attachment\.imageDataUrl/);
  assert.match(renderer, /previewText\.hidden = !attachment\.previewText/);
});

test('Windows native host is capture-only and cannot queue capture behind an agent runtime', async () => {
  const repositoryRoot = join(appDirectory, '..', '..');
  const nativeHost = await readFile(join(repositoryRoot, 'src/Zommi.Windows/ElectronNativeHost.cs'), 'utf8');
  const nativeProgram = await readFile(join(repositoryRoot, 'src/Zommi.Windows/Program.cs'), 'utf8');
  const main = await readFile(join(appDirectory, 'main.mjs'), 'utf8');
  assert.match(nativeHost, /case "capture"/);
  assert.match(nativeHost, /case "selectImage"/);
  assert.doesNotMatch(nativeHost, /CodexAppServerClient|startCodex|startTurn|interruptTurn|getChatState/);
  assert.doesNotMatch(nativeProgram, /CodexAppServerClient|thread\/start|turn\/start|MainForm/);
  await assert.rejects(access(join(repositoryRoot, 'src/Zommi.Windows/CodexAppServerClient.cs')));
  await assert.rejects(access(join(repositoryRoot, 'src/Zommi.Core/CodexStreamProtocol.cs')));
  assert.match(main, /captureHost\.request\('capture', point \? \{ point \} : \{\}\)/);
  assert.match(main, /backend\.startTurn/);
});
