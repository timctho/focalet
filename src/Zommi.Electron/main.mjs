import { app, BrowserWindow, Menu, Tray, clipboard, globalShortcut, ipcMain, nativeImage, nativeTheme, powerMonitor, screen } from 'electron';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { appendFile, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NativeHostClient } from './native-host.mjs';
import { loadArtifactPreview } from './artifact-preview.mjs';
import { RuntimeBroker } from './runtime-broker.mjs';
import { RuntimeDiscovery } from './runtime-discovery.mjs';
import { capturePortableContext } from './platform-capture.mjs';
import { selectImageRegion } from './image-selector.mjs';
import {
  COMPACT_WINDOW_SIZE,
  calculateAdaptiveWindowSize,
  calculateAnchoredWindowBounds,
  interpolateWindowBounds,
} from './window-layout.mjs';

const moduleDirectory = dirname(fileURLToPath(import.meta.url));
const seededAcceptance = process.argv.includes('--acceptance-ui-seeded');
const acceptanceEvidencePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-evidence='))
  ?.slice('--acceptance-evidence='.length);
const acceptanceHoverRestPath = process.argv
  .find((argument) => argument.startsWith('--acceptance-hover-rest='))
  ?.slice('--acceptance-hover-rest='.length);
const acceptanceHoverActivePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-hover-active='))
  ?.slice('--acceptance-hover-active='.length);
const acceptanceInputProbePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-input-probe='))
  ?.slice('--acceptance-input-probe='.length);
const acceptanceModelEvidencePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-model-evidence='))
  ?.slice('--acceptance-model-evidence='.length);
const acceptanceRuntimeEvidencePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-runtime-evidence='))
  ?.slice('--acceptance-runtime-evidence='.length);
const acceptanceCompactEvidencePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-compact-evidence='))
  ?.slice('--acceptance-compact-evidence='.length);
const acceptanceCaptureTriggerPath = process.argv
  .find((argument) => argument.startsWith('--acceptance-capture-trigger='))
  ?.slice('--acceptance-capture-trigger='.length);
const acceptanceTransportEvidencePath = process.argv
  .find((argument) => argument.startsWith('--acceptance-transport-evidence='))
  ?.slice('--acceptance-transport-evidence='.length);
const noAutoLaunch = process.argv.includes('--no-auto-launch');
const HOVER_COLLAPSE_DELAY_MS = 500;
let mainWindow = null;
let tray = null;
let backend = null;
let captureHost = null;
let quitting = false;
let largePanel = false;
let panelOpen = false;
let displaySignature = null;
let boundsAnimationTimer = null;
let hoverCollapseTimer = null;
let hoverPollTimer = null;
let pointerInsideWindow = false;
let manualWindowDrag = null;
let shortcuts = { context: false, image: false };
let seededStreamTimer = null;
let seededStreamTurnId = null;
let seededStreamThreadId = null;
let seededActiveThreadId = 'seeded-zommi-thread';
let runtimeLogPath = null;
let acceptanceCapturePollTimer = null;
let powerResumeHandler = null;

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow({ openPanel: true, focusComposer: true }));
  // Do not top-level await a function that waits for app readiness. Electron
  // waits for the ESM entry point to finish evaluating before it emits ready,
  // so awaiting app.whenReady() here would deadlock packaged startup.
  void startApplication().catch((error) => {
    console.error('Zommi failed to start.', error);
    app.quit();
  });
}

async function startApplication() {
  await app.whenReady();
  await initializeRuntimeLog();
  nativeTheme.themeSource = 'light';
  app.setAppUserModelId('com.zommi.desktop');
  if (process.platform === 'darwin') app.dock?.hide();
  createWindow();
  startWindowHoverTracking();
  createTray();
  createBackend();
  powerResumeHandler = () => {
    void backend.rediscoverTargets().catch((error) => {
      writeRuntimeLog('runtime-resume-refresh', error.message);
    });
  };
  powerMonitor.on('resume', powerResumeHandler);
  registerIpc();
  registerShortcuts();

  if (seededAcceptance) {
    mainWindow.webContents.once('did-finish-load', () => {
      seedAcceptanceContexts();
      send('acceptance:conversation', true);
      sendStatus('seeded Electron UI acceptance');
      sendShortcutState();
      showWindow({ openPanel: true, focusComposer: true, animate: false, position: { x: 80, y: 80 } });
      if (acceptanceEvidencePath) {
        setTimeout(() => captureAcceptanceEvidence(acceptanceEvidencePath), 700);
      }
      if (acceptanceInputProbePath) {
        setTimeout(() => runAcceptanceInputProbe(acceptanceInputProbePath), 900);
      }
    });
  } else {
    mainWindow.webContents.once('did-finish-load', () => {
      startAcceptanceCaptureTrigger();
      sendShortcutState();
      showWindow();
      if (acceptanceCompactEvidencePath) {
        setTimeout(() => captureAcceptanceEvidence(acceptanceCompactEvidencePath), 500);
      }
      if (acceptanceTransportEvidencePath) {
        setTimeout(() => captureTransportEvidence(acceptanceTransportEvidencePath), 800);
      }
    });
    if (!noAutoLaunch) startBackend().catch((error) => sendStatus(`Codex connection failed: ${error.message}`, true));
  }

  app.on('activate', () => showWindow({ openPanel: true, focusComposer: true }));
  app.on('will-quit', () => {
    clearInterval(hoverPollTimer);
    clearInterval(acceptanceCapturePollTimer);
    globalShortcut.unregisterAll();
    backend?.stop?.();
    captureHost?.stop?.();
    if (powerResumeHandler) powerMonitor.removeListener('resume', powerResumeHandler);
  });
}

function startAcceptanceCaptureTrigger() {
  if (!acceptanceCaptureTriggerPath) return;
  let handling = false;
  acceptanceCapturePollTimer = setInterval(async () => {
    if (handling) return;
    handling = true;
    try {
      const trigger = JSON.parse(await readFile(acceptanceCaptureTriggerPath, 'utf8'));
      await rm(acceptanceCaptureTriggerPath, { force: true });
      writeRuntimeLog('acceptance', 'capture trigger received');
      const result = await captureContext({ point: { x: Number(trigger.x), y: Number(trigger.y) } });
      if (trigger.resultPath) await writeFile(String(trigger.resultPath), `${JSON.stringify(result)}\n`, 'utf8');
    } catch (error) {
      if (error?.code !== 'ENOENT') writeRuntimeLog('acceptance', `capture trigger failed: ${error.message}`);
    } finally {
      handling = false;
    }
  }, 50);
}

