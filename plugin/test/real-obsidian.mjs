import { spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import puppeteer from "puppeteer-core";
import { connectAgent } from "../../test/e2e/mcp_client.ts";

const repo = join(import.meta.dirname, "../..");
const here = mkdtempSync(join(tmpdir(), "babelsync-obsidian-"));
const server = process.env.BABELSYNC_URL ?? "http://localhost:4000";
const binary = process.env.OBSIDIAN_BIN ?? "/Applications/Obsidian.app/Contents/MacOS/Obsidian";
const realProfile = process.env.OBSIDIAN_PROFILE ?? `${process.env.HOME}/Library/Application Support/obsidian/obsidian.json`;
const chrome = process.env.CHROME_BIN ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const realBefore = existsSync(realProfile) ? statSync(realProfile).mtimeMs : 0;
const realUntouched = () => (existsSync(realProfile) ? statSync(realProfile).mtimeMs : 0) === realBefore;
const results = [];
const children = [];

function check(name, ok, detail = "") {
  results.push({ name, ok });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
}

async function eventually(what, probe, timeout = 20000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      last = await probe();
      if (last === true) return check(what, true);
    } catch (error) {
      last = String(error);
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  check(what, false, `last: ${JSON.stringify(last)}`);
}

async function device(name, port) {
  const profile = join(here, `profile-${name}`);
  const vault = join(here, `vault-${name}`);
  const pluginDir = join(vault, ".obsidian/plugins/babelsync");
  mkdirSync(pluginDir, { recursive: true });
  mkdirSync(profile, { recursive: true });
  cpSync(join(repo, "plugin/main.js"), join(pluginDir, "main.js"));
  cpSync(join(repo, "plugin/manifest.json"), join(pluginDir, "manifest.json"));
  writeFileSync(join(vault, ".obsidian/community-plugins.json"), JSON.stringify(["babelsync"]));
  writeFileSync(
    join(profile, "obsidian.json"),
    JSON.stringify({ vaults: { [`babelsynctest${name}`]: { path: vault, ts: Date.now(), open: true } } }),
  );

  const child = spawn(binary, [`--user-data-dir=${profile}`, `--remote-debugging-port=${port}`], { stdio: "ignore" });
  children.push(child);

  let browser;
  for (let attempt = 0; attempt < 60 && !browser; attempt++) {
    browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${port}`, defaultViewport: null }).catch(() => null);
    if (!browser) await new Promise((resolve) => setTimeout(resolve, 500));
  }
  if (!browser) throw new Error(`could not attach to obsidian ${name}`);

  const page = await findApp(browser);
  const base = await page.evaluate(() => app.vault.adapter.basePath);
  if (base !== vault) throw new Error(`obsidian ${name} opened ${base}, not the throwaway vault`);
  return { name, profile, vault, browser, page, port };
}

async function findApp(browser) {
  for (let attempt = 0; attempt < 80; attempt++) {
    for (const page of await browser.pages()) {
      const ready = await page.evaluate(() => typeof app !== "undefined" && !!app.vault && !!app.workspace?.layoutReady).catch(() => false);
      if (ready) return page;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("obsidian did not finish loading");
}

async function enablePlugin(device) {
  const { page } = device;
  await page.evaluate(async () => {
    window.__opened = [];
    window.open = (url) => void window.__opened.push(String(url));
    await app.plugins.setEnable(true);
    await app.plugins.enablePluginAndSave("babelsync");
    document.querySelectorAll(".modal-container .modal-close-button").forEach((button) => button.click());
  });
  const loaded = await page.evaluate(() => !!app.plugins.plugins.babelsync);
  check(`${device.name}: plugin loads in Obsidian ${await page.evaluate(() => navigator.userAgent.match(/obsidian\/([\d.]+)/i)?.[1])}`, loaded);
}

async function approve(url) {
  const consent = await fetch(url, { redirect: "manual" });
  const cookie = (consent.headers.getSetCookie?.() ?? []).map((line) => line.split(";")[0]).join("; ");
  const html = await consent.text();
  const csrf = html.match(/name="_csrf_token"[^>]*value="([^"]+)"/)?.[1] ?? html.match(/value="([^"]+)"[^>]*name="_csrf_token"/)?.[1];
  const fields = new URLSearchParams({ _csrf_token: csrf, decision: "approve" });
  for (const [, name, value] of html.matchAll(/<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"/g)) {
    if (name !== "_csrf_token") fields.set(name, value.replaceAll("&amp;", "&"));
  }
  const decided = await fetch(new URL("/oauth/authorize", url), {
    method: "POST",
    redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: fields.toString(),
  });
  const location = decided.headers.get("location") ?? "";
  if (!location.startsWith("obsidian://babelsync")) throw new Error(`consent answered ${decided.status} ${location} ${(await decided.text()).slice(0, 300)}`);
  return Object.fromEntries(new URL(location).searchParams);
}

async function signIn(device, vaultId) {
  const { page, name } = device;
  await page.evaluate(
    async (server, name) => {
      const plugin = app.plugins.plugins.babelsync;
      plugin.settings.deviceName = name;
      await plugin.saveSettings();
      app.setting.open();
      app.setting.openTabById("babelsync");
    },
    server,
    name,
  );
  await eventually(`${name}: a fresh settings tab offers one address field and one sign-in button`, () =>
    page.evaluate(() => {
      const tab = document.querySelector(".vertical-tab-content");
      const connection = [...tab.querySelectorAll(".setting-item")].slice(0, 2);
      const buttons = connection.flatMap((item) => [...item.querySelectorAll("button")]).map((button) => button.innerText);
      const fields = connection.flatMap((item) => [...item.querySelectorAll("input, select")]);
      return tab.querySelector(".setting-item-heading")?.innerText.startsWith("Not connected") && fields.length === 1 && buttons.join() === "Sign in";
    }),
  );
  if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, `settings-${name}-fresh.png`) });
  await page.evaluate((server) => {
    const tab = document.querySelector(".vertical-tab-content");
    const field = tab.querySelector(".setting-item input[type=text]");
    field.value = server;
    field.dispatchEvent(new Event("input"));
    [...tab.querySelectorAll("button")].find((button) => button.innerText === "Sign in").click();
  }, server);
  const consent = async (what) => {
    let url;
    await eventually(`${name}: ${what} opens the server's consent page`, async () => {
      url = await page.evaluate(() => window.__opened.at(-1));
      return !!url?.startsWith(`${server}/oauth/authorize?`);
    });
    const callback = await approve(url);
    await page.evaluate((callback) => app.plugins.plugins.babelsync.finishSignIn(callback), callback);
    const signedIn = await page.evaluate(() => !!app.plugins.plugins.babelsync.settings.tokens?.accessToken?.startsWith("bsa_"));
    check(`${name}: oauth code is exchanged for tokens inside Obsidian`, signedIn);
  };
  const needsSignIn = (await fetch(`${server}/api/vaults`)).status === 401;
  if (needsSignIn) await consent("the sign-in button");

  await eventually(`${name}: signing in goes straight on to the vault, asking first and saying what will happen`, () =>
    page.evaluate(() => [...document.querySelectorAll(".modal-container .modal")].some((modal) => modal.innerText.includes("Sync this Obsidian vault"))),
  );
  await page.evaluate(() => [...document.querySelectorAll(".modal-container .modal button")].find((button) => button.innerText === "Connect").click());
  await eventually(`${name}: settings tab says what it is syncing with`, () =>
    page.evaluate(() => document.querySelector(".vertical-tab-content .setting-item-heading")?.innerText.startsWith("Syncing with ")),
  );
  if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, `settings-${name}.png`) });
  await page.evaluate(() => app.setting.close());
  if (!needsSignIn) {
    await page.evaluate(() => app.plugins.plugins.babelsync.signIn());
    await consent("signing in on a server that does not demand it");
  }
  await eventually(`${name}: status bar reports synced`, () => page.evaluate(() => document.querySelector(".status-bar")?.innerText.includes("Babel Sync: synced")));
}

