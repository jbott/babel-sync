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

    this.onToggle = (event) => {
      const folder = event.target;
      if (!(folder instanceof HTMLDetailsElement) || !folder.dataset.path) return;
      if (folder.open) this.open.add(folder.dataset.path);
      else this.open.delete(folder.dataset.path);
      save(this.vaultId, this.open);
    };
    this.el.addEventListener("toggle", this.onToggle, true);

    this.onAll = (event) => {
      const wanted = event.detail.open;
      for (const folder of this.folders()) folder.open = wanted;
      this.open = wanted ? new Set(this.folders().map((folder) => folder.dataset.path)) : new Set();
      save(this.vaultId, this.open);
    };
    this.el.addEventListener("babelsync:folders", this.onAll);

    this.apply();
  },

  updated() {
    this.apply();
  },

  destroyed() {
    this.el.removeEventListener("toggle", this.onToggle, true);
    this.el.removeEventListener("babelsync:folders", this.onAll);
  },

  folders() {
    return [...this.el.querySelectorAll("details[data-path]")];
  },

  apply() {
    const current = this.el.querySelector("[aria-current=page]");
    for (const folder of this.folders()) {
      const wanted = this.open.has(folder.dataset.path) || (current !== null && folder.contains(current));
      if (folder.open !== wanted && (wanted || !folder.dataset.seen)) folder.open = wanted;
      folder.dataset.seen = "true";
    }
  },
};
