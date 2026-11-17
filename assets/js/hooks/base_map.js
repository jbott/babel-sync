let maplibre;

const WORKER_URL = "/assets/js/maplibre-worker.js";
const STYLES = { light: "https://tiles.openfreemap.org/styles/bright", dark: "https://tiles.openfreemap.org/styles/dark" };
const DEFAULT_COLOR = "var(--accent)";
const SOURCE = "places";
const LABEL_FONT = "Noto Sans Regular";
const PIN_RADIUS = 10;
const LABEL_SIZE = 12;
const LABEL_PADDING = 3;
const LABEL_GAP = (PIN_RADIUS + LABEL_PADDING + 2) / LABEL_SIZE;
const LEVEL = { bearing: 0, pitch: 0, roll: 0 };
const REFRAME_MS = 800;
const TURNS = ["rotate", "pitch", "roll"];

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

function button(className, label, onClick) {
  const element = document.createElement("button");
  element.type = "button";
  element.className = className;
  element.title = label;
  element.setAttribute("aria-label", label);
  const icon = document.createElement("span");
  icon.className = "maplibregl-ctrl-icon";
  icon.setAttribute("aria-hidden", "true");
  element.append(icon);
  element.addEventListener("click", onClick);
  return element;
}

function controls(library, reframe) {
  const navigation = new library.NavigationControl({ showCompass: true, visualizePitch: true });
  const add = navigation.onAdd.bind(navigation);
  const remove = navigation.onRemove.bind(navigation);
  let shown;
  let showCompass;

  navigation.onAdd = (map) => {
    const group = add(map);
    const compass = group.querySelector(".maplibregl-ctrl-compass");
    shown = map;
    showCompass = () => (compass.hidden = map.getBearing() === 0 && map.getPitch() === 0 && map.getRoll() === 0);
    for (const turn of TURNS) map.on(turn, showCompass);
    showCompass();
    group.append(button("base-map-reframe", "Back to the starting view", reframe));
    return group;
  };
  navigation.onRemove = () => {
    for (const turn of TURNS) shown?.off(turn, showCompass);
    remove();
  };
  return navigation;
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

const PIN_SCALE = 2;

function pinImage(color) {
  const size = PIN_RADIUS * 2 * PIN_SCALE;
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = size;
  const context = canvas.getContext("2d");
  const centre = size / 2;
  context.beginPath();
  context.arc(centre, centre, 8 * PIN_SCALE, 0, Math.PI * 2);
  context.fillStyle = color;
  context.fill();
  context.lineWidth = 1.5 * PIN_SCALE;
  context.strokeStyle = "rgba(255, 255, 255, 0.9)";
  context.stroke();
  context.beginPath();
  context.arc(centre, centre, 2.5 * PIN_SCALE, 0, Math.PI * 2);
  context.fillStyle = "#ffffff";
  context.fill();
  return context.getImageData(0, 0, size, size);
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
      minZoom: minZoom ?? 0,
      maxZoom: maxZoom ?? 18,
      attributionControl: { compact: true },
      ...this.opening(),
    });
    this.map.addControl(
      controls(library, () => this.frame({ animate: true })),
      "top-right",
    );
    this.popup = new library.Popup({ closeButton: true, closeOnClick: false, offset: 12, maxWidth: "300px" });
    this.popup.on("close", () => (this.pinned = false));
    this.bindPopupHover();

    this.map.on("style.load", () => this.drawLayers());
    this.map.setMissingStyleImageResolver(async (id) => {
      if (id.startsWith("pin:") && !this.map.hasImage(id)) this.map.addImage(id, pinImage(id.slice(4)), { pixelRatio: PIN_SCALE });
    });

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
        properties: { index, title: place.title, pin: `pin:${resolveColor(place.color || DEFAULT_COLOR, this.colors)}` },
      })),
    };
  },

  drawLayers() {
    this.map.addSource(SOURCE, { type: "geojson", data: this.features() });
    this.map.addLayer({
      id: "place-labels",
      type: "symbol",
      source: SOURCE,
      layout: {
        "text-field": ["get", "title"],
        "text-font": [LABEL_FONT],
        "text-size": LABEL_SIZE,
        "text-max-width": 9,
        "text-padding": LABEL_PADDING,
        "text-variable-anchor-offset": [
          "bottom",
          [0, -LABEL_GAP],
          "bottom-left",
          [LABEL_GAP / 2, -LABEL_GAP],
          "bottom-right",
          [-LABEL_GAP / 2, -LABEL_GAP],
          "left",
          [LABEL_GAP, 0],
          "right",
          [-LABEL_GAP, 0],
          "top",
          [0, LABEL_GAP],
        ],
      },
      paint: {
        "text-color": dark() ? "#ececec" : "#1f2328",
        "text-halo-color": dark() ? "rgba(20, 20, 20, 0.9)" : "rgba(255, 255, 255, 0.92)",
        "text-halo-width": 1.5,
      },
    });
    this.map.addLayer({
      id: "place-pins",
      type: "symbol",
      source: SOURCE,
      layout: { "icon-image": ["get", "pin"], "icon-allow-overlap": true, "icon-padding": 0 },
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

  opening() {
    const { markers, center, zoom } = this.places;
    const points = markers.map((place) => [place.longitude, place.latitude]);
    const bounds = points.length > 0 ? points.reduce((box, point) => box.extend(point), new maplibre.LngLatBounds(points[0], points[0])) : null;
    const middle = center ? [center[1], center[0]] : bounds?.getCenter();

    if (typeof zoom === "number") return { center: middle ?? [0, 0], zoom };
    if (bounds) return { bounds, fitBoundsOptions: { padding: 20 } };
    return { center: middle ?? [0, 0], zoom: 4 };
  },

  frame({ animate } = { animate: false }) {
    const { bounds, fitBoundsOptions, ...camera } = this.opening();
    if (bounds) this.map.fitBounds(bounds, { ...fitBoundsOptions, ...LEVEL, animate, duration: REFRAME_MS });
    else if (animate) this.map.flyTo({ ...camera, ...LEVEL, duration: REFRAME_MS });
    else this.map.jumpTo({ ...camera, ...LEVEL });
  },
};