async function followLink(device, vaultId) {
  const { page, name } = device;
  await page.evaluate(() => {
    app.setting.open();
    app.setting.openTabById("babelsync");
  });
  await eventually(`${name}: a fresh settings tab says it is not connected`, () =>
    page.evaluate(() => document.querySelector(".vertical-tab-content .setting-item-heading")?.innerText.startsWith("Not connected")),
  );
  await page.evaluate(() => app.setting.close());

  const handled = await page.evaluate(
    (server, id) => {
      if (typeof window.OBS_ACT !== "function") return false;
      window.OBS_ACT({ action: "babelsync-connect", server, id, name: "Linked" });
      return true;
    },
    server,
    vaultId,
  );
  check(`${name}: Obsidian hands the connect link to the plugin`, handled);
  await eventually(`${name}: the connect link asks before changing anything`, () =>
    page.evaluate(
      (host) => {
        const modal = document.querySelector(".modal-container .modal");
        const unset = !app.plugins.plugins.babelsync.settings.serverUrl;
        return unset && !!modal?.innerText.includes(`“Linked” on ${host}`);
      },
      new URL(server).host,
    ),
  );
  if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, `connect-${name}.png`) });
  await page.evaluate(() => [...document.querySelectorAll(".modal-container .modal button")].find((button) => button.innerText === "Connect").click());

  const needsSignIn = (await fetch(`${server}/api/vaults`)).status === 401;
  if (needsSignIn) {
    let url;
    await eventually(`${name}: connecting opens the consent page`, async () => {
      url = await page.evaluate(() => window.__opened.at(-1));
      return !!url?.startsWith(`${server}/oauth/authorize?`);
    });
    const callback = await approve(url);
    await page.evaluate((callback) => app.plugins.plugins.babelsync.finishSignIn(callback), callback);
  }

  await eventually(`${name}: the connect link alone sets the server and the vault`, () =>
    page.evaluate((server, id) => {
      const { serverUrl, vaultId } = app.plugins.plugins.babelsync.settings;
      return serverUrl === server && vaultId === id;
    }, server, vaultId),
  );
  await page.evaluate(
    async (name) => {
      const plugin = app.plugins.plugins.babelsync;
      plugin.settings.deviceName = name;
      await plugin.saveSettings();
    },
    name,
  );
  await eventually(`${name}: status bar reports synced`, () => page.evaluate(() => document.querySelector(".status-bar")?.innerText.includes("Babel Sync: synced")));

  await page.evaluate((server) => window.OBS_ACT({ action: "babelsync-connect", server, id: "00000000-0000-4000-8000-000000000000", name: "Other" }), server);
  await eventually(`${name}: pointing a synced vault at another one is warned against`, () =>
    page.evaluate(() => {
      const modal = document.querySelector(".modal-container .modal");
      return !!modal?.innerText.includes("Mix two vaults?") && !!modal.querySelector("button.mod-cta")?.innerText.includes("Cancel");
    }),
  );
  await page.evaluate(() => document.querySelector(".modal-container .modal button.mod-cta").click());
  check(`${name}: cancelling leaves the vault where it was`, await page.evaluate((id) => app.plugins.plugins.babelsync.settings.vaultId === id, vaultId));

  await page.evaluate(() => {
    app.setting.open();
    app.setting.openTabById("babelsync");
  });
  await eventually(`${name}: a synced vault shows one line, leaving has its own row, and nothing asks for a name or colour`, () =>
    page.evaluate(() => {
      const tab = document.querySelector(".vertical-tab-content");
      const heading = tab.querySelector(".setting-item-heading");
      const rows = [...tab.querySelectorAll(".setting-item")].map((row) => row.querySelector(".setting-item-name")?.innerText ?? "");
      const leave = [...tab.querySelectorAll(".setting-item")].find((row) => row.querySelector(".setting-item-name")?.innerText === "Disconnect vault");
      return (
        !tab.querySelector("select") &&
        !tab.querySelector("input[type=color]") &&
        heading.innerText.startsWith("Syncing with ") &&
        heading.querySelectorAll("button").length === 0 &&
        leave?.querySelector("button")?.innerText === "Disconnect" &&
        rows.indexOf("Device name") < rows.indexOf("Disconnect vault") &&
        !rows.includes("Version") &&
        rows.includes("Device name") &&
        rows.includes("Verify files") &&
        !rows.includes("Your name") &&
        !rows.includes("Compare everything again")
      );
    }),
  );
  if (process.env.SHOTS) await page.screenshot({ path: join(process.env.SHOTS, `settings-${name}-bound.png`) });
  await page.evaluate(() => app.setting.close());
}

