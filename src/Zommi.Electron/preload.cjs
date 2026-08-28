const { contextBridge, ipcRenderer } = require('electron');

const subscribe = (channel, callback) => {
  const listener = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};

contextBridge.exposeInMainWorld('zommi', {
  hide: () => ipcRenderer.send('window:hide'),
  openPanel: () => ipcRenderer.send('window:open-panel'),
  setWindowHovered: (hovered) => ipcRenderer.send('window:set-hovered', Boolean(hovered)),
  beginWindowDrag: (point) => ipcRenderer.send('window:drag-start', point),
  moveWindowDrag: (point) => ipcRenderer.send('window:drag-move', point),
  endWindowDrag: () => ipcRenderer.send('window:drag-end'),
  toggleExpanded: () => ipcRenderer.send('window:toggle-expanded'),
  selectImage: () => ipcRenderer.invoke('context:select-image'),
  getRuntimeState: () => ipcRenderer.invoke('runtime:state'),
  requestRuntime: (request) => ipcRenderer.invoke('runtime:request', request),
  getTransportMetrics: () => ipcRenderer.invoke('runtime:transport-metrics'),
  probeTransport: () => ipcRenderer.invoke('runtime:transport-probe', { rendererSubmittedAtEpochMs: Date.now() }),
  refreshRuntimes: (hostId) => ipcRenderer.invoke('runtime:refresh', hostId),
  selectRuntime: (targetId) => ipcRenderer.invoke('runtime:select', targetId),
  saveRuntimeOverride: (value) => ipcRenderer.invoke('runtime:override-save', value),
  removeRuntimeOverride: (id) => ipcRenderer.invoke('runtime:override-remove', id),
  signInRuntime: (targetId) => ipcRenderer.invoke('runtime:sign-in', targetId),
  resolveApproval: (payload) => ipcRenderer.invoke('approval:resolve', payload),
  resolveQuestion: (payload) => ipcRenderer.invoke('question:resolve', payload),
  send: (payload) => ipcRenderer.invoke('chat:send', payload),
  interrupt: (identity) => ipcRenderer.invoke('chat:interrupt', identity),
  getChatState: () => ipcRenderer.invoke('chat:state'),
  createSession: (payload) => ipcRenderer.invoke('chat:create-session', payload),
  switchSession: (threadId) => ipcRenderer.invoke('chat:switch-session', threadId),
  copy: (text) => ipcRenderer.invoke('clipboard:write', text),
  reportAcceptanceHover: (hovered) => ipcRenderer.send('acceptance:hover-state', Boolean(hovered)),
  onContext: (callback) => subscribe('context:added', callback),
  onRuntimeState: (callback) => subscribe('runtime:state', callback),
  onRuntimeEvent: (callback) => subscribe('runtime:event', callback),
  onTransportMetric: (callback) => subscribe('runtime:transport-metric', callback),
  onApprovalRequested: (callback) => subscribe('approval:requested', callback),
  onQuestionRequested: (callback) => subscribe('question:requested', callback),
  onStatus: (callback) => subscribe('status:changed', callback),
  onStream: (callback) => subscribe('stream:update', callback),
  onTurnCompleted: (callback) => subscribe('turn:completed', callback),
  onFocusComposer: (callback) => subscribe('composer:focus', callback),
  onWindowPresentation: (callback) => subscribe('window:presentation', callback),
  onWindowBoundsSettled: (callback) => subscribe('window:bounds-settled', callback),
  onShortcuts: (callback) => subscribe('shortcuts:state', callback),
  onAcceptanceConversation: (callback) => subscribe('acceptance:conversation', callback),
});
