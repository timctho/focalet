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
  const selector = new BrowserWindow({
    title: 'Zommi image selection',
    x: display.bounds.x,
    y: display.bounds.y,
    width: display.bounds.width,
    height: display.bounds.height,
    frame: false,
    show: false,
    transparent: true,
    backgroundColor: '#00000000',
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
  selector.setContentProtection(true);
  selector.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  const sourcePromise = desktopCapturer.getSources({
    types: ['screen'],
    thumbnailSize: requestedSize,
    fetchWindowIcons: false,
  }).then((sources) => {
    const source = sources.find((candidate) => String(candidate.display_id) === String(display.id)) || sources[0];
    if (!source || source.thumbnail.isEmpty()) throw new Error('Electron could not capture the current display.');
    return source;
  });
  void sourcePromise.catch(() => {});
  try {
    await selector.loadFile(join(moduleDirectory, 'selection', 'index.html'));
  } catch (error) {
    if (!selector.isDestroyed()) selector.destroy();
    throw error;
  }
  selector.show();
  selector.setAlwaysOnTop(true, 'screen-saver');
  selector.focus();

  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (result, error = null) => {
      if (settled) return;
      settled = true;
      ipcMain.removeListener('selection:complete', onComplete);
      ipcMain.removeListener('selection:cancel', onCancel);
      if (!selector.isDestroyed()) selector.destroy();
      if (error) reject(error);
      else resolve(result);
    };
    const onCancel = (event) => {
      if (event.sender === selector.webContents) finish({ cancelled: true });
    };
    const onComplete = async (event, rectangle) => {
      if (event.sender !== selector.webContents) return;
      const normalized = normalizeRectangle(rectangle);
      if (normalized.width < 4 || normalized.height < 4) {
        finish({ cancelled: true });
        return;
      }
      try {
        const source = await sourcePromise;
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
      } catch (error) {
        finish(null, error);
      }
    };
    ipcMain.on('selection:complete', onComplete);
    ipcMain.on('selection:cancel', onCancel);
    selector.on('closed', () => finish({ cancelled: true }));
    sourcePromise.catch((error) => finish(null, error));
  });
}
