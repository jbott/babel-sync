declare const BABELSYNC_CONNECTOR_WINDOW: string;

export function connectorWindowPath(pluginDirectory: string, source = BABELSYNC_CONNECTOR_WINDOW): string {
  const { createHash, randomUUID } = require("crypto") as typeof import("crypto");
  const { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } = require("fs") as typeof import("fs");
  const { isAbsolute, join } = require("path") as typeof import("path");
  if (!isAbsolute(pluginDirectory)) throw new Error("The connector plugin directory must be absolute.");
  const directory = join(pluginDirectory, ".native");
  const hash = createHash("sha256").update(source).digest("hex");
  const path = join(directory, `connector-window-${hash}.cjs`);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  try {
    if (readFileSync(path, "utf8") === source) return path;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, source, { flag: "wx", mode: 0o600 });
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
  return path;
}
