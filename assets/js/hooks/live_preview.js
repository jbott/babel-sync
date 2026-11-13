import { syntaxTree } from "@codemirror/language";
import { Decoration, EditorView, ViewPlugin, WidgetType } from "@codemirror/view";
import { tags } from "@lezer/highlight";

const OPEN_BRACKET = 91;
const BANG = 33;

export const wikilinks = {
  defineNodes: [
    { name: "WikiLink", style: tags.link },
    { name: "WikiLinkMark", style: tags.processingInstruction },
  ],
  parseInline: [
    {
      name: "WikiLink",
      before: "Link",
      parse(cx, next, pos) {
        const open = next === BANG ? pos + 1 : pos;
        if (cx.char(open) !== OPEN_BRACKET || cx.char(open + 1) !== OPEN_BRACKET) return -1;

        const inner = cx.slice(open + 2, cx.end);
        const length = inner.indexOf("]]");
        if (length < 1 || inner.slice(0, length).includes("[[") || inner.slice(0, length).includes("\n")) return -1;

        const close = open + 2 + length;
        return cx.addElement(cx.elt("WikiLink", pos, close + 2, [cx.elt("WikiLinkMark", pos, open + 2), cx.elt("WikiLinkMark", close, close + 2)]));
      },
    },
  ],
};

class Bullet extends WidgetType {
  eq() {
    return true;
  }

  toDOM() {
    const dot = document.createElement("span");
    dot.className = "cm-bullet";
    dot.textContent = "•";
    return dot;
  }
}

class Rule extends WidgetType {
  eq() {
    return true;
  }

  toDOM() {
    const rule = document.createElement("span");
    rule.className = "cm-rule";
    return rule;
  }
}

class Checkbox extends WidgetType {
  constructor(checked) {
    super();
    this.checked = checked;
  }

  eq(other) {
    return other.checked === this.checked;
  }

  toDOM(view) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.className = "cm-task";
    box.checked = this.checked;
    box.disabled = view.state.readOnly;
    box.setAttribute("aria-label", this.checked ? "Done" : "Not done");
    box.addEventListener("mousedown", (event) => event.preventDefault());
    box.addEventListener("click", (event) => {
      event.preventDefault();
      const at = view.posAtDOM(box);
      if (view.state.sliceDoc(at, at + 1) !== "[") return;
      view.dispatch({ changes: { from: at + 1, to: at + 2, insert: this.checked ? " " : "x" } });
    });
    return box;
  }

  ignoreEvent() {
    return true;
  }
}

const hidden = Decoration.replace({});
const bullet = Decoration.replace({ widget: new Bullet() });
const rule = Decoration.replace({ widget: new Rule() });
const inlineCode = Decoration.mark({ class: "cm-inline-code" });
const indent = Decoration.mark({ class: "cm-indent" });
const quoted = Decoration.line({ class: "cm-quoted" });
const fenced = Decoration.line({ class: "cm-fenced" });
const fencedFirst = Decoration.line({ class: "cm-fenced cm-fenced-first" });
const fencedLast = Decoration.line({ class: "cm-fenced cm-fenced-last" });

const WRAPPED = { EmphasisMark: true, StrikethroughMark: true, CodeMark: true, SubscriptMark: true, SuperscriptMark: true };
const INLINE = ["Emphasis", "StrongEmphasis", "Strikethrough", "InlineCode", "Subscript", "Superscript"];

function wikilinkParts(text) {
  const inner = text.slice(2, -2);
  const bar = inner.indexOf("|");
  return bar < 0 ? { target: inner, shownFrom: 2 } : { target: inner.slice(0, bar), shownFrom: 2 + bar + 1 };
}

