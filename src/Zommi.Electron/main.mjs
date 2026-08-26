import { app, BrowserWindow, Menu, Tray, clipboard, globalShortcut, ipcMain, nativeImage, nativeTheme, screen } from 'electron';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { NativeHostClient } from './native-host.mjs';
import { PortableCodexBridge } from './codex-bridge.mjs';
import { capturePortableContext } from './platform-capture.mjs';
import { selectImageRegion } from './image-selector.mjs';

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
const noAutoLaunch = process.argv.includes('--no-auto-launch');
let mainWindow = null;
let tray = null;
let backend = null;
let quitting = false;
let expanded = false;
let displaySignature = null;
let shortcuts = { context: false, image: false };
let seededStreamTimer = null;
let seededStreamTurnId = null;
let seededStreamThreadId = null;
let seededActiveThreadId = 'seeded-zommi-thread';

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow());
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
  nativeTheme.themeSource = 'light';
  app.setAppUserModelId('com.zommi.desktop');
  if (process.platform === 'darwin') app.dock?.hide();
  createWindow();
  createTray();
  createBackend();
  registerIpc();
  registerShortcuts();

  if (seededAcceptance) {
    mainWindow.webContents.once('did-finish-load', () => {
      seedAcceptanceContexts();
      send('acceptance:conversation', true);
      sendStatus('seeded Electron UI acceptance');
      sendShortcutState();
      showWindow({ x: 80, y: 80 });
      if (acceptanceEvidencePath) {
        setTimeout(() => captureAcceptanceEvidence(acceptanceEvidencePath), 700);
      }
      if (acceptanceInputProbePath) {
        setTimeout(() => runAcceptanceInputProbe(acceptanceInputProbePath), 900);
      }
    });
  } else {
    mainWindow.webContents.once('did-finish-load', sendShortcutState);
    if (!noAutoLaunch) startBackend().catch((error) => sendStatus(`Codex connection failed: ${error.message}`, true));
    else showWindow();
  }

  app.on('activate', () => showWindow());
  app.on('will-quit', () => {
    globalShortcut.unregisterAll();
    backend?.stop?.();
  });
}

async function runAcceptanceInputProbe(path) {
  const result = { inputPath: 'webContents.sendInputEvent' };
  try {
    const sessionTogglePoint = await rendererElementCenter('#ToggleSessions');
    mainWindow.webContents.sendInputEvent({ type: 'mouseMove', x: sessionTogglePoint.x, y: sessionTogglePoint.y });
    await delay(260);
    result.sessionSidebarHover = await evaluateRenderer(`document.querySelector('#SessionSidebar')?.classList.contains('open') === true`);
    result.sessionSidebarHalfHeight = await evaluateRenderer(`{ const p = document.querySelector('#SessionSidebar')?.getBoundingClientRect(); const g = document.querySelector('.glass')?.getBoundingClientRect(); return Boolean(p && g && p.height <= g.height / 2 + 1); }`);
    result.activeSessionShowsRead = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-zommi-thread"]')?.dataset.status === 'read'`);
    result.inactiveSessionShowsDone = await evaluateRenderer(`document.querySelector('#SessionList .session-item[data-thread-id="seeded-secondary-thread"]')?.dataset.status === 'done'`);
    result.sessionStatusesUseIcons = await evaluateRenderer(`document.querySelectorAll('#SessionList .session-item .session-status .ui-icon').length === 2`);
    await clickRendererElement('#ToggleSessions');
    await clickRendererElement('#ModelSummary');
    await delay(260);
    result.modelPanel = await evaluateRenderer(`document.querySelector('#ModelPanel')?.hidden === false`);
    result.modelPanelDiagnostics = await evaluateRenderer(`{ const e = document.querySelector('#ModelPanel'); const r = e?.getBoundingClientRect(); const s = e ? getComputedStyle(e) : null; return r && s ? { x: r.x, y: r.y, width: r.width, height: r.height, display: s.display, opacity: s.opacity, visibility: s.visibility } : null; }`);
    result.modelPanelOpensUpward = await evaluateRenderer(`{ const p = document.querySelector('#ModelPanel')?.getBoundingClientRect(); const s = document.querySelector('#ModelSummary')?.getBoundingClientRect(); return Boolean(p && s && p.bottom < s.top); }`);
    result.modelSwitchBottomRight = await evaluateRenderer(`{ const s = document.querySelector('#ModelSummary')?.getBoundingClientRect(); const c = document.querySelector('.composer-shell')?.getBoundingClientRect(); return Boolean(s && c && s.left > c.left + c.width / 2 && s.bottom > c.top + c.height / 2); }`);
    if (acceptanceModelEvidencePath) await captureAcceptanceEvidence(acceptanceModelEvidencePath);
    const effortBefore = await evaluateRenderer(`document.querySelector('#EffortList .effort-option.selected')?.dataset.effort || ''`);
    await clickRendererElement('#EffortList .effort-option:not(.selected)');
    await delay(180);
    const effortAfter = await evaluateRenderer(`document.querySelector('#EffortList .effort-option.selected')?.dataset.effort || ''`);
    result.reasoningChanged = Boolean(effortBefore && effortAfter && effortBefore !== effortAfter);
    await clickRendererElement('#ModelSummary');
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
      .filter(([key]) => !['inputPath', 'modelPanelDiagnostics', 'manualScrollDiagnostics', 'thinkingCardsPerTurn'].includes(key))
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
  displaySignature = signatureForDisplay(initialDisplay);
  mainWindow = new BrowserWindow({
    title: 'Zommi — floating Codex chat',
    icon: createZommiIcon(),
    width: initialSize.width,
    height: initialSize.height,
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
    if (currentDisplay.id === display.id) applyAdaptiveWindowSize(currentDisplay, true);
  });
}

function calculateAdaptiveWindowSize(workArea, isExpanded) {
  const horizontalScale = isExpanded ? 0.72 : 0.56;
  const verticalScale = isExpanded ? 0.84 : 0.72;
  const minimumWidth = isExpanded ? 980 : 840;
  const maximumWidth = isExpanded ? 1360 : 1120;
  const minimumHeight = isExpanded ? 720 : 600;
  const maximumHeight = isExpanded ? 940 : 840;
  const availableWidth = Math.max(640, Math.floor(workArea.width - 32));
  const availableHeight = Math.max(500, Math.floor(workArea.height - 32));
  return {
    width: Math.min(availableWidth, clamp(Math.round(workArea.width * horizontalScale), minimumWidth, maximumWidth)),
    height: Math.min(availableHeight, clamp(Math.round(workArea.height * verticalScale), minimumHeight, maximumHeight)),
  };
}

function applyAdaptiveWindowSize(display, force = false) {
  const nextSignature = signatureForDisplay(display);
  if (!force && nextSignature === displaySignature) return;
  displaySignature = nextSignature;
  const size = calculateAdaptiveWindowSize(display.workArea, expanded);
  mainWindow.setContentSize(size.width, size.height, false);
}

function signatureForDisplay(display) {
  return `${display.id}:${display.workArea.width}x${display.workArea.height}@${display.scaleFactor}:${expanded}`;
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(value, maximum));
}