const read = (device, path) => device.page.evaluate(async (path) => ((await app.vault.adapter.exists(path)) ? app.vault.adapter.read(path) : null), path);
const exists = (device, path) => device.page.evaluate((path) => app.vault.adapter.exists(path), path);
const editorText = (device) => device.page.evaluate(() => app.workspace.activeEditor?.editor?.getValue() ?? null);
const openNote = (device, path) => device.page.evaluate((path) => app.workspace.openLinkText(path, "", false), path);

const SHOWN = "Trips/Lisbon in May.md";
const SHOWN_TEXT = [
  "Five days, two of us, no car. Staying in Alfama near the Sé.",
  "",
  "## Booked",
  "",
  "- [x] Flights, arriving Friday 14:10",
  "- [x] Apartment on Rua de São João da Praça",
  "- [ ] Train to Sintra on Sunday, leave before 9",
  "- [ ] Dinner at Prado, ask for the counter",
  "",
  "## Ideas",
  "",
  "Walk the hill up to Graça for the view at sunset, then down through Mouraria.",
  "Tram 28 only early in the morning. The Gulbenkian on the rainy day.",
  "",
  "See [[Packing list]] and [[Portugal budget]].",
  "",
].join("\n");

const dressSettings = (page, deviceName) =>
  page.evaluate((deviceName) => {
    const heading = [...document.querySelectorAll(".setting-item-name")].find((name) => name.textContent.startsWith("Syncing with"));
    heading.textContent = heading.textContent.replace(/ on .*$/, " on babelsync.com");
    heading.closest(".setting-item").parentElement.parentElement.querySelector("input[type=text]").value = deviceName;
  }, deviceName);

async function showCursor(writer, reader, person, from, to) {
  await writer.page.bringToFront();
  await writer.page.evaluate(
    (path, person, from, to) => {
      const plugin = app.plugins.plugins.babelsync;
      plugin.presence = () => person;
      for (const binding of plugin.collab.bindings.values()) {
        binding.doc?.awareness.setLocalStateField("user", { ...person, colorLight: person.color + "40" });
      }
      return app.workspace.openLinkText(path, "", false).then(() => {
        const editor = app.workspace.activeEditor.editor;
        editor.focus();
        editor.setSelection(from, to);
      });
    },
    SHOWN,
    person,
    from,
    to,
  );
  await writer.page.keyboard.press("Shift");
  await eventually("the picture shows the other person's cursor", () => reader.evaluate(() => !!document.querySelector(".cm-ySelectionCaret")));
  await reader.addStyleTag({ content: ".cm-ySelectionInfo { opacity: 1 !important; transition: none !important; }" });
}

