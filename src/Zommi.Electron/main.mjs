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
const noAutoLaunch = process.argv.includes('--no-auto-launch');
let mainWindow = null;
let tray = null;
let backend = null;
let quitting = false;
let expanded = false;
let shortcuts = { context: false, image: false };

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
  mainWindow = new BrowserWindow({
    title: 'Zommi — floating Codex chat',
    width: 760,
    height: 540,
    minWidth: 560,
    minHeight: 380,
    useContentSize: true,
    transparent: true,
    backgroundColor: '#00FFFFFF',
    frame: false,
    roundedCorners: true,
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
  if (process.platform === 'win32' && typeof mainWindow.setBackgroundMaterial === 'function') {
    mainWindow.setBackgroundMaterial('acrylic');
  }
  mainWindow.setMenuBarVisibility(false);
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (event) => event.preventDefault());
  mainWindow.loadFile(join(moduleDirectory, 'renderer', 'index.html'));
  mainWindow.on('close', (event) => {
    if (quitting) return;
    event.preventDefault();
    mainWindow.hide();
  });
}

function createTray() {
  const dot = nativeImage.createFromDataURL('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA4AAAAOCAQAAAC1QeVaAAAAKUlEQVR42mP4z8AARAwMjIwgE4yM/4H4P4j/B+L/QPwfiP8D8X8g/g8AOl0R/RiK5wsAAAAASUVORK5CYII=');
  tray = new Tray(dot);
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
  ipcMain.handle('clipboard:write', (_event, text) => clipboard.writeText(String(text || '')));
  ipcMain.handle('context:select-image', () => selectImageContext());
  ipcMain.handle('chat:send', async (_event, payload) => {
    const message = String(payload?.message || '').trim();
    if (!message) throw new Error('A message is required.');
    const attachments = Array.isArray(payload.attachments) ? payload.attachments : [];
    const snapshots = attachments.map((item) => item.snapshot).filter(Boolean);
    const images = attachments.map((item) => item.imageDataUrl).filter(Boolean);
    sendStatus('thinking…');
    if (process.platform === 'win32') return backend.request('startTurn', { message, snapshots, images });
    return backend.startTurn(message, snapshots, images);
  });
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
  const workArea = screen.getDisplayNearestPoint(pointer).workArea;
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
  mainWindow.setSize(expanded ? 920 : 720, expanded ? 680 : 500, true);
  send('window:expanded', expanded);
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