function createTray() {
  tray = new Tray(createZommiIcon());
  tray.setToolTip('Zommi floating Codex chat');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open floating chat', click: () => showWindow() },
    { label: 'Capture context (Alt+A)', click: () => captureContext() },
    { label: 'Select image + pointer context (Alt+Shift+A)', click: () => selectImageContext({ includePointerContext: true }) },
    { type: 'separator' },
    { label: 'Exit Zommi', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('double-click', () => showWindow());
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
    backend = new NativeHostClient(executable);
    backend.on('status', (status) => sendStatus(status, isWarningStatus(status)));
    backend.on('streamUpdate', (update) => send('stream:update', update));
    backend.on('turnCompleted', (status) => send('turn:completed', status));
    backend.on('error', (error) => sendStatus(error.message, true));
    backend.on('protocolError', (error) => sendStatus(error.message, true));
    return;
  }
  backend = new PortableCodexBridge();
  backend.on('status', (status) => sendStatus(status, isWarningStatus(status)));
  backend.on('streamUpdate', (update) => send('stream:update', update));
  backend.on('turnCompleted', (status) => send('turn:completed', status));
}

function registerShortcuts() {
  shortcuts.context = globalShortcut.register('Alt+A', () => captureContext());
  shortcuts.image = globalShortcut.register('Alt+Shift+A', () => selectImageContext({ includePointerContext: true }));
  sendShortcutState();
}

function registerIpc() {
  ipcMain.on('window:hide', () => mainWindow?.hide());
  ipcMain.on('window:toggle-expanded', () => toggleExpanded());
  ipcMain.on('acceptance:hover-state', (_event, hovered) => {
    if (!seededAcceptance) return;
    const path = hovered ? acceptanceHoverActivePath : acceptanceHoverRestPath;
    if (path) setTimeout(() => captureAcceptanceEvidence(path), 560);
  });
  ipcMain.handle('clipboard:write', (_event, text) => clipboard.writeText(String(text || '')));
  ipcMain.handle('context:select-image', () => selectImageContext());
  ipcMain.handle('chat:state', async () => {
    if (seededAcceptance) return seededChatState();
    if (process.platform === 'win32') return backend.request('getChatState');
    return backend.getChatState();
  });
  ipcMain.handle('chat:create-session', async (_event, payload) => {
    const options = readModelOptions(payload);
    if (seededAcceptance) {
      seededActiveThreadId = 'seeded-secondary-thread';
      return seededChatState();
    }
    if (process.platform === 'win32') return backend.request('createSession', options);
    return backend.createSession(options);
  });
  ipcMain.handle('chat:switch-session', async (_event, threadId) => {
    const id = String(threadId || '').trim();
    if (!id) throw new Error('A Codex thread id is required.');
    if (seededAcceptance) {
      seededActiveThreadId = id;
      return seededChatState();
    }
    if (process.platform === 'win32') return backend.request('switchSession', { threadId: id });
    return backend.switchSession(id);
  });
  ipcMain.handle('chat:send', async (_event, payload) => {
    const message = String(payload?.message || '').trim();
    if (!message) throw new Error('A message is required.');
    const attachments = Array.isArray(payload.attachments) ? payload.attachments : [];
    const snapshots = attachments.map((item) => item.snapshot).filter(Boolean);
    const images = attachments.map((item) => item.imageDataUrl).filter(Boolean);
    const options = readModelOptions(payload);
    sendStatus('thinking…');
    if (seededAcceptance) return startSeededStream(seededActiveThreadId);
    if (process.platform === 'win32') return backend.request('startTurn', { message, snapshots, images, ...options });
    return backend.startTurn(message, snapshots, images, options);
  });
  ipcMain.handle('chat:interrupt', async () => {
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
    if (process.platform === 'win32') return backend.request('interruptTurn');
    return backend.interruptTurn();
  });
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
  if (process.platform === 'win32') return backend.request('startCodex');
  return backend.ensureStarted();
}