async function deskPicture(laptop, desk) {
  await laptop.page.evaluate((path, text) => app.vault.adapter.mkdir("Trips").then(() => app.vault.create(path, text)), SHOWN, SHOWN_TEXT);
  for (const name of ["Packing list.md", "Portugal budget.md", "Reading/The Book of Disquiet.md", "Recipes/Pastéis de nata.md"]) {
    await laptop.page.evaluate(async (name) => {
      const folder = name.includes("/") ? name.slice(0, name.lastIndexOf("/")) : "";
      if (folder && !(await app.vault.adapter.exists(folder))) await app.vault.createFolder(folder);
      await app.vault.create(name, "");
    }, name);
  }
  await eventually("the note to picture reaches the desk", async () => (await read(desk, SHOWN)) === SHOWN_TEXT);
  await desk.page.bringToFront();
  await openNote(desk, SHOWN);
  await desk.page.evaluate(() => document.querySelectorAll(".notice").forEach((notice) => notice.remove()));
  await desk.page.evaluate(() => app.workspace.leftSplit.setSize?.(230));
  await showCursor(laptop, desk.page, { name: "Maya", color: "#db2777" }, { line: 6, ch: 6 }, { line: 6, ch: 21 });
  await desk.page.bringToFront();
  await new Promise((resolve) => setTimeout(resolve, 400));
  await desk.page.screenshot({ path: join(process.env.SHOTS, "editor-desktop.png") });

  await eventually("the desk is in sync for its picture", () => desk.page.evaluate(() => app.plugins.plugins.babelsync.status === "synced"));
  await desk.page.evaluate(() => {
    app.setting.open();
    app.setting.openTabById("babelsync");
  });
  await eventually("the settings picture shows a vault in sync", () => desk.page.evaluate(() => document.querySelector(".vertical-tab-content .setting-item-heading")?.innerText.includes("Up to date")));
  await dressSettings(desk.page, "MacBook Pro");
  await desk.page.screenshot({ path: join(process.env.SHOTS, "sync-settings.png") });
  await desk.page.evaluate(() => app.setting.close());
}

async function pocketPicture(laptop, phone) {
  await phone.setViewport({ width: 390, height: 780, deviceScaleFactor: 3 });
  await phone.evaluate((path) => app.workspace.openLinkText(path, "", false), SHOWN);
  await phone.evaluate(() => document.querySelectorAll(".notice").forEach((notice) => notice.remove()));
  await showCursor(laptop, phone, { name: "Sam", color: "#2563eb" }, { line: 7, ch: 6 }, { line: 7, ch: 21 });
  await phone.bringToFront();
  await new Promise((resolve) => setTimeout(resolve, 600));
  await phone.screenshot({ path: join(process.env.SHOTS, "editor-phone.png") });
  await phone.evaluate(() => {
    app.setting.open();
    app.setting.openTabById("babelsync");
  });
  await new Promise((resolve) => setTimeout(resolve, 800));
  await dressSettings(phone, "iPhone");
  await phone.screenshot({ path: join(process.env.SHOTS, "sync-settings-phone.png") });
  await phone.evaluate(() => app.setting.close());
  await phone.setViewport(null);
}

