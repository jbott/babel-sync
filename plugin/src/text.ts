import diff from "fast-diff";
import type * as Y from "yjs";

const DOC_EXTENSIONS = [".md", ".markdown", ".txt", ".base", ".canvas"];

export function kindFor(path: string): "doc" | "blob" {
  const lower = path.toLowerCase();
  return DOC_EXTENSIONS.some((extension) => lower.endsWith(extension)) ? "doc" : "blob";
}

export function normalize(text: string): string {
  return text.replace(/\r\n/g, "\n");
}

export async function textHash(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  let hex = "";
  for (const byte of new Uint8Array(digest)) hex += byte.toString(16).padStart(2, "0");
  return hex;
}

export function applyTextChange(text: Y.Text, next: string, origin: unknown): void {
  const current = text.toString();
  if (current === next) return;

  text.doc!.transact(() => {
    let index = 0;
    for (const [operation, chunk] of diff(current, next)) {
      if (operation === diff.EQUAL) {
        index += chunk.length;
      } else if (operation === diff.DELETE) {
        text.delete(index, chunk.length);
      } else {
        text.insert(index, chunk);
        index += chunk.length;
      }
    }
  }, origin);
}

export function conflictPath(path: string, device: string, now: Date): string {
  const slash = path.lastIndexOf("/");
  const folder = slash === -1 ? "" : path.slice(0, slash + 1);
  const name = slash === -1 ? path : path.slice(slash + 1);
  const dot = name.lastIndexOf(".");
  const stem = (dot <= 0 ? name : name.slice(0, dot)).replace(/( \(conflict [^()]*\)( \d+)?)+$/, "");
  const extension = dot <= 0 ? "" : name.slice(dot);
  const stamp = now.toISOString().slice(0, 19).replace("T", " ").replace(/:/g, "");
  const by = device.replace(/[\\/:*?"<>|()#^[\]]+/g, " ").replace(/\s+/g, " ").trim() || "device";
  return `${folder}${stem} (conflict ${by} ${stamp})${extension}`;
}
