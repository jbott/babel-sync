function allowedNavigation(value, connector) {
  try {
    const url = new URL(value);
    const landing = new URL(connector.landingUrl);
    if (url.username || url.password || !connector.allowedHosts.includes(url.hostname)) return false;
    if (landing.protocol === "http:" && landing.hostname === "127.0.0.1") return url.origin === landing.origin;
    return url.protocol === "https:" && (url.origin === landing.origin || !url.port);
  } catch {
    return false;
  }
}

module.exports = { allowedNavigation };
