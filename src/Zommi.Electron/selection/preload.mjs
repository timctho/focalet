import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('zommiSelection', {
  complete: (rectangle) => ipcRenderer.send('selection:complete', rectangle),
  cancel: () => ipcRenderer.send('selection:cancel'),
  onInitialize: (callback) => ipcRenderer.once('selection:init', (_event, payload) => callback(payload)),
});
