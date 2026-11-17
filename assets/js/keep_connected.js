const CHECK_MS = 5_000;
const STUCK_MS = 20_000;

export function keepConnected(liveSocket) {
  const socket = liveSocket.getSocket();
  let everConnected = false;
  let downSince = null;

  setInterval(() => {
    if (socket.isConnected()) {
      everConnected = true;
      downSince = null;
      return;
    }
    if (!everConnected || document.visibilityState !== "visible") {
      downSince = null;
      return;
    }
    downSince ??= Date.now();
    if (Date.now() - downSince < STUCK_MS) return;
    downSince = null;
    socket.disconnect(() => socket.connect());
  }, CHECK_MS);
}