async function captureContext() {
  try {
    const result = await capturePointerContext();
    if (result?.snapshot) {
      send('context:added', {
        id: randomUUID(),
        snapshot: result.snapshot,
        previewText: result.previewText,
        imageDataUrl: null,
      });
      sendStatus('Context attached');
    } else if (!result?.preservePrevious) {
      sendStatus('No accessible context was exposed under the pointer', true);
    }
  } catch (error) {
    sendStatus(`Context capture failed: ${error.message}`, true);
  }
  showWindow();
}

async function capturePointerContext() {
  return process.platform === 'win32'
    ? backend.request('capture')
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
      ? await backend.request('selectImage')
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
      showWindow();
      return result;
    }
    if (result?.errorMessage) sendStatus(`Image selection failed: ${result.errorMessage}`, true);
  } catch (error) {
    sendStatus(`Image selection failed: ${error.message}`, true);
  }
  if (wasVisible) showWindow();
  return { cancelled: true };
}

function showWindow(pointerOverride = null) {
  if (!mainWindow) return;
  const pointer = pointerOverride || screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(pointer);
  applyAdaptiveWindowSize(display);
  const workArea = display.workArea;
  const [width, height] = mainWindow.getSize();
  let x = pointer.x + 24;
  let y = pointer.y + 24;
  if (x + width > workArea.x + workArea.width) x = pointer.x - width - 24;
  if (y + height > workArea.y + workArea.height) y = pointer.y - height - 24;
  x = Math.max(workArea.x, Math.min(x, workArea.x + workArea.width - width));
  y = Math.max(workArea.y, Math.min(y, workArea.y + workArea.height - height));
  mainWindow.setPosition(Math.round(x), Math.round(y), false);
  mainWindow.show();
  mainWindow.focus();
  send('composer:focus', true);
}

function toggleExpanded() {
  if (!mainWindow) return;
  expanded = !expanded;
  const display = screen.getDisplayMatching(mainWindow.getBounds());
  applyAdaptiveWindowSize(display, true);
  send('window:expanded', expanded);
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
    activeTurns: seededStreamTurnId && seededStreamThreadId
      ? [{ threadId: seededStreamThreadId, turnId: seededStreamTurnId }]
      : [],
    thread: { id: seededActiveThreadId, turns: seededHistory(seededActiveThreadId) },
  };
}

function seededHistory(threadId) {
  if (threadId === 'seeded-secondary-thread') {
    return [{ id: 'secondary-turn', items: [
      { id: 'secondary-user', type: 'userMessage', content: [{ type: 'text', text: 'Keep this chat available while another session is running.' }] },
      { id: 'secondary-agent', type: 'agentMessage', phase: 'final', status: 'completed', text: 'This independent session remains interactive.' },
    ] }];
  }
  const turns = Array.from({ length: 42 }, (_value, index) => ({
    id: `history-turn-${index + 1}`,
    items: [
      { id: `history-user-${index + 1}`, type: 'userMessage', content: [{ type: 'text', text: `History question ${index + 1}` }] },
      { id: `history-agent-${index + 1}`, type: 'agentMessage', phase: 'final', status: 'completed', text: `History answer ${index + 1}` },
    ],
  }));
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
  return ['ZOMMI INVOCATION CONTEXT', `PRIMARY SELECTION:\n${snapshot.selection.join('\n')}`, `Window: ${snapshot.windowTitle}`, `URL: ${snapshot.locator.value}`, ...snapshot.visibleText].filter(Boolean).join('\n');
}

function send(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
}

function sendStatus(message, warning = false) {
  send('status:changed', { message: String(message), warning });
}

function isWarningStatus(message) {
  return /error|failed|exited|timed? out|did not respond/i.test(String(message));
}

function sendShortcutState() {
  send('shortcuts:state', shortcuts);
}
