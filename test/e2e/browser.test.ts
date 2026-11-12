import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { connectAgent } from "./mcp_client.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const phase = process.env.BABELSYNC_PHASE!;
const vaultId = process.env.BABELSYNC_VAULT_ID ?? "";
const setupUrl = process.env.BABELSYNC_SETUP_URL ?? "";
const token = process.env.BABELSYNC_TOKEN ?? "";

const onePixelPng = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");

let browser: Browser;
const problems: string[] = [];
const pages: Page[] = [];

async function explained(run: () => Promise<void>): Promise<void> {
  try {
    await run();
  } catch (error) {
    const seen = await Promise.all(pages.map(async (page) => `${page.url()}\n${await textOf(page, "body").catch(String)}`));
    throw new Error(`${error}\nproblems: ${problems.join("; ")}\n\n${seen.join("\n---\n")}`, { cause: error });
  }
}

async function open(path: string): Promise<Page> {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  pages.push(page);
  await page.setViewport({ width: 1280, height: 4000 });
  const session = await page.createCDPSession();
  await session.send("Emulation.setFocusEmulationEnabled", { enabled: true });
  page.on("pageerror", (error) => problems.push(`uncaught: ${error}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  page.on("dialog", (dialog) => dialog.accept());
  await page.goto(baseUrl + path, { waitUntil: "networkidle0" });
  await page.waitForSelector(".phx-connected");
  return page;
}

async function textOf(page: Page, selector: string): Promise<string> {
  return page.$eval(selector, (element) => (element as HTMLElement).innerText);
}

async function waitForText(page: Page, selector: string, expected: string, exact = false): Promise<void> {
  await page.waitForFunction(
    (selector, expected, exact) => {
      const text = (document.querySelector(selector) as HTMLElement | null)?.innerText;
      return exact ? text?.trim() === expected : text?.includes(expected);
    },
    { timeout: 10_000 },
    selector,
    expected,
    exact,
  );
}

function editorText(page: Page): Promise<string> {
  return page.evaluate(() =>
    [...document.querySelectorAll(".cm-line")]
      .map((line) => {
        const copy = line.cloneNode(true) as HTMLElement;
        copy.querySelectorAll(".cm-ySelectionCaret, .cm-widgetBuffer").forEach((widget) => widget.remove());
        return copy.textContent;
      })
      .join("\n"),
  );
}

async function eventually(check: () => Promise<boolean>, describe: () => Promise<string>): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(await describe());
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

async function fill(page: Page, selector: string, value: string): Promise<void> {
  await page.focus(selector);
  await page.$eval(selector, (input) => (input as HTMLInputElement).select());
  await page.keyboard.type(value);
}

before(async () => {
  browser = await puppeteer.launch({
    executablePath: process.env.CHROME_BIN!,
    headless: true,
    args: ["--no-sandbox", "--disable-gpu"],
  });
});

after(async () => {
  await browser.close();
});

test("two tabs write, read, attach, rename, restore and delete together", { skip: phase !== "app" }, () =>
  explained(async () => {
    const one = await open(`/v/${vaultId}`);
    await one.waitForSelector("#empty");

    await one.type("#new-note input[type=text]", "Notes/browser.md");
    await one.keyboard.press("Enter");
    await one.waitForSelector(".cm-content");
    await one.focus(".cm-content");
    await one.keyboard.type("# Hello\n\nfrom tab one 😀\n");

    const two = await open(`/v/${vaultId}/f/Notes/browser.md`);
    await waitForText(two, ".cm-content", "from tab one 😀");

    await two.focus(".cm-content");
    await two.keyboard.type("tab two says hi\n");
    await waitForText(one, ".cm-content", "tab two says hi");
    await one.waitForSelector(".cm-ySelectionCaret");

    const agent = await connectAgent(baseUrl, token);
    const note = { vault: vaultId, path: "Notes/browser.md" };
    assert.equal((await agent.call("edit_file", { ...note, edits: [{ old_text: "from tab one", new_text: "from tab one, says the agent" }] })).failed, false);
    await waitForText(one, ".cm-content", "from tab one, says the agent 😀");
    await waitForText(two, ".cm-content", "from tab one, says the agent 😀");

    const appending = (async () => {
      for (let line = 1; line <= 15; line++) await agent.call("append_file", { ...note, content: `agent line ${line}\n` });
    })();
    await two.keyboard.type("typed while the agent was writing\n", { delay: 5 });
    await appending;
    await two.keyboard.type("still typing\n");

    const afterAgent = (await agent.read(note.path, { vault: vaultId })).text;
    for (let line = 1; line <= 15; line++) assert.ok(afterAgent.includes(`agent line ${line}\n`), `agent line ${line} survived`);
    assert.ok(afterAgent.includes("typed while the agent was writing\nstill typing\n"), afterAgent);
    await waitForText(one, ".cm-content", "agent line 15");
    await waitForText(one, ".cm-content", "typed while the agent was writing");
    const settled = (await agent.read(note.path, { vault: vaultId })).text;
    for (const tab of [one, two]) {
      await eventually(
        async () => (await editorText(tab)) === settled,
        async () => `editor has ${JSON.stringify(await editorText(tab))}, server has ${JSON.stringify(settled)}`,
      );
    }
    await agent.close();

    await one.click('#toolbar button[phx-value-mode="read"]');
    await waitForText(one, "#preview h1", "Hello");
    assert.match(await textOf(one, "#preview"), /tab two says hi/);

    const picture = join(mkdtempSync(join(tmpdir(), "babelsync-")), "pixel.png");
    writeFileSync(picture, onePixelPng);
    const uploader = (await one.$("#uploader"))!;
    await uploader.uploadFile(picture);
    await two.waitForSelector('#tree a[href$="/f/Notes/pixel.png"]');
    await one.click('#tree a[href$="/f/Notes/pixel.png"]');
    await one.waitForFunction(() => {
      const image = document.querySelector("#attachment img") as HTMLImageElement | null;
      return image?.complete && image.naturalWidth === 1;
    });

    await one.click('#tree a[href$="/f/Notes/browser.md"]');
    await waitForText(one, "#entry-path", "Notes/browser.md");
    await one.click("#rename-button");
    await one.waitForSelector("#rename-form input[type=text]");
    await fill(one, "#rename-form input[type=text]", "Notes/renamed.md");
    await one.keyboard.press("Enter");
    await waitForText(one, "#entry-path", "Notes/renamed.md", true);
    await waitForText(two, "#entry-path", "Notes/renamed.md", true);

    await two.focus(".cm-content");
    await two.keyboard.type("after the move\n");
    await one.click('#toolbar button[phx-value-mode="edit"]');
    await one.waitForSelector(".cm-content");
    await waitForText(one, ".cm-content", "after the move");

    await one.click("#history-button");
    await one.waitForSelector("#history [phx-click=show_version]");
    await one.click("#history [phx-click=show_version]");
    await one.waitForSelector("#version-changes");
    await one.click("#compare-text");
    await one.waitForSelector("#version-content");
    await one.click("#history [phx-click=close_history]");

    await one.click("#delete-button");
    await one.waitForSelector("#empty");
    await two.waitForSelector("#empty");

    await one.click("#vault-trash");
    await one.waitForSelector("#trash [phx-click=restore]");
    await one.click("#trash [phx-click=restore]");
    await one.waitForSelector("#trash-empty");
    await two.waitForSelector('#tree a[href$="/f/Notes/renamed.md"]');

    assert.deepEqual(problems, []);
  }),
);

test("a passkey is registered, used to sign in, and refused when unknown", { skip: phase !== "passkey" }, () =>
  explained(async () => {
    const page = await open("/login");
    const devtools = await page.createCDPSession();
    await devtools.send("WebAuthn.enable");
    const authenticator = async () =>
      (
        await devtools.send("WebAuthn.addVirtualAuthenticator", {
          options: {
            protocol: "ctap2",
            transport: "internal",
            hasResidentKey: true,
            hasUserVerification: true,
            isUserVerified: true,
            automaticPresenceSimulation: true,
          },
        })
      ).authenticatorId;
    const firstDevice = await authenticator();

    await page.waitForSelector("#setup-locked");
    await page.goto(setupUrl, { waitUntil: "networkidle0" });
    await page.waitForSelector(".phx-connected");
    await page.click("#passkey-setup");
    await page.waitForFunction(() => location.pathname === "/account");

    await page.goto(baseUrl + "/account", { waitUntil: "networkidle0" });
    await page.waitForSelector(".phx-connected");
    assert.equal((await page.$$("#passkeys [id^=passkey-]:not(#passkey-name):not(#passkey-add)")).length, 1);
    await devtools.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId: firstDevice });
    const authenticatorId = await authenticator();
    await page.type("#passkey-name", "Second key");
    await page.click("#passkey-add");
    await waitForText(page, "#passkeys", "Second key");

    await page.click("#sign-out");
    await page.waitForFunction(() => location.pathname === "/login");
    await page.waitForSelector(".phx-connected #passkey-sign-in");
    await page.click("#passkey-sign-in");
    await page.waitForFunction(() => location.pathname === "/account");

    await page.goto(baseUrl + "/account", { waitUntil: "networkidle0" });
    await page.waitForSelector(".phx-connected");
    await page.click("#sign-out");
    await page.waitForFunction(() => location.pathname === "/login");
    await devtools.send("WebAuthn.clearCredentials", { authenticatorId });
    await devtools.send("WebAuthn.setAutomaticPresenceSimulation", { authenticatorId, enabled: false });
    await page.waitForSelector(".phx-connected #passkey-sign-in");
    await page.click("#passkey-sign-in");
    await devtools.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
    await page.goto(baseUrl + "/", { waitUntil: "networkidle0" });
    assert.equal(new URL(page.url()).pathname, "/");
    await page.waitForSelector(".phx-connected #passkey-sign-in");
  }),
);
