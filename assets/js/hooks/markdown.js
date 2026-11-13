let temml;
let mermaid;
let diagrams = 0;

const dark = () => document.documentElement.dataset.theme === "dark";

async function renderMath(root) {
  const pending = root.querySelectorAll("span[data-math-style]:not([data-drawn])");
  if (pending.length === 0) return;
  temml ??= (await import("temml")).default;

  for (const span of pending) {
    const source = span.textContent;
    span.dataset.drawn = "";
    try {
      temml.render(source.trim(), span, { displayMode: span.dataset.mathStyle === "display", throwOnError: false });
    } catch {
      span.textContent = source;
    }
  }
}

async function renderDiagrams(root) {
  const pending = root.querySelectorAll("pre.mermaid:not([data-drawn])");
  if (pending.length === 0) return;
  mermaid ??= (await import("mermaid")).default;
  mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark() ? "dark" : "default" });

  for (const block of pending) {
    const source = block.textContent;
    block.dataset.drawn = "";
    try {
      const { svg } = await mermaid.render(`babelsync-diagram-${++diagrams}`, source);
      if (block.isConnected && block.textContent === source) block.innerHTML = svg;
    } catch {
      block.dataset.failed = "";
    }
  }
}

export const Markdown = {
  mounted() {
    this.draw();
  },
  updated() {
    this.draw();
  },
  draw() {
    renderMath(this.el);
    renderDiagrams(this.el);
  },
};