function decorations(view) {
  const { state } = view;
  const { doc } = state;
  const found = [];

  const touches = (from, to) => state.selection.ranges.some((range) => range.from <= to && range.to >= from);
  const lineTouched = (at) => {
    const line = doc.lineAt(at);
    return touches(line.from, line.to);
  };
  const hide = (from, to) => {
    if (from < to) found.push(hidden.range(from, to));
  };
  const eachLine = (from, to, mark) => {
    for (let at = doc.lineAt(from).from; at <= to; at = doc.lineAt(at).to + 1) mark(doc.lineAt(at));
  };

  const seen = {
    HeaderMark(node) {
      if (!node.node.parent?.name.startsWith("ATXHeading") || lineTouched(node.from)) return;
      const spaced = doc.sliceString(node.to, node.to + 1) === " ";
      hide(node.from, spaced ? node.to + 1 : node.to);
    },

    InlineCode(node) {
      found.push(inlineCode.range(node.from, node.to));
    },

    Link(node) {
      if (touches(node.from, node.to)) return;
      const marks = node.node.getChildren("LinkMark");
      const address = node.node.getChild("URL");
      if (marks.length < 4 || !address || marks[0].to === marks[1].from) return;

      hide(marks[0].from, marks[0].to);
      hide(marks[1].from, node.to);
      found.push(
        Decoration.mark({
          class: "cm-followable",
          attributes: { "data-address": doc.sliceString(address.from, address.to) },
        }).range(marks[0].to, marks[1].from),
      );
      return false;
    },

    WikiLink(node) {
      const text = doc.sliceString(node.from, node.to);
      if (text.startsWith("!") || touches(node.from, node.to)) return false;

      const { target, shownFrom } = wikilinkParts(text);
      if (node.from + shownFrom >= node.to - 2) return false;

      hide(node.from, node.from + shownFrom);
      hide(node.to - 2, node.to);
      found.push(Decoration.mark({ class: "cm-followable", attributes: { "data-target": target } }).range(node.from + shownFrom, node.to - 2));
      return false;
    },

    ListMark(node) {
      const line = doc.lineAt(node.from);
      if (line.from < node.from && doc.sliceString(line.from, node.from).trim() === "") {
        found.push(indent.range(line.from, node.from));
      }
      if (node.node.parent?.parent?.name !== "BulletList") return;

      const task = node.node.nextSibling?.name === "Task" ? node.node.nextSibling.firstChild : null;
      if (task?.name === "TaskMarker") {
        if (touches(node.from, task.to)) return;
        const checked = doc.sliceString(task.from + 1, task.from + 2).toLowerCase() === "x";
        hide(node.from, task.from);
        found.push(Decoration.replace({ widget: new Checkbox(checked) }).range(task.from, task.to));
      } else if (!touches(node.from, node.to)) {
        found.push(bullet.range(node.from, node.to));
      }
    },

    QuoteMark(node) {
      if (lineTouched(node.from)) return;
      const spaced = doc.sliceString(node.to, node.to + 1) === " ";
      hide(node.from, spaced ? node.to + 1 : node.to);
    },

    Blockquote(node, from, to) {
      eachLine(Math.max(node.from, from), Math.min(node.to, to), (line) => found.push(quoted.range(line.from)));
    },

    FencedCode(node, from, to) {
      const first = doc.lineAt(node.from).from;
      const last = doc.lineAt(node.to).from;
      eachLine(Math.max(node.from, from), Math.min(node.to, to), (line) => {
        const mark = line.from === first ? fencedFirst : line.from === last ? fencedLast : fenced;
        found.push(mark.range(line.from));
      });
    },

    HorizontalRule(node) {
      if (!lineTouched(node.from)) found.push(rule.range(node.from, node.to));
    },
  };

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter(node) {
        if (WRAPPED[node.name]) {
          const around = node.node.parent;
          if (around && INLINE.includes(around.name) && !touches(around.from, around.to)) hide(node.from, node.to);
          return;
        }
        return seen[node.name]?.(node, from, to);
      },
    });
  }

  return Decoration.set(found, true);
}

const rendering = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.tree = syntaxTree(view.state);
      this.decorations = decorations(view);
    }

    update(update) {
      const tree = syntaxTree(update.state);
      if (update.docChanged || update.viewportChanged || update.selectionSet || tree !== this.tree) {
        this.tree = tree;
        this.decorations = decorations(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

const look = EditorView.baseTheme({
  ".cm-bullet": { color: "var(--muted)", display: "inline-block", width: "1ch", textAlign: "center" },
  ".cm-indent": { fontFamily: "var(--ff-mono)" },
  ".cm-task": {
    accentColor: "var(--accent)",
    cursor: "pointer",
    height: "0.95em",
    margin: "0 0.15em 0 0",
    verticalAlign: "-0.08em",
    width: "0.95em",
  },
  ".cm-rule": {
    borderTop: "1px solid var(--line-strong)",
    display: "inline-block",
    verticalAlign: "middle",
    width: "100%",
  },
  ".cm-inline-code": {
    backgroundColor: "var(--sunken)",
    borderRadius: "0.25rem",
    padding: "0.1em 0.3em",
  },
  ".cm-line.cm-quoted": {
    borderLeft: "3px solid var(--line-strong)",
    paddingLeft: "0.9rem",
  },
  ".cm-line.cm-fenced": {
    backgroundColor: "var(--sunken)",
    paddingInline: "0.9rem",
  },
  ".cm-line.cm-fenced-first": { borderRadius: "0.5rem 0.5rem 0 0" },
  ".cm-line.cm-fenced-last": { borderRadius: "0 0 0.5rem 0.5rem" },
  ".cm-followable": {
    cursor: "pointer",
    textDecoration: "underline",
    textDecorationColor: "color-mix(in oklab, var(--accent) 35%, transparent)",
    textUnderlineOffset: "0.2em",
  },
  ".cm-followable:hover": { textDecorationColor: "var(--accent)" },
});

export function livePreview({ follow }) {
  return [
    rendering,
    look,
    EditorView.domEventHandlers({
      mousedown(event) {
        if (event.button !== 0) return false;
        const link = event.target instanceof Element ? event.target.closest(".cm-followable") : null;
        if (!link) return false;

        event.preventDefault();
        follow(link.dataset);
        return true;
      },
    }),
  ];
}
