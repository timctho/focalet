const { contextBridge, ipcRenderer } = require('electron');

const subscribe = (channel, callback) => {
  const listener = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};

contextBridge.exposeInMainWorld('zommi', {
  hide: () => ipcRenderer.send('window:hide'),
  toggleExpanded: () => ipcRenderer.send('window:toggle-expanded'),
  selectImage: () => ipcRenderer.invoke('context:select-image'),
  send: (payload) => ipcRenderer.invoke('chat:send', payload),
  interrupt: () => ipcRenderer.invoke('chat:interrupt'),
  getChatState: () => ipcRenderer.invoke('chat:state'),
  createSession: (payload) => ipcRenderer.invoke('chat:create-session', payload),
  switchSession: (threadId) => ipcRenderer.invoke('chat:switch-session', threadId),
  copy: (text) => ipcRenderer.invoke('clipboard:write', text),
  reportAcceptanceHover: (hovered) => ipcRenderer.send('acceptance:hover-state', Boolean(hovered)),
  onContext: (callback) => subscribe('context:added', callback),
  onStatus: (callback) => subscribe('status:changed', callback),
  onStream: (callback) => subscribe('stream:update', callback),
  onTurnCompleted: (callback) => subscribe('turn:completed', callback),
  onFocusComposer: (callback) => subscribe('composer:focus', callback),
  onShortcuts: (callback) => subscribe('shortcuts:state', callback),
  onAcceptanceConversation: (callback) => subscribe('acceptance:conversation', callback),
  onWindowMoving: (callback) => subscribe('window:moving', callback),
});
