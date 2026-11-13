let maplibre;

const WORKER_URL = "/assets/js/maplibre-worker.js";
const STYLES = { light: "https://tiles.openfreemap.org/styles/bright", dark: "https://tiles.openfreemap.org/styles/dark" };
const DEFAULT_COLOR = "var(--accent)";
const SOURCE = "places";

const dark = () =>
  document.documentElement.dataset.theme === "dark" || (!document.documentElement.dataset.theme && matchMedia("(prefers-color-scheme: dark)").matches);

const touch = () => matchMedia("(hover: none)").matches;

async function load() {
  if (!maplibre) {
    maplibre = await import("maplibre-gl");
    maplibre.setWorkerUrl(WORKER_URL);
  }
  return maplibre;
}

function resolveColor(color, cache) {
  if (cache.has(color)) return cache.get(color);
  const probe = document.createElement("span");
  probe.style.color = color;
  probe.hidden = true;
  document.body.append(probe);
  const resolved = getComputedStyle(probe).color || "rgb(100, 116, 139)";
  probe.remove();
  cache.set(color, resolved);
  return resolved;
}

function piece(part) {
  if (part.kind === "text") return document.createTextNode(part.text);
  const link = document.createElement("a");
  link.textContent = part.text;
  link.href = part.href;
  if (part.kind === "web") {
    link.target = "_blank";
    link.rel = "noopener noreferrer";
  } else {
    link.dataset.phxLink = "patch";
    link.dataset.phxLinkState = "push";
  }
  return link;
}

function popupContent(place, columns) {
  const filled = place.fields.map((parts, at) => ({ parts, label: columns[at] })).filter(({ parts }) => parts && parts.length > 0);
  const box = document.createElement("div");
  box.className = "base-map-popup";

  const title = document.createElement("a");
  title.className = "base-map-popup-title";
  if (place.href) {
    title.href = place.href;
    title.dataset.phxLink = "patch";
    title.dataset.phxLinkState = "push";
  }
  const [first, ...rest] = filled;
  if (first) title.append(...first.parts.map((part) => document.createTextNode(part.text)));
  else title.textContent = place.title;
  box.append(title);

  if (rest.length > 0) {
    const list = document.createElement("dl");
    for (const { parts, label } of rest) {
      const term = document.createElement("dt");
      term.textContent = label;
      const value = document.createElement("dd");
      value.append(...parts.map(piece));
      list.append(term, value);
    }
    box.append(list);
  }
  return box;
}

export const BaseMap = {
  async mounted() {
    const library = await load();
    if (!this.el.isConnected) return;
    this.colors = new Map();
    this.places = JSON.parse(this.el.dataset.places);
    const { minZoom, maxZoom } = this.places;

    this.map = new library.Map({
      container: this.el.querySelector("[data-map-canvas]"),
      style: dark() ? STYLES.dark : STYLES.light,
      center: [0, 0],
      zoom: 4,
      minZoom: minZoom ?? 0,
      maxZoom: maxZoom ?? 18,
      attributionControl: { compact: true },
    });
    this.map.addControl(new library.NavigationControl({ showCompass: false }), "top-right");
    this.popup = new library.Popup({ closeButton: true, closeOnClick: false, offset: 12, maxWidth: "300px" });
    this.popup.on("close", () => (this.pinned = false));
    this.bindPopupHover();

    this.map.on("style.load", () => this.drawLayers());
    this.map.once("load", () => this.frame());

    this.theme = new MutationObserver(() => {
      this.colors.clear();
      this.map.setStyle(dark() ? STYLES.dark : STYLES.light);
    });
    this.theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    this.resize = new ResizeObserver(() => this.map.resize());
    this.resize.observe(this.el);
    this.shownView = this.el.dataset.view;
  },

  updated() {
    if (!this.map) return;
    this.places = JSON.parse(this.el.dataset.places);
    this.colors.clear();
    this.map.getSource(SOURCE)?.setData(this.features());
    if (this.el.dataset.view !== this.shownView) {
      this.shownView = this.el.dataset.view;
      this.popup.remove();
      this.frame();
    }
  },

  destroyed() {
    this.theme?.disconnect();
    this.resize?.disconnect();
    clearTimeout(this.hideTimer);
    this.map?.remove();
  },

  features() {
    return {
      type: "FeatureCollection",
      features: this.places.markers.map((place, index) => ({
        type: "Feature",
        id: index,
        geometry: { type: "Point", coordinates: [place.longitude, place.latitude] },
        properties: { index, color: resolveColor(place.color || DEFAULT_COLOR, this.colors) },
      })),
    };
  },

  drawLayers() {
    this.map.addSource(SOURCE, { type: "geojson", data: this.features() });
    this.map.addLayer({
      id: "place-pins",
      type: "circle",
      source: SOURCE,
      paint: { "circle-radius": 8, "circle-color": ["get", "color"], "circle-stroke-width": 1.5, "circle-stroke-color": "rgba(255, 255, 255, 0.9)" },
    });
    this.map.addLayer({
      id: "place-dots",
      type: "circle",
      source: SOURCE,
      paint: { "circle-radius": 2.5, "circle-color": "#ffffff" },
    });
    if (this.layersBound) return;
    this.layersBound = true;

    this.map.on("mouseenter", "place-pins", (event) => {
      this.map.getCanvas().style.cursor = "pointer";
      if (!touch() && !this.pinned) this.show(event.features[0]);
    });
    this.map.on("mouseleave", "place-pins", () => {
      this.map.getCanvas().style.cursor = "";
      if (!touch() && !this.pinned) this.hideSoon();
    });
    this.map.on("click", (event) => {
      const feature = this.pinAt(event.point);
      if (feature) {
        this.show(feature);
        this.pinned = true;
      } else {
        this.popup.remove();
      }
    });
  },

  pinAt({ x, y }) {
    const reach = touch() ? 14 : 4;
    const [first] = this.map.queryRenderedFeatures(
      [
        [x - reach, y - reach],
        [x + reach, y + reach],
      ],
      { layers: ["place-pins"] },
    );
    return first;
  },

  show(feature) {
    const place = this.places.markers[feature.properties.index];
    if (!place) return;
    clearTimeout(this.hideTimer);
    this.popup.setLngLat(feature.geometry.coordinates).setDOMContent(popupContent(place, this.places.columns)).addTo(this.map);
  },

  hideSoon() {
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => this.popup.remove(), 150);
  },

  bindPopupHover() {
    this.popup.on("open", () => {
      const element = this.popup.getElement();
      element?.addEventListener("mouseenter", () => clearTimeout(this.hideTimer));
      element?.addEventListener("mouseleave", () => !touch() && !this.pinned && this.hideSoon());
    });
  },

  frame() {
    const { markers, center, zoom } = this.places;
    const points = markers.map((place) => [place.longitude, place.latitude]);
    const bounds = points.length > 0 ? points.reduce((box, point) => box.extend(point), new maplibre.LngLatBounds(points[0], points[0])) : null;

    if (center) this.map.setCenter([center[1], center[0]]);
    else if (bounds) this.map.setCenter(bounds.getCenter());

    if (typeof zoom === "number") this.map.setZoom(zoom);
    else if (bounds) this.map.fitBounds(bounds, { padding: 20, animate: false });
  },
};
