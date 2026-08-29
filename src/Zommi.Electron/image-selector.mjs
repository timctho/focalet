import { BrowserWindow, desktopCapturer, ipcMain, screen } from 'electron';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeRectangle, scaleCropRectangle } from './selection-geometry.mjs';

const moduleDirectory = dirname(fileURLToPath(import.meta.url));

export async function selectImageRegion() {
  const pointer = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(pointer);
  const requestedSize = {
    width: Math.max(1, Math.round(display.bounds.width * display.scaleFactor)),
    height: Math.max(1, Math.round(display.bounds.height * display.scaleFactor)),
  };
  const sources = await desktopCapturer.getSources({
    types: ['screen'],
    thumbnailSize: requestedSize,
    fetchWindowIcons: false,
  });
  const source = sources.find((candidate) => String(candidate.display_id) === String(display.id)) || sources[0];
  if (!source || source.thumbnail.isEmpty()) throw new Error('Electron could not capture the current display.');

  const selector = new BrowserWindow({
    title: 'Zommi image selection',
    x: display.bounds.x,
    y: display.bounds.y,
    width: display.bounds.width,
    height: display.bounds.height,
    frame: false,
    show: false,
    transparent: false,
    backgroundColor: '#111111',
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    movable: false,
    fullscreenable: false,
    webPreferences: {
      preload: join(moduleDirectory, 'selection', 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  selector.setMenuBarVisibility(false);
  selector.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  await selector.loadFile(join(moduleDirectory, 'selection', 'index.html'));
  selector.webContents.send('selection:init', { imageDataUrl: source.thumbnail.toDataURL() });
  selector.show();
  selector.setAlwaysOnTop(true, 'screen-saver');
  selector.focus();

  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      ipcMain.removeListener('selection:complete', onComplete);
      ipcMain.removeListener('selection:cancel', onCancel);
      if (!selector.isDestroyed()) selector.destroy();
      resolve(result);
    };
    const onCancel = (event) => {
      if (event.sender === selector.webContents) finish({ cancelled: true });
    };
    const onComplete = (event, rectangle) => {
      if (event.sender !== selector.webContents) return;
      const normalized = normalizeRectangle(rectangle);
      if (normalized.width < 4 || normalized.height < 4) {
        finish({ cancelled: true });
        return;
      }
      const crop = scaleCropRectangle(normalized, display.bounds, source.thumbnail.getSize());
      const cropped = source.thumbnail.crop(crop);
      finish({
        cancelled: false,
        dataUrl: cropped.toDataURL(),
        bounds: {
          x: display.bounds.x + normalized.x,
          y: display.bounds.y + normalized.y,
          width: normalized.width,
          height: normalized.height,
        },
      });
    };
    ipcMain.on('selection:complete', onComplete);
    ipcMain.on('selection:cancel', onCancel);
    selector.on('closed', () => finish({ cancelled: true }));
  });
}