async function runAcceptanceInputProbe(path) {
  const result = { inputPath: 'webContents.sendInputEvent' };
  try {
    result.dragRegionStyles = await evaluateRenderer(`['.glass', '.panel-content', '.edge-drag-top', '.titlebar', '.drag-region', '.background-drag', '#ToggleSessions'].map((selector) => { const element = document.querySelector(selector); const rectangle = element?.getBoundingClientRect(); const style = element ? getComputedStyle(element) : null; const center = rectangle ? document.elementFromPoint(rectangle.left + rectangle.width / 2, rectangle.top + rectangle.height / 2) : null; return { selector, bodyClass: document.body.className, className: element?.className || '', display: style?.display || '', appRegion: style?.webkitAppRegion || '', pointerEvents: style?.pointerEvents || '', rectangle: rectangle ? { x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height } : null, centerElement: center?.id || center?.className || center?.tagName || '' }; })`);
    const beforeManualDrag = mainWindow.getBounds();
    await evaluateRenderer(`window.zommi.beginWindowDrag({ x: 400, y: 300 })`);
    await evaluateRenderer(`window.zommi.moveWindowDrag({ x: 454, y: 326 })`);
    await delay(120);
    const afterManualDrag = mainWindow.getBounds();
    await evaluateRenderer(`window.zommi.endWindowDrag()`);
    result.manualTopDragDiagnostics = { before: beforeManualDrag, after: afterManualDrag };
    result.manualTopDrag = afterManualDrag.x - beforeManualDrag.x === 54 && afterManualDrag.y - beforeManualDrag.y === 26;
    const draggedOrbBounds = compactHitBounds(afterManualDrag);
    setPanelOpen(false, { animate: false });
    const collapsedAfterDrag = compactHitBounds(mainWindow.getBounds());
    result.collapsedOrbFollowsDraggedWindow = collapsedAfterDrag.x === draggedOrbBounds.x && collapsedAfterDrag.y === draggedOrbBounds.y;
    setPanelOpen(true, { animate: false });
    mainWindow.setBounds(beforeManualDrag, false);
    const sessionTogglePoint = await rendererElementCenter('#ToggleSessions');
    mainWindow.webContents.sendInputEvent({ type: 'mouseMove', x: sessionTogglePoint.x, y: sessionTogglePoint.y });
    await delay(260);
    result.sessionSidebarHover = await evaluateRenderer(`document.querySelector('#SessionSidebar')?.classList.contains('open') === true`);
    result.sessionSidebarHalfHeight = await evaluateRenderer(`{ const p = document.querySelector('#SessionSidebar')?.getBoundingClientRect(); const g = document.querySelector('.glass')?.getBoundingClientRect(); return Boolean(p && g && p.height <= g.height / 2 + 1); }`);
    result.activeSessionShowsRead = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-zommi-thread"]')?.dataset.status === 'read'`);
    result.inactiveSessionShowsDone = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-secondary-thread"]')?.dataset.status === 'done'`);
    result.sessionStatusesUseIcons = await evaluateRenderer(`document.querySelectorAll('#SessionList .session-item .session-status .ui-icon').length === 2`);
    await clickRendererElement('#ToggleSessions');
    const sessionAwayPoint = await rendererElementCenter('#CodexTranscript');
    mainWindow.webContents.sendInputEvent({ type: 'mouseMove', x: sessionAwayPoint.x, y: sessionAwayPoint.y });
    await delay(280);
    result.sessionSidebarClickDoesNotPin = await evaluateRenderer(`document.querySelector('#SessionSidebar')?.classList.contains('open') === false`);
    await clickRendererElement('#RuntimeSummary');
    result.runtimePickerOpens = await evaluateRenderer(`document.querySelector('#RuntimePanel')?.hidden === false && document.querySelector('#RuntimeSummary')?.getAttribute('aria-expanded') === 'true'`);
    result.runtimePickerShowsSelectedTarget = await evaluateRenderer(`document.querySelector('#RuntimeList .runtime-target.selected')?.dataset.targetId === 'seeded-codex-target'`);
    result.runtimePickerShowsHostAndProtocol = await evaluateRenderer(`/app-server/.test(document.querySelector('#RuntimeList .runtime-target-detail')?.textContent || '') && /Ubuntu/.test(document.querySelector('#RuntimeList .runtime-target-detail')?.textContent || '')`);
    result.runtimePickerNeedsNoWizard = await evaluateRenderer(`!/(setup|wizard|configure)/i.test(document.querySelector('#RuntimePanel')?.textContent || '')`);
    await clickRendererElement('#RuntimeAdvanced > summary');
    result.runtimeAdvancedOpens = await evaluateRenderer(`document.querySelector('#RuntimeAdvanced')?.open === true`);
    result.runtimeAdvancedShowsProtocolTargets = await evaluateRenderer(`{ const values = [...document.querySelectorAll('#RuntimeOverrideAdapter option')].map((option) => option.value); return values.includes('codex-app-server') && values.includes('openclaw-acp') && values.includes('openclaw-gateway'); }`);
    result.runtimeAdvancedDefaultsToHostPath = await evaluateRenderer(`document.querySelector('#RuntimeOverrideHostLabel')?.hidden === false && document.querySelector('#RuntimeOverrideLocatorLabel')?.textContent === 'Executable path'`);
    await evaluateRenderer(`{ const select = document.querySelector('#RuntimeOverrideAdapter'); select.value = 'openclaw-gateway'; select.dispatchEvent(new Event('change', { bubbles: true })); return true; }`);
    result.runtimeAdvancedGatewayUsesEndpoint = await evaluateRenderer(`{ const host = document.querySelector('#RuntimeOverrideHostLabel'); return host?.hidden === true && getComputedStyle(host).display === 'none' && document.querySelector('#RuntimeOverrideLocatorLabel')?.textContent === 'Gateway endpoint' && document.querySelector('#RuntimeOverrideLocator')?.placeholder.startsWith('ws://'); }`);
    result.runtimeAdvancedShowsConfiguredOverride = await evaluateRenderer(`/gateway\.example\.test/.test(document.querySelector('#RuntimeOverrideList')?.textContent || '')`);
    result.runtimeAdvancedHasNoCredentialInput = await evaluateRenderer(`!document.querySelector('#RuntimeAdvanced input[type="password"], #RuntimeAdvanced [name*="token" i], #RuntimeAdvanced [name*="password" i]')`);
    if (acceptanceRuntimeEvidencePath) await captureAcceptanceEvidence(acceptanceRuntimeEvidencePath);
    await clickRendererElement('#RuntimeSummary');
    send('question:requested', {
      questionId: 'seeded-structured-question',
      runtimeTargetId: 'seeded-codex-target',
      title: 'Structured question acceptance',
      questions: [
        { questionId: 'branch', header: 'Branch', question: 'Which branch?', options: [{ label: 'main', description: 'Stable branch' }, { label: 'dev', description: 'Development branch' }] },
        { questionId: 'secret', header: 'Secret', question: 'Sensitive value?', options: [], isOther: true, isSecret: true },
      ],
    });
    await delay(180);
    result.structuredQuestionDialog = await evaluateRenderer(`Boolean(document.querySelectorAll('#QuestionPanel .structured-question').length === 2 && document.querySelector('#QuestionPanel input[type="radio"]') && document.querySelector('#QuestionPanel input[type="password"]'))`);
    await evaluateRenderer(`{ document.querySelector('#QuestionPanel input[type="radio"]')?.click(); const secret = document.querySelector('#QuestionPanel input[type="password"]'); if (secret) { secret.value = 'acceptance-only'; secret.dispatchEvent(new Event('input', { bubbles: true })); } return true; }`);
    await clickRendererElement('#QuestionSubmit');
    result.structuredQuestionResolves = await evaluateRenderer(`document.querySelector('#QuestionPanel')?.hidden === true`);
    await clickRendererElement('#ToggleSessions');
    await clickRendererElement('#ModelSummary');
    await delay(260);
    result.chatControlsLeaveLoading = await evaluateRenderer(`{ const label = document.querySelector('#ModelSummaryLabel')?.textContent?.trim() || ''; const composer = document.querySelector('#ZommiComposer'); return Boolean(label && !/^(Loading|Connecting|Retry)/i.test(label) && composer && !composer.disabled); }`);
    result.modelPanel = await evaluateRenderer(`document.querySelector('#ModelPanel')?.hidden === false`);
    result.modelPanelDiagnostics = await evaluateRenderer(`{ const e = document.querySelector('#ModelPanel'); const r = e?.getBoundingClientRect(); const s = e ? getComputedStyle(e) : null; return r && s ? { x: r.x, y: r.y, width: r.width, height: r.height, display: s.display, opacity: s.opacity, visibility: s.visibility } : null; }`);
    result.modelPanelOpensBelowTopControl = await evaluateRenderer(`{ const p = document.querySelector('#ModelPanel')?.getBoundingClientRect(); const s = document.querySelector('#ModelSummary')?.getBoundingClientRect(); return Boolean(p && s && p.top > s.bottom); }`);
    result.modelSelectionBesideAgentAtTop = await evaluateRenderer(`{ const m = document.querySelector('#ModelSummary')?.getBoundingClientRect(); const r = document.querySelector('#RuntimeSummary')?.getBoundingClientRect(); const c = document.querySelector('.composer-shell')?.getBoundingClientRect(); return Boolean(m && r && c && m.left >= r.right && Math.abs((m.top + m.height / 2) - (r.top + r.height / 2)) <= 2 && m.bottom < c.top); }`);
    result.generatedImageDisplayed = await evaluateRenderer(`Boolean(document.querySelector('#CodexTranscript .artifact-card.image img'))`);
    result.generatedHtmlPreviewDisplayed = await evaluateRenderer(`Boolean(document.querySelector('#CodexTranscript .artifact-card.html iframe')?.srcdoc.includes('ZOMMI_HTML_PREVIEW'))`);
    if (acceptanceModelEvidencePath) await captureAcceptanceEvidence(acceptanceModelEvidencePath);
    const effortBefore = await evaluateRenderer(`document.querySelector('#EffortList .effort-option.selected')?.dataset.effort || ''`);
    await clickRendererElement('#EffortList .effort-option:not(.selected)');
    await delay(180);
    const effortAfter = await evaluateRenderer(`document.querySelector('#EffortList .effort-option.selected')?.dataset.effort || ''`);
    result.reasoningChanged = Boolean(effortBefore && effortAfter && effortBefore !== effortAfter);
    await clickRendererElement('#ModelSummary');
    await evaluateRenderer(`{ document.querySelector('#CodexTranscript .artifact-card.image .artifact-open')?.click(); return true; }`);
    result.generatedImageExpandedPreview = await evaluateRenderer(`Boolean(document.querySelector('#ArtifactViewer')?.hidden === false && document.querySelector('#ArtifactViewerBody img'))`);
    await evaluateRenderer(`{ document.querySelector('#CloseArtifactViewer')?.click(); return true; }`);
    await evaluateRenderer(`{ document.querySelector('#CodexTranscript .artifact-card.html .artifact-open')?.click(); return true; }`);
    result.generatedHtmlExpandedPreview = await evaluateRenderer(`Boolean(document.querySelector('#ArtifactViewer')?.hidden === false && document.querySelector('#ArtifactViewerBody iframe')?.srcdoc.includes('ZOMMI_HTML_PREVIEW'))`);
    await evaluateRenderer(`{ document.querySelector('#CloseArtifactViewer')?.click(); return true; }`);
    await clickRendererElement('#ToggleSessions');

    const initialHistoryCount = await evaluateRenderer(`document.querySelectorAll('#CodexTranscript .conversation-turn').length`);
    await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); e.scrollTop = 0; e.dispatchEvent(new Event('scroll')); return true; }`);
    await delay(220);
    const pagedHistoryState = await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); return { count: e.querySelectorAll('.conversation-turn').length, top: e.scrollTop }; }`);
    result.historyLoadsInPages = initialHistoryCount < 42 && pagedHistoryState.count > initialHistoryCount && pagedHistoryState.top > 0;
    for (let page = 0; page < 3; page += 1) {
      await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); e.scrollTop = 0; e.dispatchEvent(new Event('scroll')); return true; }`);
      await delay(180);
    }
    result.historyReachesFirstTurn = await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); e.scrollTop = 0; return e.querySelector('.conversation-turn')?.getAttribute('aria-label') === 'Conversation turn 1'; }`);

    await clickRendererElement('#ZommiComposer');
    mainWindow.webContents.insertText('seeded streaming input acceptance');
    await delay(100);
    await clickRendererElement('#SendMessage');
    await delay(300);
    result.stopButtonDuringStreaming = await evaluateRenderer(`document.querySelector('#SendMessage')?.getAttribute('aria-label') === 'Stop response'`);
    result.composerEditableWhileStreaming = await evaluateRenderer(`document.querySelector('#ZommiComposer')?.disabled === false`);
    await clickRendererElement('#ZommiComposer');
    mainWindow.webContents.insertText('draft while streaming');
    await delay(100);
    result.composerAcceptsDraftWhileStreaming = await evaluateRenderer(`document.querySelector('#ZommiComposer')?.value === 'draft while streaming'`);
    result.thinkingSurvivesToolActivity = await evaluateRenderer(`Boolean(document.querySelector('#CodexTranscript .conversation-turn:last-child .activity-card.thinking[open]') && document.querySelector('#CodexTranscript .conversation-turn:last-child .activity-card.tool.completed'))`);
    await clickRendererElement('#ToggleSessions');
    await clickRendererElement('#SessionList .session-item[data-thread-id="seeded-secondary-thread"]');
    await delay(260);
    result.sessionSwitchDuringStreaming = await evaluateRenderer(`document.querySelector('#SessionList .session-item.active')?.dataset.threadId === 'seeded-secondary-thread'`);
    result.backgroundSessionShowsRunning = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-zommi-thread"]')?.dataset.status === 'running'`);
    result.switchedSessionComposerEnabled = await evaluateRenderer(`document.querySelector('#ZommiComposer')?.disabled === false`);
    await clickRendererElement('#SessionList .session-item[data-thread-id="seeded-zommi-thread"]');
    await delay(260);
    result.returnedToRunningSession = await evaluateRenderer(`document.querySelector('#SendMessage')?.getAttribute('aria-label') === 'Stop response'`);
    await delay(2500);
    const transcriptPoint = await rendererElementCenter('#CodexTranscript');
    mainWindow.webContents.sendInputEvent({ type: 'mouseMove', x: transcriptPoint.x, y: transcriptPoint.y });
    mainWindow.webContents.sendInputEvent({ type: 'mouseWheel', x: transcriptPoint.x, y: transcriptPoint.y, deltaY: 720, canScroll: true });
    await delay(250);
    const manualScrollState = await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); return e ? { top: e.scrollTop, distance: e.scrollHeight - e.scrollTop - e.clientHeight } : null; }`);
    await delay(1000);
    const streamedScrollState = await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); return e ? { top: e.scrollTop, distance: e.scrollHeight - e.scrollTop - e.clientHeight } : null; }`);
    result.manualScrollDiagnostics = { before: manualScrollState, after: streamedScrollState };
    result.manualScrollPreserved = Boolean(manualScrollState && streamedScrollState && manualScrollState.distance > 40 && Math.abs(streamedScrollState.top - manualScrollState.top) <= 2);
    result.latestButtonVisible = await evaluateRenderer(`document.querySelector('#ScrollToLatest')?.hidden === false`);
    await clickRendererElement('#ScrollToLatest');
    await delay(180);
    result.latestButtonReturnsToBottom = await evaluateRenderer(`{ const e = document.querySelector('#CodexTranscript'); return Boolean(e && e.scrollHeight - e.scrollTop - e.clientHeight <= 40); }`);
    await clickRendererElement('#SendMessage');
    await delay(250);
    result.stopCompleted = await evaluateRenderer(`document.querySelector('#CodexStatus')?.textContent === 'stopped' && document.querySelector('#SendMessage')?.getAttribute('aria-label') === 'Send message'`);
    result.thinkingDeduplicated = await evaluateRenderer(`(document.querySelector('#CodexTranscript')?.textContent.match(/Preparing a long streamed response\./g) || []).length === 1`);
    result.thinkingCardsPerTurn = await evaluateRenderer(`[...document.querySelectorAll('#CodexTranscript .conversation-turn')].map((turn) => turn.querySelectorAll('.activity-card.thinking').length)`);
    result.singleThinkingCard = result.thinkingCardsPerTurn.some((count) => count > 0) && result.thinkingCardsPerTurn.every((count) => count <= 1);
    result.thinkingUsesStatusIcon = await evaluateRenderer(`Boolean(document.querySelector('#CodexTranscript .activity-card.thinking .activity-state[data-status="done"] .ui-icon'))`);
    await clickRendererElement('#ToggleSessions');
    await clickRendererElement('#SessionList .session-item[data-thread-id="seeded-secondary-thread"]');
    send('turn:completed', { threadId: 'seeded-zommi-thread', status: 'completed' });
    await delay(180);
    result.backgroundCompletionShowsUnread = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-zommi-thread"]')?.dataset.status === 'unread'`);
    result.passed = Object.entries(result)
      .filter(([key]) => !['inputPath', 'dragRegionStyles', 'manualTopDragDiagnostics', 'modelPanelDiagnostics', 'manualScrollDiagnostics', 'thinkingCardsPerTurn'].includes(key))
      .every(([, value]) => value === true);
  } catch (error) {
    result.passed = false;
    result.error = error.message;
  }
  await writeFile(path, `${JSON.stringify(result, null, 2)}\n`);
}

