const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('zommiSelection', {
  complete: (rectangle) => ipcRenderer.send('selection:complete', rectangle),
  cancel: () => ipcRenderer.send('selection:cancel'),
});
