import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { connectorWindowPath } from "../src/connector-window-loader.ts";

const originalRequire = globalThis.require;
const require = createRequire(import.meta.url);
globalThis.require = require;
after(() => {
  if (originalRequire) globalThis.require = originalRequire;
  else Reflect.deleteProperty(globalThis, "require");
});

function directory(t: { after: (action: () => void) => void }): string {
  const path = mkdtempSync(join(tmpdir(), "babel-connector-window-"));
  t.after(() => rmSync(path, { recursive: true, force: true }));
  return path;
}

test("reloading an updated connector uses its new module without changing the running version", (t) => {
  const plugin = directory(t);
  const first = connectorWindowPath(plugin, 'module.exports = "first";');
  assert.equal(require(first), "first");
  const second = connectorWindowPath(plugin, 'module.exports = "second";');
  assert.notEqual(second, first);
  assert.equal(require(second), "second");
  assert.equal(require(first), "first");
  assert.equal(connectorWindowPath(plugin, 'module.exports = "second";'), second);
});

test("a damaged helper is replaced with the bundled source before loading", (t) => {
  const plugin = directory(t);
  const source = "module.exports = { ready: true };";
  const path = connectorWindowPath(plugin, source);
  writeFileSync(path, "incomplete");
  assert.equal(connectorWindowPath(plugin, source), path);
  assert.equal(readFileSync(path, "utf8"), source);
  assert.deepEqual(require(path), { ready: true });
  assert.equal(readdirSync(dirname(path)).length, 1);
});

test("a relative plugin path cannot write into an unrelated working directory", () => {
  assert.throws(() => connectorWindowPath("plugin", "module.exports = {};"), /must be absolute/);
});
