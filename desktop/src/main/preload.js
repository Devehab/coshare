'use strict';
// The only bridge between the window and the app: a few named calls, no Node access in the page.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('coshare', {
  state: () => ipcRenderer.invoke('state'),
  invite: (groupID) => ipcRenderer.invoke('invite', groupID),
  action: (name, ...args) => ipcRenderer.invoke('action', name, ...args),
  onChange: (callback) => ipcRenderer.on('state-changed', () => callback()),
});
