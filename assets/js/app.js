import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/babel_sync";
import topbar from "../vendor/topbar";
import { Editor } from "./hooks/editor";
import { Uploader } from "./hooks/uploader";
import { Passkey } from "./hooks/passkey";
import { Folders } from "./hooks/folders";
import { Markdown } from "./hooks/markdown";
import { Canvas } from "./hooks/canvas";
import { BaseMap } from "./hooks/base_map";
import { Finder } from "./hooks/finder";
import { allNotesSaved, anyNoteUnsent } from "./hooks/client";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, Editor, Uploader, Passkey, Folders, Markdown, Canvas, BaseMap, Finder },
});

const barColor = () => (document.documentElement.dataset.theme === "dark" ? "#74cdc0" : "#1f6e69");

topbar.config({ barThickness: 2, shadowBlur: 0 });
window.addEventListener("phx:page-loading-start", (_info) => {
  topbar.config({ barColors: { 0: barColor() } });
  topbar.show(750);
});
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

const RELOAD_GUARD = "babelsync:reloaded-for-assets";
const RELOAD_SPACING_MS = 30_000;
const SAVE_WAIT_MS = 15_000;

window.addEventListener("phx:assets-changed", async () => {
  let last = 0;
  try {
    last = Number(sessionStorage.getItem(RELOAD_GUARD) || 0);
  } catch {}
  if (Date.now() - last < RELOAD_SPACING_MS) return;
  try {
    await allNotesSaved(SAVE_WAIT_MS);
  } catch {
    return;
  }
  try {
    sessionStorage.setItem(RELOAD_GUARD, String(Date.now()));
  } catch {}
  window.location.reload();
});

window.addEventListener("babelsync:close-on-phone", ({ target }) => {
  if (matchMedia("(min-width: 768px)").matches) return;
  liveSocket.execJS(target, target.getAttribute("data-close"));
});

window.addEventListener("beforeunload", (event) => {
  if (anyNoteUnsent()) event.preventDefault();
});

liveSocket.connect();

window.liveSocket = liveSocket;

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({ detail: reloader }) => {
    reloader.enableServerLogs();

    let keyDown;
    window.addEventListener("keydown", (e) => (keyDown = e.key));
    window.addEventListener("keyup", (_e) => (keyDown = null));
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtCaller(e.target);
        } else if (keyDown === "d") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtDef(e.target);
        }
      },
      true,
    );

    window.liveReloader = reloader;
  });
}
