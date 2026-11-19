const key = (vaultId) => `babelsync:open-folders:${vaultId}`;

function load(vaultId) {
  try {
    return new Set(JSON.parse(localStorage.getItem(key(vaultId)) || "[]"));
  } catch {
    return new Set();
  }
}

function save(vaultId, open) {
  try {
    localStorage.setItem(key(vaultId), JSON.stringify([...open]));
  } catch {}
}

export const Folders = {
  mounted() {
    this.vaultId = this.el.dataset.vaultId;
    this.open = load(this.vaultId);

    this.expected = new Map();
    this.onToggle = (event) => {
      const folder = event.target;
      if (!(folder instanceof HTMLDetailsElement) || !folder.dataset.path) return;
      const path = folder.dataset.path;
      if (this.expected.get(path) === folder.open) return void this.expected.delete(path);
      if (folder.open) this.open.add(path);
      else this.open.delete(path);
      save(this.vaultId, this.open);
      this.pushEvent("toggle_folder", { path, open: folder.open });
    };
    this.el.addEventListener("toggle", this.onToggle, true);

    this.onAll = (event) => {
      this.pushEvent("all_folders", { open: event.detail.open }, ({ open }) => {
        this.open = new Set(open);
        save(this.vaultId, this.open);
        for (const folder of this.folders()) this.set(folder, this.open.has(folder.dataset.path));
      });
    };
    this.el.addEventListener("babelsync:folders", this.onAll);

    this.handleEvent("reveal_folder", ({ path, open }) => {
      for (const above of open) this.open.add(above);
      save(this.vaultId, this.open);
      this.announce();
      this.revealing = path;
      this.apply();
    });

    this.announce();
    this.apply();
  },

  reconnected() {
    this.announce();
  },

  announce() {
    this.pushEvent("open_folders", { paths: [...this.open] });
  },

  set(folder, open) {
    if (folder.open === open) return;
    this.expected.set(folder.dataset.path, open);
    folder.open = open;
  },

  updated() {
    this.apply();
  },

  destroyed() {
    this.el.removeEventListener("toggle", this.onToggle, true);
    this.el.removeEventListener("babelsync:folders", this.onAll);
  },

  reveal() {
    if (!this.revealing) return;
    const folder = this.folders().find((folder) => folder.dataset.path === this.revealing);
    if (!folder) return;
    this.revealing = null;
    (folder.querySelector("summary") ?? folder).scrollIntoView({ block: "center" });
  },

  folders() {
    return [...this.el.querySelectorAll("details[data-path]")];
  },

  apply() {
    const current = this.el.querySelector("[aria-current=page]");
    const href = current?.getAttribute("href");
    const selectionChanged = href !== this.selectedHref;
    this.selectedHref = href;
    let found = false;
    for (const folder of this.folders()) {
      const path = folder.dataset.path;
      const holdsCurrent = selectionChanged && current !== null && folder.contains(current);
      if (holdsCurrent && !this.open.has(path)) {
        this.open.add(path);
        found = true;
      }
      const wanted = this.open.has(path);
      if (folder.open !== wanted && (wanted || !folder.dataset.seen)) this.set(folder, wanted);
      folder.dataset.seen = "true";
    }
    this.reveal();
    if (!found) return;
    save(this.vaultId, this.open);
    this.announce();
  },
};
