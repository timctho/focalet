const { app, BrowserWindow, clipboard, ipcMain } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const directory = process.argv[2];
const mode = process.argv[3];
const imageReadDelay = Number(process.argv[4] ?? 1500);
app.setPath('userData', path.join(directory, 'profile'));
app.commandLine.appendSwitch('disable-background-networking');
app.commandLine.appendSwitch('force-renderer-accessibility');
let window;
let enters = 0;
const events = [];
const diagnostics = [];
const save = () => fs.writeFileSync(path.join(directory, 'result.json'), JSON.stringify({ events, enters, diagnostics }));
ipcMain.handle('text', () => clipboard.readText());
ipcMain.handle('image', async () => {
  // Orca native chat obtains a browser image/thumbnail, then separately asks
  // its main process to save clipboard.readImage(). The second read must see
  // the same image even after the first consumer has requested the pixels.
  const preview = clipboard.readImage();
  diagnostics.push({ phase: 'preview', empty: preview.isEmpty(), formats: clipboard.availableFormats() });
  save();
  await new Promise(resolve => setTimeout(resolve, imageReadDelay));
  const image = clipboard.readImage();
  diagnostics.push({ phase: 'save', empty: image.isEmpty(), formats: clipboard.availableFormats() });
  save();
  if (image.isEmpty()) throw new Error('Electron readImage lost the image between preview and save');
  if (!preview.toPNG().equals(image.toPNG())) throw new Error('Electron preview and save read different images');
  return { dataUrl: image.toDataURL(), size: image.getSize() };
});
ipcMain.on('result', (_event, value) => { events.push({ ...value, receivedAt: Date.now() }); save(); });
ipcMain.on('enter', () => { enters++; save(); });
ipcMain.on('ready', () => {
  // File existence is the reader's readiness signal. Publish only after the
  // writer has closed the file, so Windows readers cannot race an open handle.
  fs.writeFileSync(path.join(directory, 'ready.tmp'), JSON.stringify({ window: window.getNativeWindowHandle().readBigUInt64LE().toString(), mode }));
  fs.renameSync(path.join(directory, 'ready.tmp'), path.join(directory, 'ready'));
});
ipcMain.handle('mode', () => mode);
app.whenReady().then(async () => {
  window = new BrowserWindow({ title: 'Zommi Electron clipboard fixture', width: 900, height: 650, alwaysOnTop: true,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), sandbox: true, contextIsolation: true } });
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  await window.loadFile(path.join(__dirname, 'receiver.html'));
  window.show(); window.focus();
});
app.on('window-all-closed', () => app.quit());
