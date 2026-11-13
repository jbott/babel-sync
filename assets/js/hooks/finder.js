const ITEM = "[data-finder-item]";

export const Finder = {
  mounted() {
    this.onKey = (event) => {
      const open = this.dialog() !== null;
      if ((event.metaKey || event.ctrlKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === "k") {
        event.preventDefault();
        if (open) return this.close();
        this.opener = document.activeElement;
        return this.pushEvent("open_finder", {});
      }
      if (!open) return;

      if (event.key === "Escape") {
        event.preventDefault();
        this.close();
      } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.move(event.key === "ArrowDown" ? 1 : -1);
      } else if (event.key === "Enter" && !event.isComposing) {
        event.preventDefault();
        this.items()[this.active]?.click();
      } else if (event.key === "Tab") {
        event.preventDefault();
        this.input()?.focus();
      }
    };
    window.addEventListener("keydown", this.onKey, true);
    this.active = 0;
    this.wasOpen = false;
    this.arrange();
  },

  updated() {
    this.arrange();
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey, true);
  },

  dialog() {
    return this.el.querySelector("[role=dialog]");
  },

  input() {
    return this.el.querySelector("input");
  },

  items() {
    return [...this.el.querySelectorAll(ITEM)];
  },

  close() {
    this.pushEvent("close_finder", {});
  },

  move(by) {
    const count = this.items().length;
    if (count === 0) return;
    this.active = (this.active + by + count) % count;
    this.mark();
    this.items()[this.active].scrollIntoView({ block: "nearest" });
  },

  mark() {
    for (const [at, item] of this.items().entries()) item.setAttribute("aria-selected", String(at === this.active));
  },

  arrange() {
    const open = this.dialog() !== null;
    if (open && !this.wasOpen) {
      this.opener ||= document.activeElement;
      this.active = 0;
      this.input()?.focus();
    }
    if (!open && this.wasOpen) {
      if (this.opener instanceof HTMLElement && this.opener.isConnected) this.opener.focus();
      this.opener = null;
    }
    this.wasOpen = open;
    if (!open) return;

    const typed = this.input()?.value ?? "";
    if (typed !== this.typed) this.active = 0;
    this.typed = typed;
    this.active = Math.min(this.active, Math.max(this.items().length - 1, 0));
    this.mark();
  },
};
