import { requestUrl } from "obsidian";

const BODILESS = new Set([204, 205, 304]);

export async function nativeFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const headers: Record<string, string> = {};
  new Headers(init.headers).forEach((value, name) => {
    headers[name] = value;
  });

  const result = await requestUrl({
    url,
    method: init.method ?? "GET",
    headers,
    body: body(init.body),
    throw: false,
  });

  return new Response(BODILESS.has(result.status) ? null : result.arrayBuffer, {
    status: result.status,
    headers: result.headers,
  });
}

function body(value: RequestInit["body"]): string | ArrayBuffer | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return value;
  if (value instanceof ArrayBuffer) return value;
  if (ArrayBuffer.isView(value)) {
    return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) as ArrayBuffer;
  }
  throw new Error("unsupported request body");
}
