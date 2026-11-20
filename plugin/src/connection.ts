export type Connection = { name: string; landingUrl: string; allowedHosts: string[]; userAgent?: string; checkSelector?: string };

const chromePlatforms = {
  darwin: "Macintosh; Intel Mac OS X 10_15_7",
  linux: "X11; Linux x86_64",
  win32: "Windows NT 10.0; Win64; x64",
};

export function connectionUserAgent(override?: string, platform = process.platform): string {
  if (override) return override;
  const os = platform === "darwin" || platform === "win32" ? chromePlatforms[platform] : chromePlatforms.linux;
  return `Mozilla/5.0 (${os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36`;
}

function parseUrl(text: string): URL | undefined {
  try {
    return new URL(text);
  } catch {
    return undefined;
  }
}

export function connection(name: string, address: string, hosts: string[], agent: string, selector = ""): Connection {
  const url = parseUrl(address);
  if (!name.trim()) throw new Error("Enter a name for this connection.");
  const loopback = url?.protocol === "http:" && url.hostname === "127.0.0.1";
  if (!url || url.username || url.password || (url.protocol !== "https:" && !loopback)) {
    throw new Error("Enter an HTTPS start URL, or a local test URL at http://127.0.0.1.");
  }
  const additional = hosts.map((host) => host.trim().toLowerCase()).filter((host) => host && host !== url.hostname);
  if (additional.some((host) => !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(host))) {
    throw new Error("Enter exact sign-in host names separated by commas.");
  }
  if (loopback && additional.some((host) => host !== url.hostname)) {
    throw new Error("A loopback connection can use only its own origin.");
  }
  if (agent.length > 512 || /[^ -~]/.test(agent)) throw new Error("Use up to 512 printable ASCII characters for the user agent.");
  if (selector.length > 512 || /\p{Cc}/u.test(selector)) throw new Error("Use up to 512 characters for the signed-in selector.");
  const checkSelector = selector.trim();
  const userAgent = agent.trim();
  return {
    name: name.trim(),
    landingUrl: url.href,
    allowedHosts: [...new Set([url.hostname, ...additional])],
    ...(userAgent ? { userAgent } : {}),
    ...(checkSelector ? { checkSelector } : {}),
  };
}

export function restoreConnection(entry: Connection & { loopbackUserAgent?: string }): Connection {
  return connection(entry.name, entry.landingUrl, entry.allowedHosts, entry.userAgent ?? entry.loopbackUserAgent ?? "", entry.checkSelector ?? "");
}