async function clickRendererElement(selector) {
  const point = await rendererElementCenter(selector);
  mainWindow.webContents.sendInputEvent({ type: 'mouseMove', x: point.x, y: point.y });
  mainWindow.webContents.sendInputEvent({ type: 'mouseDown', x: point.x, y: point.y, button: 'left', clickCount: 1 });
  mainWindow.webContents.sendInputEvent({ type: 'mouseUp', x: point.x, y: point.y, button: 'left', clickCount: 1 });
  await delay(180);
}

async function rendererElementCenter(selector) {
  const rectangle = await evaluateRenderer(`{ const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return null; const r = e.getBoundingClientRect(); return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), width: r.width, height: r.height }; }`);
  if (!rectangle || rectangle.width <= 0 || rectangle.height <= 0) throw new Error(`Renderer element is not visible: ${selector}`);
  return rectangle;
}

function evaluateRenderer(expression) {
  return mainWindow.webContents.executeJavaScript(`(() => ${expression})()`);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function captureAcceptanceEvidence(path) {
  try {
    const image = await mainWindow.webContents.capturePage();
    await writeFile(path, image.toPNG());
    sendStatus('seeded Electron UI evidence captured');
  } catch (error) {
    sendStatus(`UI evidence capture failed: ${error.message}`, true);
  }
}

function createWindow() {
  const initialDisplay = screen.getPrimaryDisplay();
  const initialSize = calculateAdaptiveWindowSize(initialDisplay.workArea, false);
  const initialBounds = calculateAnchoredWindowBounds(initialDisplay.workArea, initialSize);
  displaySignature = signatureForDisplay(initialDisplay);
  mainWindow = new BrowserWindow({
    title: 'Zommi — floating agent chat',
    icon: createZommiIcon(),
    ...initialBounds,
    minWidth: 640,
    minHeight: 500,
    useContentSize: true,
    transparent: true,
    backgroundColor: '#00000000',
    frame: false,
    roundedCorners: true,
    hasShadow: false,
    resizable: true,
    show: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    vibrancy: process.platform === 'darwin' ? 'under-window' : undefined,
    visualEffectState: process.platform === 'darwin' ? 'active' : undefined,
    webPreferences: {
      preload: join(moduleDirectory, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      zoomFactor: 1,
    },
  });
  mainWindow.setIgnoreMouseEvents(true, { forward: true });
  mainWindow.setMenuBarVisibility(false);
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());
  mainWindow.loadFile(join(moduleDirectory, 'renderer', 'index.html'));
  mainWindow.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
    mainWindow.hide();
  });
  screen.on('display-metrics-changed', (_event, display, changedMetrics) => {
    if (!mainWindow || mainWindow.isDestroyed() || !changedMetrics.some((metric) => ['bounds', 'workArea', 'scaleFactor'].includes(metric))) return;
    const currentDisplay = screen.getDisplayMatching(mainWindow.getBounds());
    if (currentDisplay.id === display.id) applyWindowLayout(currentDisplay, true);
  });
}

