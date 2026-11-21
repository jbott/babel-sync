import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import esbuild from "esbuild";

const production = process.argv[2] === "production";

function checkedOutRevision() {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    return "unknown";
  }
}

const revision = process.env.BABELSYNC_REVISION || checkedOutRevision();

const context = await esbuild.context({
  entryPoints: ["src/main.ts"],
  bundle: true,
  format: "cjs",
  target: "es2022",
  platform: "browser",
  outfile: "main.js",
  sourcemap: production ? false : "inline",
  minify: production,
  logLevel: "info",
  define: { BABELSYNC_REVISION: JSON.stringify(revision) },
  plugins: [
    {
      name: "connector-window",
      setup(build) {
        build.onLoad({ filter: /[/\\]connector-window-loader\.ts$/ }, async ({ path }) => {
          const helper = await esbuild.build({
            entryPoints: ["src/connector-window.cjs"],
            bundle: true,
            format: "cjs",
            target: "es2022",
            platform: "node",
            external: ["electron"],
            minify: production,
            write: false,
            metafile: true,
          });
          const loader = await esbuild.transform(await readFile(path, "utf8"), {
            loader: "ts",
            define: { BABELSYNC_CONNECTOR_WINDOW: JSON.stringify(helper.outputFiles[0].text) },
          });
          return {
            contents: loader.code,
            loader: "js",
            resolveDir: dirname(path),
            watchFiles: [path, ...Object.keys(helper.metafile.inputs).map((input) => resolve(input))],
          };
        });
      },
    },
  ],
  external: [
    "obsidian",
    "electron",
    "@electron/remote",
    "crypto",
    "fs",
    "net",
    "path",
    "@codemirror/autocomplete",
    "@codemirror/collab",
    "@codemirror/commands",
    "@codemirror/language",
    "@codemirror/lint",
    "@codemirror/search",
    "@codemirror/state",
    "@codemirror/view",
    "@lezer/common",
    "@lezer/highlight",
    "@lezer/lr",
  ],
});

if (production) {
  await context.rebuild();
  await context.dispose();
} else {
  await context.watch();
}