async function run() {
  const listed = await (await fetch(`${server}/api/vaults`)).json();
  const vaultId = process.env.BABELSYNC_VAULT_ID ?? listed.vaults?.[0]?.id;
  if (!vaultId) throw new Error("create an empty vault on the server first, or name one in BABELSYNC_VAULT_ID");

  const laptop = await device("laptop", 9351);
  const desk = await device("desk", 9352);
  check("real Obsidian profile is not the one in use", realUntouched());

  await enablePlugin(laptop);
  await enablePlugin(desk);
  await signIn(laptop, vaultId);
  await followLink(desk, vaultId);

  await laptop.page.evaluate(() => app.vault.create("Hello.md", "hi from the laptop 😀\n"));
  await eventually("a note created in one Obsidian appears in the other", async () => (await read(desk, "Hello.md")) === "hi from the laptop 😀\n");

  await openNote(laptop, "Hello.md");
  await openNote(desk, "Hello.md");
  await eventually("both editors show the note", async () => (await editorText(laptop)) === "hi from the laptop 😀\n" && (await editorText(desk)) === "hi from the laptop 😀\n");

  await laptop.page.bringToFront();
  await laptop.page.evaluate(() => {
    const editor = app.workspace.activeEditor.editor;
    editor.focus();
    editor.setCursor(editor.lastLine());
  });
  await laptop.page.keyboard.type("typed on the laptop");
  await eventually("keystrokes in one editor show up live in the other editor", async () => (await editorText(desk))?.includes("typed on the laptop"));
  await eventually("the other editor shows the remote cursor", () => desk.page.evaluate(() => !!document.querySelector(".cm-ySelectionCaret")));

  await desk.page.bringToFront();
  await openNote(desk, "Hello.md");
  await desk.page.evaluate(() => {
    const collab = app.plugins.plugins.babelsync.collab;
    const editor = app.workspace.activeEditor.editor;
    collab.releaseAll();
    editor.replaceRange("\ntyped before the note was bound", { line: editor.lastLine(), ch: editor.getLine(editor.lastLine()).length });
    collab.refresh();
  });
  await eventually("typing that was not saved yet survives the note being bound", async () => (await editorText(laptop))?.includes("typed before the note was bound"));
  check("and stays in the editor it was typed in", (await editorText(desk))?.includes("typed before the note was bound"));

  await desk.page.bringToFront();
  await desk.page.evaluate(() => {
    const editor = app.workspace.activeEditor.editor;
    editor.focus();
    editor.setCursor({ line: 0, ch: 0 });
  });
  await desk.page.keyboard.type("desk says hello\n");
  let merged = "desk says hello\nhi from the laptop 😀\ntyped on the laptop\ntyped before the note was bound";
  await eventually("simultaneous typing converges to the same text in both editors", async () => (await editorText(laptop)) === merged && (await editorText(desk)) === merged);
  await eventually("the merged text is written to both vaults on disk", () => readFileSync(join(laptop.vault, "Hello.md"), "utf8") === merged && readFileSync(join(desk.vault, "Hello.md"), "utf8") === merged, 30000);

  const note = { vault: vaultId, path: "Hello.md" };
  const agent = await connectAgent(server, await laptop.page.evaluate(() => app.plugins.plugins.babelsync.settings.tokens.accessToken));
  await agent.call("append_file", { ...note, content: "the agent adds a line\n" });
  await eventually("an agent's append shows up in both open Obsidian editors", async () =>
    (await editorText(laptop))?.endsWith("\nthe agent adds a line\n") && (await editorText(desk))?.endsWith("\nthe agent adds a line\n"),
  );
  await agent.call("edit_file", { ...note, edits: [{ old_text: "desk says hello", new_text: "desk says hello to the agent" }] });
  await eventually("an agent's edit shows up in both open Obsidian editors", async () =>
    (await editorText(laptop))?.startsWith("desk says hello to the agent\n") && (await editorText(desk))?.startsWith("desk says hello to the agent\n"),
  );

  await laptop.page.bringToFront();
  await laptop.page.evaluate(() => {
    const editor = app.workspace.activeEditor.editor;
    editor.focus();
    editor.setCursor({ line: 1, ch: 0 });
  });
  const appending = (async () => {
    for (let line = 1; line <= 12; line++) await agent.call("append_file", { ...note, content: `agent line ${line}\n` });
  })();
  await laptop.page.keyboard.type("typed in Obsidian while the agent wrote ", { delay: 8 });
  await appending;
  const afterAgent = (await agent.read(note.path, { vault: vaultId })).text;
  check(
    "typing in Obsidian while an agent appends loses neither",
    afterAgent.includes("typed in Obsidian while the agent wrote hi from the laptop 😀") && Array.from({ length: 12 }, (_, n) => `agent line ${n + 1}\n`).every((line) => afterAgent.includes(line)),
    JSON.stringify(afterAgent),
  );
  await eventually("both Obsidian editors match what the agent reads", async () => {
    const now = (await agent.read(note.path, { vault: vaultId })).text;
    return (await editorText(laptop)) === now && (await editorText(desk)) === now;
  });

  const browser = await puppeteer.launch({ executablePath: chrome, headless: true }).catch(() => null);
  if (browser) {
    const web = await browser.newPage();
    await web.setViewport({ width: 1280, height: 4000 });
    await web.goto(`${server}/v/${vaultId}/f/Hello.md`, { waitUntil: "networkidle0" });
    if (new URL(web.url()).pathname === "/login") {
      check("web editor opened (server needs sign-in, skipped)", true);
    } else {
      await web.waitForSelector(".cm-content");
      await eventually("the web editor shows what Obsidian and the agent wrote", () =>
        web.evaluate(() => document.querySelector(".cm-content").innerText.includes("agent line 12") && document.querySelector(".cm-content").innerText.includes("typed in Obsidian while the agent wrote")),
      );
      await web.focus(".cm-content");
      await web.keyboard.type("typed in the browser\n");
      await eventually("typing in the web editor shows up live in both Obsidian editors", async () =>
        (await editorText(laptop))?.startsWith("typed in the browser\n") && (await editorText(desk))?.startsWith("typed in the browser\n"),
      );
      await eventually("the web editor shows Obsidian's cursor", () => web.evaluate(() => !!document.querySelector(".cm-ySelectionCaret")));
      await laptop.page.bringToFront();
      await laptop.page.evaluate(() => {
        const editor = app.workspace.activeEditor.editor;
        editor.focus();
        editor.setCursor({ line: 0, ch: 0 });
      });
      await laptop.page.keyboard.type("Obsidian answers the browser\n");
      await eventually("typing in Obsidian shows up live in the web editor", () => web.evaluate(() => document.querySelector(".cm-content").innerText.startsWith("Obsidian answers the browser")));
    }
    await browser.close();
  } else {
    check("web editor opened (no Chrome found, skipped)", true);
  }

  merged = (await agent.read(note.path, { vault: vaultId })).text;
  await agent.close();
  await eventually("everything written by all three is on disk in both vaults", () => readFileSync(join(laptop.vault, "Hello.md"), "utf8") === merged && readFileSync(join(desk.vault, "Hello.md"), "utf8") === merged, 30000);

  const picture = [...Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64")];
  await laptop.page.evaluate((bytes) => app.vault.createBinary("Attachments/pixel.png", new Uint8Array(bytes).buffer), picture).catch(async () => {
    await laptop.page.evaluate(async (bytes) => {
      await app.vault.createFolder("Attachments").catch(() => {});
      await app.vault.createBinary("Attachments/pixel.png", new Uint8Array(bytes).buffer);
    }, picture);
  });
  await eventually("an attachment added in one Obsidian is downloaded by the other", () => existsSync(join(desk.vault, "Attachments/pixel.png")) && readFileSync(join(desk.vault, "Attachments/pixel.png")).equals(Buffer.from(picture)));

  await laptop.page.evaluate(() => app.fileManager.renameFile(app.vault.getAbstractFileByPath("Hello.md"), "Moved/Greeting.md")).catch(async () => {
    await laptop.page.evaluate(async () => {
      await app.vault.createFolder("Moved").catch(() => {});
      await app.fileManager.renameFile(app.vault.getAbstractFileByPath("Hello.md"), "Moved/Greeting.md");
    });
  });
  await eventually("a rename in one Obsidian is followed by the other", async () => (await exists(desk, "Moved/Greeting.md")) && !(await exists(desk, "Hello.md")));
  await eventually("the renamed note keeps its text", async () => (await read(desk, "Moved/Greeting.md")) === merged);

  await desk.page.evaluate(() => app.vault.create("Scratch.md", "delete me\n"));
  await eventually("a second note reaches the first Obsidian", async () => (await read(laptop, "Scratch.md")) === "delete me\n");
  await desk.page.evaluate(() => app.vault.delete(app.vault.getAbstractFileByPath("Scratch.md")));
  await eventually("a deletion in one Obsidian is followed by the other", async () => !(await exists(laptop, "Scratch.md")));

  await desk.page.evaluate(async () => {
    await app.vault.createFolder("Box/Inner");
    await app.vault.create("Box/a.md", "a\n");
    await app.vault.create("Box/Inner/b.md", "b\n");
  });
  await eventually("notes in nested folders reach the other Obsidian", async () => (await exists(laptop, "Box/a.md")) && (await exists(laptop, "Box/Inner/b.md")));
  await desk.page.evaluate(() => app.fileManager.renameFile(app.vault.getAbstractFileByPath("Box"), "Crate"));
  await eventually(
    "a folder renamed in one Obsidian is renamed in the other, leaving no empty folder",
    async () => (await exists(laptop, "Crate/a.md")) && (await exists(laptop, "Crate/Inner/b.md")) && !(await exists(laptop, "Box")),
    12000,
  );
  await desk.page.evaluate(() => app.fileManager.trashFile(app.vault.getAbstractFileByPath("Crate")));
  await eventually("a folder deleted in one Obsidian is gone from the other, folder and all", async () => !(await exists(laptop, "Crate")), 12000);
  const leftovers = await (await fetch(`${server}/api/vaults/${vaultId}/entries`)).json().catch(() => null);
  if (leftovers?.entries) check("the server keeps nothing of the deleted folder", !leftovers.entries.some((entry) => !entry.deleted && entry.path.startsWith("Crate/")));

  await desk.page.evaluate(() => app.vault.create("Food.base", "views:\n  - type: table\n    name: Table\n"));
  await eventually("a base file reaches the other Obsidian", async () => (await read(laptop, "Food.base")) === "views:\n  - type: table\n    name: Table\n");
  await laptop.page.evaluate(() => app.vault.modify(app.vault.getAbstractFileByPath("Food.base"), "views:\n  - type: table\n    name: Renamed\n"));
  await eventually("an edit to a base file is merged into the other Obsidian", async () => (await read(desk, "Food.base")) === "views:\n  - type: table\n    name: Renamed\n");

  await desk.page.evaluate(() => app.vault.createFolder("Made on purpose"));
  await eventually("an empty folder made in one Obsidian appears in the other", () => exists(laptop, "Made on purpose"));
  await laptop.page.evaluate(async () => {
    await app.plugins.disablePlugin("babelsync");
    await app.vault.adapter.mkdir("Leftover");
    await new Promise((resolve) => setTimeout(resolve, 1500));
    await app.plugins.enablePlugin("babelsync");
  });
  await eventually("an empty folder left from before the plugin started is cleared away, and the made one stays", async () => !(await exists(laptop, "Leftover")) && (await exists(laptop, "Made on purpose")), 15000);
  await desk.page.evaluate(() => app.fileManager.trashFile(app.vault.getAbstractFileByPath("Made on purpose")));
  await eventually("deleting the empty folder in one Obsidian removes it from the other", async () => !(await exists(laptop, "Made on purpose")), 12000);
  const build = await laptop.page.evaluate(() => app.plugins.plugins.babelsync.build);
  check("the plugin knows which build it is running", /^[0-9a-f]{8}$/.test(build), build);
  await laptop.page.evaluate(async () => {
    await app.vault.createBinary("Pasted image 1.jpg", new Uint8Array([9, 8, 7, 6]).buffer);
  });
  await eventually("a pasted image reaches the other Obsidian", () => exists(desk, "Pasted image 1.jpg"), 12000);
  await laptop.page.evaluate(async () => {
    await app.vault.createFolder("Pasted");
    await app.fileManager.renameFile(app.vault.getAbstractFileByPath("Pasted image 1.jpg"), "Pasted/Pasted image 1.jpg");
  });
  await eventually("moving it into a new attachments folder moves it on the other", async () => (await exists(desk, "Pasted/Pasted image 1.jpg")) && !(await exists(desk, "Pasted image 1.jpg")), 12000);
  await new Promise((resolve) => setTimeout(resolve, 2500));
  const copies = await laptop.page.evaluate(() => app.vault.getFiles().map((file) => file.path).filter((path) => path.includes("Pasted image")));
  check("and the move makes no conflict copies", copies.length === 1 && copies[0] === "Pasted/Pasted image 1.jpg", copies.join(" | "));

  await laptop.page.evaluate(async () => {
    window.oldBabelSync = app.plugins.plugins.babelsync;
    await app.commands.executeCommandById("babelsync:reload");
  });
  await eventually("after the reload command the new copy of the plugin syncs", () => laptop.page.evaluate(() => app.plugins.plugins.babelsync !== window.oldBabelSync && app.plugins.plugins.babelsync?.engine?.status === "synced"), 20000);
  const copiesRunning = await laptop.page.evaluate(async () => {
    const held = (await navigator.locks.query()).held.filter((lock) => lock.name.startsWith("babelsync:"));
    return { held: held.length, oldStopped: window.oldBabelSync.engine === null, log: app.plugins.plugins.babelsync.debugLog() };
  });
  check("only one copy of the plugin holds the vault, and the old one has stopped", copiesRunning.held === 1 && copiesRunning.oldStopped, JSON.stringify({ held: copiesRunning.held, oldStopped: copiesRunning.oldStopped }));
  check("the debug log survives the reload and tells the copies apart", /plugin unloaded/.test(copiesRunning.log) && new Set(copiesRunning.log.match(/ \[[0-9a-f]{4}\] /g)).size >= 2, copiesRunning.log.split("\n").slice(-6).join(" | "));

  await eventually("the laptop settles once nothing is left to send", () => laptop.page.evaluate(() => app.plugins.plugins.babelsync.engine.status === "synced"), 15000);
  const stamp = await laptop.page.evaluate(() => {
    const plugin = app.plugins.plugins.babelsync;
    return { revision: plugin.revision, log: plugin.debugLog() };
  });
  check("the plugin knows which commit it was built from", /^[0-9a-f]{7,}/.test(stamp.revision), stamp.revision);
  check(
    "the debug log names the build and what the plugin did, and holds no token",
    stamp.log.includes(`commit ${stamp.revision}, build ${build}`) && stamp.log.includes("status: synced") && !/accessToken|refreshToken|Bearer/.test(stamp.log),
    stamp.log.split("\n").slice(-30).join(" | "),
  );

  await laptop.page.evaluate(() => app.vault.setConfig("readableLineLength", false));
  await laptop.page.evaluate(() => app.plugins.plugins.babelsync.engine.rescan());
  await eventually(
    "an Obsidian setting changed on one device reaches the other's .obsidian folder",
    () => existsSync(join(desk.vault, ".obsidian/app.json")) && JSON.parse(readFileSync(join(desk.vault, ".obsidian/app.json"), "utf8")).readableLineLength === false,
    45000,
  );
  check("device-only files are not synced", !existsSync(join(desk.vault, ".obsidian/plugins/babelsync/data.json")) || JSON.parse(readFileSync(join(desk.vault, ".obsidian/plugins/babelsync/data.json"), "utf8")).deviceName === "desk");

  await openNote(desk, "Hello.md");
  await desk.page.evaluate(() => app.plugins.disablePlugin("babelsync"));
  writeFileSync(join(desk.vault, "Offline.md"), "written while the plugin was off\n");
  await laptop.page.evaluate(() => app.vault.create("Meanwhile.md", "made on the laptop\n"));
  await new Promise((resolve) => setTimeout(resolve, 1500));
  await desk.page.evaluate(() => app.plugins.enablePlugin("babelsync"));
  await eventually("after the plugin restarts, offline changes go up", async () => (await read(laptop, "Offline.md")) === "written while the plugin was off\n", 30000);
  await eventually("and missed changes come down", async () => (await read(desk, "Meanwhile.md")) === "made on the laptop\n", 30000);
  await eventually("a note left open across the restart is live again", () =>
    desk.page.evaluate(() => [...app.plugins.plugins.babelsync.collab.bindings.values()].some((binding) => binding.path === "Hello.md" && binding.doc)),
  );
  await openNote(laptop, "Hello.md");
  await laptop.page.bringToFront();
  await laptop.page.evaluate(() => {
    const editor = app.workspace.activeEditor.editor;
    editor.focus();
    editor.setCursor({ line: 0, ch: 0 });
  });
  await eventually("the laptop's cursor is resting in the note", () => laptop.page.evaluate(() => app.workspace.activeEditor.editor.hasFocus()));
  await desk.page.evaluate(() => app.plugins.disablePlugin("babelsync"));
  await desk.page.evaluate(() => app.plugins.enablePlugin("babelsync"));
  await eventually("a device that joins sees a cursor already resting there, without waiting for it to move", () => desk.page.evaluate(() => !!document.querySelector(".cm-ySelectionCaret")), 6000);

  await laptop.page.evaluate(() => app.vault.create("Verified.md", "as first synced\n"));
  await eventually("a note to verify reaches the desk", async () => (await read(desk, "Verified.md")) === "as first synced\n");
  await eventually("the desk settles before it is verified", () => desk.page.evaluate(() => app.plugins.plugins.babelsync.engine.status === "synced"));
  await desk.page.evaluate(async () => {
    const plugin = app.plugins.plugins.babelsync;
    const entry = [...plugin.engine.byId.values()].find((known) => known.path === "Verified.md");
    await app.vault.adapter.write("Verified.md", "hidden new text\n");
    const stat = await app.vault.adapter.stat("Verified.md");
    entry.mtime = stat.mtime;
    entry.size = stat.size;
    await plugin.verify();
  });
  await eventually("verify finds a change that the file's size and time hid", async () => (await read(laptop, "Verified.md")) === "hidden new text\n", 15000);

  if (process.env.SHOTS) await deskPicture(laptop, desk);

  await desk.page.evaluate(() => app.emulateMobile(true)).catch(() => {});
  const phone = await findApp(desk.browser).catch(() => null);
  if (phone) {
    desk.page = phone;
    const mobile = await phone.evaluate(() => document.body.classList.contains("is-mobile"));
    check("Obsidian's mobile emulation is on", mobile);
    await eventually("the plugin loads and syncs under mobile emulation", () => phone.evaluate(() => app.plugins.plugins.babelsync?.engine?.status === "synced"), 30000);
    await laptop.page.evaluate(() => app.vault.create("ForPhone.md", "to the phone\n"));
    await eventually("a note reaches the emulated phone", async () => (await read(desk, "ForPhone.md")) === "to the phone\n");
    if (process.env.SHOTS) await pocketPicture(laptop, phone);
    await phone.evaluate(() => app.emulateMobile(false)).catch(() => {});
  } else {
    check("Obsidian's mobile emulation is on", false, "app did not come back");
  }

  const stalePlugin = join(laptop.vault, ".obsidian/plugins/babelsync/main.js");
  check("the plugin's own files are not synced through the vault", (await laptop.page.evaluate(() => app.plugins.plugins.babelsync.ignored(".obsidian/plugins/babelsync/main.js"))) === true);
  writeFileSync(stalePlugin, "module.exports = {}");
  const fetched = await laptop.page.evaluate(async () => {
    const plugin = app.plugins.plugins.babelsync;
    plugin.build = "00000000";
    plugin.updated = false;
    await plugin.fetchUpdate();
    return { updated: plugin.updated, log: plugin.debugLog() };
  });
  check("a plugin on another build fetches the server's build", readFileSync(stalePlugin, "utf8") === readFileSync(join(repo, "plugin/main.js"), "utf8"), fetched.log.split("\n").filter((line) => /fetch/.test(line)).join(" | "));
  check("and offers to reload into it", fetched.updated === true);

  for (const each of [laptop, desk]) {
    const errors = await each.page.evaluate(() => [...document.querySelectorAll(".notice")].map((notice) => notice.innerText)).catch(() => []);
    check(`${each.name}: no error notices on screen`, !errors.some((text) => /error|refused|failed/i.test(text)), errors.join(" | "));
  }
  check("real Obsidian profile was never written", realUntouched());
}

try {
  await run();
} catch (error) {
  check("run completed", false, String(error?.stack ?? error));
} finally {
  for (const child of children) child.kill("SIGTERM");
  const failed = results.filter((result) => !result.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
}
