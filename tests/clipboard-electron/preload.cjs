const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('fixture', {
  text: () => ipcRenderer.invoke('text'), image: () => ipcRenderer.invoke('image'),
  mode: () => ipcRenderer.invoke('mode'), ready: () => ipcRenderer.send('ready'),
  result: value => ipcRenderer.send('result', value), enter: () => ipcRenderer.send('enter'),
});