function applyWindowLayout(display, force = false) {
  const nextSignature = signatureForDisplay(display);
  if (!force && nextSignature === displaySignature) return;
  displaySignature = nextSignature;
  mainWindow.setBounds(targetBoundsForDisplay(display), false);
  send('window:bounds-settled', { open: panelOpen });
}

function signatureForDisplay(display) {
  return `${display.id}:${display.workArea.x},${display.workArea.y},${display.workArea.width}x${display.workArea.height}@${display.scaleFactor}:${panelOpen}:${largePanel}`;
}

function targetBoundsForDisplay(display, position = null) {
  const size = calculateAdaptiveWindowSize(display.workArea, largePanel);
  const bounds = calculateAnchoredWindowBounds(display.workArea, size);
  return position ? { ...bounds, x: Math.round(position.x), y: Math.round(position.y) } : bounds;
}

function createTray() {
  tray = new Tray(createZommiIcon());
  tray.setToolTip('Zommi floating agent chat');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open floating chat', click: () => showWindow({ openPanel: true, focusComposer: true }) },
    { label: 'Capture context (Alt+A)', click: () => captureContext({ point: screen.getCursorScreenPoint() }) },
    { label: 'Select image + pointer context (Alt+Shift+A)', click: () => selectImageContext({ includePointerContext: true }) },
    { type: 'separator' },
    { label: 'Exit Zommi', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('double-click', () => showWindow({ openPanel: true, focusComposer: true }));
}

function createZommiIcon() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
    <defs><linearGradient id="g" x1="10" y1="8" x2="54" y2="58" gradientUnits="userSpaceOnUse"><stop stop-color="#85c7ff"/><stop offset=".48" stop-color="#8278f5"/><stop offset="1" stop-color="#d574d8"/></linearGradient></defs>
    <circle cx="32" cy="32" r="29" fill="url(#g)"/><circle cx="32" cy="32" r="27.5" fill="none" stroke="#fff" stroke-opacity=".72"/>
    <path d="M32 15c1.35 9.9 7.1 15.65 17 17-9.9 1.35-15.65 7.1-17 17-1.35-9.9-7.1-15.65-17-17 9.9-1.35 15.65-7.1 17-17Z" fill="#fff"/>
  </svg>`;
  return nativeImage.createFromDataURL(`data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`);
}

function createBackend() {
  if (process.platform === 'win32') {
    const executable = process.env.ZOMMI_NATIVE_HOST_PATH || join(process.resourcesPath, 'native', 'Zommi.exe');
    writeRuntimeLog('native-host', executable);
    captureHost = new NativeHostClient(executable);
    captureHost.on('error', (error) => sendStatus(`Capture host failed: ${error.message}`, true));
    captureHost.on('protocolError', (error) => sendStatus(`Capture host protocol failed: ${error.message}`, true));
    captureHost.on('requestError', ({ method, error }) => writeRuntimeLog(`capture:${method}`, error.message));
    captureHost.on('exit', ({ message }) => writeRuntimeLog('native-host-exit', message));
    // Warm the capture-only host while runtime discovery happens so the first
    // user gesture never pays .NET/native bundle startup on the hot path.
    captureHost.start();
    void captureHost.request('ping')
      .then(({ version }) => writeRuntimeLog('native-host-ready', `version=${version || ''}`))
      .catch((error) => writeRuntimeLog('native-host-warmup', error.message));
  }
  const userData = app.getPath('userData');
  const discovery = new RuntimeDiscovery({
    cachePath: join(userData, 'runtime-discovery.json'),
    settingsPath: join(userData, 'runtime-settings.json'),
  });
  backend = new RuntimeBroker({
    discovery,
    preferencePath: join(userData, 'runtime-preferences.json'),
  });
  backend.on('status', ({ message, warning, targetId, status }) => {
    writeRuntimeLog('runtime-status', `target=${targetId || ''} status=${status || ''} ${message}`);
    sendStatus(message, warning);
  });
  backend.on('diagnostic', ({ message, targetId, status }) => {
    writeRuntimeLog('runtime-diagnostic', `target=${targetId || ''} status=${status || ''} ${message}`);
  });
  backend.on('targetsChanged', (state) => send('runtime:state', state));
  backend.on('event', (event) => send('runtime:event', event));
  backend.on('streamUpdate', (update) => send('stream:update', update));
  backend.on('approvalRequested', (request) => send('approval:requested', request));
  backend.on('questionRequested', (request) => send('question:requested', request));
  backend.on('turnCompleted', (status) => {
    writeRuntimeLog('turn-completed', `target=${status?.runtimeTargetId || ''} thread=${status?.threadId || ''} status=${status?.status || ''}`);
    send('turn:completed', status);
  });
  backend.on('transportMetric', (metric) => {
    writeRuntimeLog(
      'transport-metric',
      `target=${metric.runtimeTargetId || ''} operation=${metric.clientOperationId || ''} method=${metric.method || ''} rendererToWrite=${metric.rendererToProtocolWriteMilliseconds ?? ''} mainToWrite=${metric.mainToProtocolWriteMilliseconds ?? ''}`,
    );
    send('runtime:transport-metric', metric);
  });
}

function registerShortcuts() {
  shortcuts.context = globalShortcut.register('Alt+A', () => captureContext({ point: screen.getCursorScreenPoint() }));
  shortcuts.image = globalShortcut.register('Alt+Shift+A', () => selectImageContext({ includePointerContext: true }));
  writeRuntimeLog('shortcuts', `context=${shortcuts.context} image=${shortcuts.image}`);
  sendShortcutState();
}

function registerIpc() {
  ipcMain.on('window:hide', () => mainWindow?.hide());
  ipcMain.on('window:toggle-expanded', () => toggleExpanded());
  ipcMain.on('window:open-panel', () => showWindow({ openPanel: true, focusComposer: true }));
  ipcMain.on('window:set-hovered', (_event, hovered) => setWindowHovered(Boolean(hovered)));
  ipcMain.on('window:drag-start', (_event, point) => beginManualWindowDrag(point));
  ipcMain.on('window:drag-move', (_event, point) => moveManualWindowDrag(point));
  ipcMain.on('window:drag-end', () => { manualWindowDrag = null; });
  ipcMain.on('acceptance:hover-state', (_event, hovered) => {
    if (!seededAcceptance) return;
    const path = hovered ? acceptanceHoverActivePath : acceptanceHoverRestPath;
    if (path) setTimeout(() => captureAcceptanceEvidence(path), 300);
  });
  ipcMain.handle('clipboard:write', (_event, text) => clipboard.writeText(String(text || '')));
  ipcMain.handle('artifact:preview', (_event, request) => loadArtifactPreview(request, {
    runtimeState: seededAcceptance ? seededRuntimeState() : backend.getRuntimeState(),
  }));
  ipcMain.handle('context:select-image', () => selectImageContext());
  ipcMain.handle('runtime:state', async () => {
    if (seededAcceptance) return seededRuntimeState();
    await backend.initialize();
    return backend.getRuntimeState();
  });
  ipcMain.handle('runtime:request', (_event, request) => backend.request(request));
  ipcMain.handle('runtime:transport-metrics', () => seededAcceptance ? [] : backend.getTransportMetrics());
  ipcMain.handle('runtime:transport-probe', (_event, payload) => {
    if (seededAcceptance) throw new Error('Seeded UI mode has no real protocol transport.');
    return backend.probeTransportWrite({
      rendererSubmittedAtEpochMs: Number(payload?.rendererSubmittedAtEpochMs) || null,
      mainReceivedAtEpochMs: Date.now(),
    });
  });
  ipcMain.handle('runtime:refresh', (_event, hostId) => seededAcceptance
    ? seededRuntimeState()
    : backend.refreshTargets(hostId || null));
  ipcMain.handle('runtime:select', (_event, targetId) => seededAcceptance
    ? seededRuntimeState()
    : backend.selectTarget(String(targetId || '')));
  ipcMain.handle('runtime:override-save', (_event, value) => {
    if (seededAcceptance) return seededRuntimeState();
    return backend.saveRuntimeOverride(value && typeof value === 'object' ? value : {});
  });
  ipcMain.handle('runtime:override-remove', (_event, id) => {
    if (seededAcceptance) return seededRuntimeState();
    return backend.removeRuntimeOverride(String(id || ''));
  });
  ipcMain.handle('runtime:sign-in', async (_event, targetId) => {
    const launch = backend.getSignInLaunch(targetId || undefined);
    if (!launch) throw new Error('This runtime does not expose a separate sign-in command. Open its CLI to configure authentication.');
    await launchInTerminal(launch);
    return { opened: true, displayCommand: launch.displayCommand };
  });
  ipcMain.handle('approval:resolve', (_event, payload) => backend.resolveApproval(
    String(payload?.approvalId || ''),
    payload?.optionId ? String(payload.optionId) : null,
    {
      runtimeTargetId: payload?.runtimeTargetId ? String(payload.runtimeTargetId) : undefined,
      sessionId: payload?.sessionId ? String(payload.sessionId) : undefined,
    },
  ));
  ipcMain.handle('question:resolve', (_event, payload) => seededAcceptance
    ? { resolved: true, questionId: String(payload?.questionId || '') }
    : backend.resolveQuestion(
      String(payload?.questionId || ''),
      payload?.answer && typeof payload.answer === 'object' ? payload.answer : {},
      {
        runtimeTargetId: payload?.runtimeTargetId ? String(payload.runtimeTargetId) : undefined,
        sessionId: payload?.sessionId ? String(payload.sessionId) : undefined,
      },
    ));
  ipcMain.handle('chat:state', async () => {
    if (seededAcceptance) return seededChatState();
    const state = await backend.getChatState();
    writeRuntimeLog('chat-state', `target=${state?.runtimeTargetId || ''} thread=${state?.activeThreadId || ''} models=${state?.models?.length || 0}`);
    return state;
  });
  ipcMain.handle('chat:create-session', async (_event, payload) => {
    const options = readModelOptions(payload);
    if (seededAcceptance) {
      seededActiveThreadId = 'seeded-secondary-thread';
      return seededChatState();
    }
    return backend.createSession(options);
  });
  ipcMain.handle('chat:switch-session', async (_event, threadId) => {
    const id = String(threadId || '').trim();
    if (!id) throw new Error('An Agent Session id is required.');
    if (seededAcceptance) {
      seededActiveThreadId = id;
      return seededChatState();
    }
    return backend.switchSession(id);
  });
  ipcMain.handle('chat:send', async (_event, payload) => {
    const mainReceivedAtEpochMs = Date.now();
    const message = String(payload?.message || '').trim();
    if (!message) throw new Error('A message is required.');
    const attachments = Array.isArray(payload.attachments) ? payload.attachments : [];
    const snapshots = attachments.map((item) => item.snapshot).filter(Boolean);
    const images = attachments.map((item) => item.imageDataUrl).filter(Boolean);
    const options = readModelOptions(payload);
    sendStatus('thinking…');
    if (seededAcceptance) return startSeededStream(seededActiveThreadId);
    const result = await backend.startTurn(message, snapshots, images, {
      ...options,
      clientOperationId: payload?.clientOperationId ? String(payload.clientOperationId) : undefined,
      transport: {
        rendererSubmittedAtEpochMs: Number(payload?.rendererSubmittedAtEpochMs) || null,
        mainReceivedAtEpochMs,
      },
    });
    writeRuntimeLog('chat-send', `target=${result?.runtimeTargetId || ''} accepted=${Boolean(result?.accepted)} thread=${result?.threadId || ''} turn=${result?.turnId || ''}`);
    return result;
  });
  ipcMain.handle('chat:interrupt', async (_event, identity) => {
    sendStatus('stopping…');
    if (seededAcceptance) {
      const turnId = seededStreamTurnId;
      const threadId = seededStreamThreadId;
      if (!turnId || !threadId || threadId !== seededActiveThreadId) throw new Error('There is no active Codex turn to stop.');
      clearInterval(seededStreamTimer);
      seededStreamTimer = null;
      seededStreamTurnId = null;
      seededStreamThreadId = null;
      setTimeout(() => send('turn:completed', { threadId, status: 'interrupted' }), 80);
      return { interrupted: true, threadId, turnId };
    }
    return backend.interruptTurn({
      runtimeTargetId: identity?.runtimeTargetId ? String(identity.runtimeTargetId) : undefined,
      sessionId: identity?.sessionId ? String(identity.sessionId) : undefined,
      turnId: identity?.turnId ? String(identity.turnId) : undefined,
    });
  });
}

function beginManualWindowDrag(point) {
  if (!mainWindow || mainWindow.isDestroyed() || !validScreenPoint(point)) return;
  manualWindowDrag = {
    pointer: { x: point.x, y: point.y },
    bounds: mainWindow.getBounds(),
  };
}

function moveManualWindowDrag(point) {
  if (!manualWindowDrag || !mainWindow || mainWindow.isDestroyed() || !validScreenPoint(point)) return;
  mainWindow.setPosition(
    Math.round(manualWindowDrag.bounds.x + point.x - manualWindowDrag.pointer.x),
    Math.round(manualWindowDrag.bounds.y + point.y - manualWindowDrag.pointer.y),
    false,
  );
}

function validScreenPoint(point) {
  return Number.isFinite(point?.x) && Number.isFinite(point?.y);
}

function startSeededStream(threadId) {
  if (seededStreamTurnId) throw new Error('A seeded acceptance turn is already active.');
  seededStreamTurnId = `seeded-turn-${Date.now()}`;
  seededStreamThreadId = threadId;
  const turnId = seededStreamTurnId;
  let line = 0;
  send('stream:update', { threadId, kind: 'thinking', lifecycle: 'started', title: 'Thinking', text: '', itemId: `${turnId}-thinking` });
  send('stream:update', { threadId, kind: 'thinking', lifecycle: 'delta', title: 'Thinking', text: 'Preparing a long streamed response.', itemId: `${turnId}-thinking` });
  send('stream:update', { threadId, kind: 'thinking', lifecycle: 'completed', title: 'Thinking', text: 'Preparing a long streamed response.', status: 'done', itemId: `${turnId}-thinking` });
  send('stream:update', { threadId, kind: 'tool', lifecycle: 'started', title: 'Command', text: 'Inspecting acceptance context', itemId: `${turnId}-tool` });
  send('stream:update', { threadId, kind: 'toolOutput', lifecycle: 'delta', title: 'Command output', text: 'Acceptance context ready.', itemId: `${turnId}-tool` });
  send('stream:update', { threadId, kind: 'tool', lifecycle: 'completed', title: 'Command', text: '', status: 'done', itemId: `${turnId}-tool` });
  seededStreamTimer = setInterval(() => {
    if (seededStreamTurnId !== turnId) return;
    line += 1;
    send('stream:update', { threadId, kind: 'assistant', lifecycle: 'delta', title: 'Codex', text: `Streaming acceptance line ${line}.\n`, itemId: `${turnId}-assistant` });
    if (line < 300) return;
    clearInterval(seededStreamTimer);
    seededStreamTimer = null;
    seededStreamTurnId = null;
    seededStreamThreadId = null;
    send('turn:completed', { threadId, status: 'completed' });
  }, 60);
  return { accepted: true, threadId, turnId };
}

function readModelOptions(payload) {
  const model = String(payload?.model || '').trim();
  const effort = String(payload?.effort || '').trim();
  return {
    ...(model ? { model } : {}),
    ...(effort ? { effort } : {}),
  };
}

async function startBackend() {
  await backend.initialize();
  if (backend.getRuntimeState().activeTargetId) await backend.warmSelectedTarget();
}

async function launchInTerminal(launch) {
  const terminal = process.platform === 'win32'
    ? { command: 'wt.exe', args: ['-w', 'new', launch.command, ...launch.args] }
    : process.platform === 'darwin'
      ? { command: 'open', args: ['-a', 'Terminal', launch.command, ...launch.args] }
      : { command: process.env.TERMINAL || 'x-terminal-emulator', args: ['-e', launch.command, ...launch.args] };
  await new Promise((resolve, reject) => {
    const child = spawn(terminal.command, terminal.args, {
      detached: true,
      stdio: 'ignore',
      windowsHide: false,
    });
    child.once('spawn', () => {
      child.unref();
      resolve();
    });
    child.once('error', reject);
  });
}

async function captureContext({ point = screen.getCursorScreenPoint() } = {}) {
  const startedAt = performance.now();
  let nativeResult = null;
  let attached = false;
  showWindow({ openPanel: true, focusComposer: true });
  sendStatus('Capturing context…');
  try {
    nativeResult = await capturePointerContext(point);
    writeRuntimeLog('capture', `total=${Math.round(performance.now() - startedAt)} native=${nativeResult?.elapsedMilliseconds ?? ''} preview=${nativeResult?.previewMilliseconds ?? ''} stages=${JSON.stringify(nativeResult?.timings || {})}`);
    if (nativeResult?.snapshot) {
      send('context:added', {
        id: randomUUID(),
        snapshot: nativeResult.snapshot,
        previewText: nativeResult.previewText,
        imageDataUrl: null,
      });
      attached = true;
      sendStatus(`Context attached · ${Math.round(performance.now() - startedAt)} ms`);
    } else if (!nativeResult?.preservePrevious) {
      sendStatus('No accessible context was exposed under the pointer', true);
    }
  } catch (error) {
    sendStatus(`Context capture failed: ${error.message}`, true);
  }
  return {
    attached,
    totalMilliseconds: Math.round(performance.now() - startedAt),
    nativeMilliseconds: nativeResult?.elapsedMilliseconds ?? null,
  };
}

async function capturePointerContext(point = null) {
  return process.platform === 'win32'
    ? captureHost.request('capture', point ? { point } : {})
    : capturePortableContext(process.platform);
}

async function selectImageContext({ includePointerContext = false } = {}) {
  const wasVisible = mainWindow?.isVisible();
  let pointerContext = null;
  if (includePointerContext) {
    try {
      pointerContext = await capturePointerContext();
    } catch (error) {
      sendStatus(`Pointer context capture failed; image selection remains available: ${error.message}`, true);
    }
  }
  mainWindow?.hide();
  try {
    const result = process.platform === 'win32'
      ? await captureHost.request('selectImage')
      : await selectImageRegion();
    if (!result?.cancelled && result?.dataUrl) {
      send('context:added', {
        id: randomUUID(),
        snapshot: pointerContext?.snapshot || null,
        previewText: pointerContext?.previewText || 'User-selected screen region',
        imageDataUrl: result.dataUrl,
        bounds: result.bounds,
      });
      sendStatus(`${pointerContext?.snapshot ? 'Image + pointer context' : 'Image'} attached · ${result.bounds.width}×${result.bounds.height}`);
      showWindow({ openPanel: true, focusComposer: true });
      return result;
    }
    if (result?.errorMessage) sendStatus(`Image selection failed: ${result.errorMessage}`, true);
  } catch (error) {
    sendStatus(`Image selection failed: ${error.message}`, true);
  }
  if (wasVisible) showWindow();
  return { cancelled: true };
}

function showWindow({ openPanel: shouldOpenPanel = false, focusComposer = false, animate = true, position = null } = {}) {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  if (shouldOpenPanel) setPanelOpen(true, { animate, position });
  if (focusComposer) {
    mainWindow.show();
    mainWindow.focus();
    send('composer:focus', true);
  } else {
    mainWindow.showInactive();
  }
}

function toggleExpanded() {
  if (!mainWindow) return;
  largePanel = !largePanel;
  if (!panelOpen) panelOpen = true;
  const display = screen.getDisplayMatching(mainWindow.getBounds());
  displaySignature = signatureForDisplay(display);
  send('window:presentation', { open: true, large: largePanel });
  animateWindowBounds(targetBoundsForDisplay(display));
  send('window:expanded', largePanel);
}

function setWindowHovered(hovered) {
  clearTimeout(hoverCollapseTimer);
  hoverCollapseTimer = null;
  if (hovered) {
    setPanelOpen(true);
    return;
  }
  hoverCollapseTimer = setTimeout(() => setPanelOpen(false), HOVER_COLLAPSE_DELAY_MS);
}

function startWindowHoverTracking() {
  clearInterval(hoverPollTimer);
  hoverPollTimer = setInterval(() => {
    if (!mainWindow || mainWindow.isDestroyed() || !mainWindow.isVisible() || mainWindow.isMinimized()) {
      pointerInsideWindow = false;
      return;
    }
    const pointer = screen.getCursorScreenPoint();
    const bounds = mainWindow.getBounds();
    const hitBounds = panelOpen ? bounds : compactHitBounds(bounds);
    const inside = pointer.x >= hitBounds.x
      && pointer.x < hitBounds.x + hitBounds.width
      && pointer.y >= hitBounds.y
      && pointer.y < hitBounds.y + hitBounds.height;
    if (inside === pointerInsideWindow) return;
    pointerInsideWindow = inside;
    setWindowHovered(inside);
  }, 100);
}

function compactHitBounds(windowBounds) {
  return {
    x: Math.round(windowBounds.x + (windowBounds.width - COMPACT_WINDOW_SIZE) / 2),
    y: windowBounds.y + windowBounds.height - COMPACT_WINDOW_SIZE,
    width: COMPACT_WINDOW_SIZE,
    height: COMPACT_WINDOW_SIZE,
  };
}

function setPanelOpen(open, { animate = true, position = null } = {}) {
  clearTimeout(hoverCollapseTimer);
  hoverCollapseTimer = null;
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (panelOpen === open && !position) return;
  panelOpen = open;
  const display = position
    ? screen.getDisplayNearestPoint(position)
    : screen.getDisplayMatching(mainWindow.getBounds());
  displaySignature = signatureForDisplay(display);
  if (open) mainWindow.setIgnoreMouseEvents(false);
  else mainWindow.setIgnoreMouseEvents(true, { forward: true });
  send('window:presentation', { open, large: largePanel });
  const target = targetBoundsForDisplay(display, position);
  if (position) mainWindow.setBounds(target, false);
  setTimeout(() => send('window:bounds-settled', { open: panelOpen }), animate ? 240 : 50);
}

function animateWindowBounds(target, duration = 300) {
  clearTimeout(boundsAnimationTimer);
  boundsAnimationTimer = null;
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const start = mainWindow.getBounds();
  const startedAt = performance.now();
  const step = () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    const elapsed = performance.now() - startedAt;
    const progress = Math.min(1, elapsed / duration);
    const eased = progress < 0.5
      ? 4 * progress * progress * progress
      : 1 - Math.pow(-2 * progress + 2, 3) / 2;
    mainWindow.setBounds(interpolateWindowBounds(start, target, eased), false);
    if (progress < 1) boundsAnimationTimer = setTimeout(step, 16);
    else {
      boundsAnimationTimer = null;
      send('window:bounds-settled', { open: panelOpen });
    }
  };
  step();
}

function seededChatState() {
  const now = Math.floor(Date.now() / 1000);
  const sessions = [
    { id: 'seeded-zommi-thread', name: 'Structured context', preview: 'Structured context', updatedAt: now, threadSource: 'zommi' },
    { id: 'seeded-secondary-thread', name: 'Background comparison', preview: 'Background comparison', updatedAt: now - 30, threadSource: 'zommi' },
  ];
  return {
    activeThreadId: seededActiveThreadId,
    activeModel: 'fixture-standard',
    activeEffort: 'medium',
    models: [{
      id: 'fixture-standard', model: 'fixture-standard', displayName: 'Fixture Standard', hidden: false,
      supportedReasoningEfforts: ['low', 'medium', 'high', 'xhigh'].map((reasoningEffort) => ({ reasoningEffort, description: '' })),
      defaultReasoningEffort: 'medium',
    }],
    sessions,
    runtime: seededRuntimeState(),
    runtimeTargetId: 'seeded-codex-target',
    capabilities: seededRuntimeState().capabilities,
    sessionBinding: { runtimeTargetId: 'seeded-codex-target', sessionId: seededActiveThreadId },
    activeTurns: seededStreamTurnId && seededStreamThreadId
      ? [{ threadId: seededStreamThreadId, turnId: seededStreamTurnId }]
      : [],
    thread: { id: seededActiveThreadId, cwd: '/home/example/Project/zommi', turns: seededHistory(seededActiveThreadId) },
  };
}

function seededRuntimeState() {
  const activeTarget = {
    id: 'seeded-codex-target',
    runtimeId: 'codex',
    adapterId: 'codex-app-server',
    displayName: 'Codex',
    protocolName: 'app-server',
    classification: 'native',
    status: 'ready',
    capabilities: [
      'session.list.v1', 'session.create.v1', 'session.resume.v1', 'history.read.v1',
      'turn.stream.v1', 'turn.interrupt.v1', 'input.image.v1', 'model.select.v1',
      'reasoning.select.v1',
    ],
    executionHost: { id: 'wsl:ubuntu', kind: 'wsl', name: 'Ubuntu', displayName: 'WSL · Ubuntu', isDefault: true },
  };
  return {
    targets: [activeTarget],
    activeTargetId: activeTarget.id,
    activeTarget,
    capabilities: [...activeTarget.capabilities],
    settings: {
      hosts: [
        activeTarget.executionHost,
        { id: 'native:win32', kind: 'native', platform: 'win32', displayName: 'Windows', isDefault: false },
      ],
      adapters: [
        { adapterId: 'codex-app-server', displayName: 'Codex', protocolName: 'app-server', hostKinds: ['native', 'wsl'], acceptsEndpoint: false },
        { adapterId: 'openclaw-acp', displayName: 'OpenClaw', protocolName: 'ACP', hostKinds: ['native', 'wsl'], acceptsEndpoint: false },
        { adapterId: 'openclaw-gateway', displayName: 'OpenClaw', protocolName: 'Direct Gateway', hostKinds: ['remote'], acceptsEndpoint: true },
      ],
      overrides: [{
        id: 'seeded-openclaw-endpoint', adapterId: 'openclaw-gateway', profileId: 'default',
        endpoint: 'wss://gateway.example.test/',
      }],
    },
  };
}

function seededHistory(threadId) {
  if (threadId === 'seeded-secondary-thread') {
    return [{ id: 'secondary-turn', items: [
      { id: 'secondary-user', type: 'userMessage', content: [{ type: 'text', text: 'Keep this chat available while another session is running.' }] },
      { id: 'secondary-agent', type: 'agentMessage', phase: 'final', status: 'completed', text: 'This independent session remains interactive.' },
    ] }];
  }
  const turns = Array.from({ length: 42 }, (_value, index) => {
    const items = [
      { id: `history-user-${index + 1}`, type: 'userMessage', content: [{ type: 'text', text: `History question ${index + 1}` }] },
      { id: `history-agent-${index + 1}`, type: 'agentMessage', phase: 'final', status: 'completed', text: `History answer ${index + 1}` },
    ];
    if (index === 41) {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="#edf4ff"/><circle cx="320" cy="170" r="90" fill="#779cff"/><text x="320" y="310" text-anchor="middle" font-family="sans-serif" font-size="28" fill="#253b68">ZOMMI IMAGE PREVIEW</text></svg>';
      items.push(
        { id: 'history-generated-image', type: 'imageGeneration', status: 'completed', revisedPrompt: 'Zommi preview', result: Buffer.from(svg).toString('base64'), savedPath: '/tmp/zommi-preview.svg', failure: null },
        { id: 'history-generated-html', type: 'mcpToolCall', status: 'completed', server: 'preview', tool: 'render', result: { content: [{ type: 'resource', resource: { uri: 'preview.html', mimeType: 'text/html', text: '<main style="font:28px sans-serif;padding:48px;color:#253b68">ZOMMI_HTML_PREVIEW</main>' } }], structuredContent: null } },
      );
    }
    return { id: `history-turn-${index + 1}`, items };
  });
  if (seededStreamThreadId === threadId && seededStreamTurnId) {
    turns.push({ id: seededStreamTurnId, items: [
      { id: `${seededStreamTurnId}-user`, type: 'userMessage', content: [{ type: 'text', text: 'seeded streaming input acceptance' }] },
      { id: `${seededStreamTurnId}-thinking`, type: 'reasoning', status: 'completed', summary: ['Preparing a long streamed response.'], content: [] },
    ] });
  }
  return turns;
}

function seedAcceptanceContexts() {
  const now = new Date();
  const base = {
    snapshotId: 'electron-seeded-docs',
    observedAtUtc: now.toISOString(),
    expiresAtUtc: new Date(now.getTime() + 300_000).toISOString(),
    surfaceKind: 'Browser', application: 'Acceptance Browser', processName: 'acceptance-browser',
    windowTitle: 'Seeded documentation tab', locator: { kind: 'URL', value: 'https://docs.example.com/guide' },
    selection: ['SELECTED_TEXT_IS_PRIMARY'],
    visibleText: Array.from({ length: 80 }, (_value, index) => `Scrollable surrounding documentation line ${index + 1}`),
    indicatedTarget: null, confidence: 'high', limitation: null,
  };
  send('context:added', { id: randomUUID(), snapshot: base, previewText: seededPreview(base), imageDataUrl: null });
  const second = { ...base, snapshotId: 'electron-seeded-shop', windowTitle: 'Seeded shopping tab', locator: { kind: 'URL', value: 'https://shop.example.com/item' }, selection: [], visibleText: ['Second tab text'] };
  send('context:added', { id: randomUUID(), snapshot: second, previewText: seededPreview(second), imageDataUrl: null });
  send('context:added', { id: randomUUID(), snapshot: null, previewText: 'User-selected screen region', imageDataUrl: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' });
}

function seededPreview(snapshot) {
  return ['ZOMMI INVOCATION CONTEXT', `PRIMARY SURFACE SELECTION:\n${snapshot.selection.join('\n')}`, `Window: ${snapshot.windowTitle}`, `URL: ${snapshot.locator.value}`, ...snapshot.visibleText].filter(Boolean).join('\n');
}

async function captureTransportEvidence(path) {
  const result = { sampleCount: 0, targetMilliseconds: 50, samples: [] };
  try {
    await backend.getChatState();
    for (let index = 0; index < 40; index += 1) {
      const probe = await evaluateRenderer('window.zommi.probeTransport()');
      const value = probe?.metric?.rendererToProtocolWriteMilliseconds;
      if (Number.isFinite(value)) result.samples.push(value);
    }
    result.sampleCount = result.samples.length;
    result.p50Milliseconds = percentile(result.samples, 0.50);
    result.p95Milliseconds = percentile(result.samples, 0.95);
    result.maxMilliseconds = result.samples.length ? Math.max(...result.samples) : null;
    result.passed = result.sampleCount === 40 && result.p95Milliseconds < result.targetMilliseconds;
  } catch (error) {
    result.error = String(error?.message || error);
    result.passed = false;
  }
  await writeFile(path, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function send(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
}

function sendStatus(message, warning = false) {
  writeRuntimeLog(warning ? 'warning' : 'status', message);
  send('status:changed', { message: String(message), warning });
}

async function initializeRuntimeLog() {
  if (process.platform !== 'win32') return;
  runtimeLogPath = join(app.getPath('userData'), 'zommi-runtime.log');
  try {
    await writeFile(runtimeLogPath, `${new Date().toISOString()} startup packaged=${app.isPackaged} resources=${process.resourcesPath}\n`, 'utf8');
  } catch (error) {
    runtimeLogPath = null;
    console.error('Could not initialize the Zommi runtime log.', error);
  }
}

function writeRuntimeLog(kind, message) {
  if (!runtimeLogPath) return;
  const safeMessage = String(message || '').replace(/[\r\n]+/g, ' ').slice(0, 2000);
  void appendFile(runtimeLogPath, `${new Date().toISOString()} ${kind} ${safeMessage}\n`, 'utf8').catch(() => {});
}

function isWarningStatus(message) {
  return /error|failed|exited|unavailable|timed? out|did not respond/i.test(String(message));
}

function sendShortcutState() {
  send('shortcuts:state', shortcuts);
}
