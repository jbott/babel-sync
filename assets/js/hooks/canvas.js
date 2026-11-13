const MIN_SCALE = 0.1;
const MAX_SCALE = 3;
const MARGIN = 24;
const DRAG_THRESHOLD = 4;

const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

function scrollsWithin(target, root, deltaX, deltaY) {
  for (let element = target; element && element !== root; element = element.parentElement) {
    const style = getComputedStyle(element);
    const vertical = /(auto|scroll)/.test(style.overflowY) && element.scrollHeight > element.clientHeight;
    const horizontal = /(auto|scroll)/.test(style.overflowX) && element.scrollWidth > element.clientWidth;
    if (vertical && deltaY < 0 && element.scrollTop > 0) return true;
    if (vertical && deltaY > 0 && element.scrollTop + element.clientHeight < element.scrollHeight - 1) return true;
    if (horizontal && deltaX < 0 && element.scrollLeft > 0) return true;
    if (horizontal && deltaX > 0 && element.scrollLeft + element.clientWidth < element.scrollWidth - 1) return true;
  }
  return false;
}

export const Canvas = {
  mounted() {
    this.view = { x: 0, y: 0, scale: 1 };
    this.moved = false;
    this.pointers = new Map();

    this.el.addEventListener("wheel", (event) => this.wheel(event), { passive: false });
    this.el.addEventListener("pointerdown", (event) => this.down(event));
    this.el.addEventListener("pointermove", (event) => this.move(event));
    for (const name of ["pointerup", "pointercancel"]) this.el.addEventListener(name, (event) => this.up(event));
    this.el.addEventListener("click", (event) => this.control(event), true);

    this.resize = new ResizeObserver(() => {
      if (!this.moved) this.fit();
    });
    this.resize.observe(this.el);
    this.fit();
  },

  updated() {
    if (this.moved) this.apply();
    else this.fit();
  },

  destroyed() {
    this.resize.disconnect();
  },

  board() {
    return this.el.querySelector(".canvas-board");
  },

  fit() {
    const board = this.board();
    if (!board) return;
    const width = board.offsetWidth;
    const height = board.offsetHeight;
    const scale = clamp(Math.min((this.el.clientWidth - MARGIN * 2) / width, (this.el.clientHeight - MARGIN * 2) / height, 1), MIN_SCALE, MAX_SCALE);
    this.view = {
      scale,
      x: (this.el.clientWidth - width * scale) / 2,
      y: Math.max(MARGIN, (this.el.clientHeight - height * scale) / 2),
    };
    this.apply();
  },

  apply() {
    const board = this.board();
    if (!board) return;
    board.style.transformOrigin = "0 0";
    board.style.transform = `translate(${this.view.x}px, ${this.view.y}px) scale(${this.view.scale})`;
  },

  zoom(factor, atX, atY) {
    const scale = clamp(this.view.scale * factor, MIN_SCALE, MAX_SCALE);
    const ratio = scale / this.view.scale;
    this.view = { scale, x: atX - (atX - this.view.x) * ratio, y: atY - (atY - this.view.y) * ratio };
    this.moved = true;
    this.apply();
  },

  pan(deltaX, deltaY) {
    this.view = { ...this.view, x: this.view.x + deltaX, y: this.view.y + deltaY };
    this.moved = true;
    this.apply();
  },

  local(event) {
    const bounds = this.el.getBoundingClientRect();
    return { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
  },

  wheel(event) {
    if (!event.ctrlKey && !event.metaKey && scrollsWithin(event.target, this.el, event.deltaX, event.deltaY)) return;
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) {
      const { x, y } = this.local(event);
      this.zoom(Math.exp(-event.deltaY * 0.01), x, y);
    } else {
      this.pan(-event.deltaX, -event.deltaY);
    }
  },

  down(event) {
    if (event.button !== 0 || event.target.closest("[data-canvas]")) return;
    this.pointers.set(event.pointerId, { ...this.local(event), startX: event.clientX, startY: event.clientY, dragging: false });
  },

  move(event) {
    const pointer = this.pointers.get(event.pointerId);
    if (!pointer) return;
    const now = this.local(event);

    if (this.pointers.size === 2) {
      const [first, second] = [...this.pointers.values()];
      const before = Math.hypot(first.x - second.x, first.y - second.y);
      const centreX = (first.x + second.x) / 2;
      const centreY = (first.y + second.y) / 2;
      Object.assign(pointer, now, { dragging: true });
      const after = Math.hypot(first.x - second.x, first.y - second.y);
      this.pan((first.x + second.x) / 2 - centreX, (first.y + second.y) / 2 - centreY);
      if (before > 0) this.zoom(after / before, (first.x + second.x) / 2, (first.y + second.y) / 2);
      return;
    }

    if (!pointer.dragging && Math.hypot(event.clientX - pointer.startX, event.clientY - pointer.startY) < DRAG_THRESHOLD) return;
    if (!pointer.dragging) {
      pointer.dragging = true;
      this.el.setPointerCapture(event.pointerId);
      this.el.dataset.dragging = "";
    }
    this.pan(now.x - pointer.x, now.y - pointer.y);
    Object.assign(pointer, now);
  },

  up(event) {
    const pointer = this.pointers.get(event.pointerId);
    this.pointers.delete(event.pointerId);
    if (this.pointers.size === 0) delete this.el.dataset.dragging;
    if (pointer?.dragging) {
      this.suppressClick = true;
      setTimeout(() => (this.suppressClick = false), 0);
    }
  },

  control(event) {
    if (this.suppressClick) {
      this.suppressClick = false;
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    const button = event.target.closest("[data-canvas]");
    if (!button) return;
    const centreX = this.el.clientWidth / 2;
    const centreY = this.el.clientHeight / 2;
    if (button.dataset.canvas === "in") this.zoom(1.25, centreX, centreY);
    if (button.dataset.canvas === "out") this.zoom(0.8, centreX, centreY);
    if (button.dataset.canvas === "fit") {
      this.moved = false;
      this.fit();
    }
  },
};
