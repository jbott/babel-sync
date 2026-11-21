const { BrowserWindow } = require("electron");

const { allowedNavigation } = require("./connector-navigation.cjs");

function create(connector, partition, userAgent, parentId) {
  const window = new BrowserWindow({
    title: connector.name,
    width: 1000,
    height: 800,
    show: false,
    parent: BrowserWindow.fromId(parentId),
    autoHideMenuBar: true,
    webPreferences: {
      partition,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      nodeIntegrationInWorker: false,
      nodeIntegrationInSubFrames: false,
      webSecurity: true,
      allowRunningInsecureContent: false,
      webviewTag: false,
    },
  });
  const contents = window.webContents;
  contents.removeAllListeners("will-navigate");
  const guard = (event, url) => {
    if (!allowedNavigation(url, connector)) event.preventDefault();
  };
  contents.on("will-navigate", guard);
  contents.on("will-redirect", (event, url, _sameDocument, mainFrame) => {
    if (mainFrame) guard(event, url);
  });
  contents.setWindowOpenHandler(() => ({ action: "deny" }));
  contents.on("will-prevent-unload", (event) => event.preventDefault());
  contents.setUserAgent(userAgent);
  return window;
}

module.exports = { create };
