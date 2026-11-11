import {basicSetup} from "codemirror"
import {EditorState} from "@codemirror/state"
import {EditorView, keymap} from "@codemirror/view"
import {HighlightStyle, syntaxHighlighting} from "@codemirror/language"
import {markdown} from "@codemirror/lang-markdown"
import {tags} from "@lezer/highlight"
import {yCollab, yUndoManagerKeymap} from "y-codemirror.next"
import * as Y from "yjs"
import {sharedClient} from "./client"

const tint = (token, share) => `color-mix(in oklab, var(${token}) ${share}%, transparent)`

const theme = EditorView.theme({
  "&": {height: "100%", fontSize: "var(--editor-size)", backgroundColor: "transparent", color: "var(--ink)"},
  "&.cm-focused": {outline: "none"},
  ".cm-scroller": {
    fontFamily: "var(--ff-sans)",
    lineHeight: "1.7",
    paddingInline: "max(0px, calc((100% - 50rem) / 2))",
  },
  ".cm-content": {
    flexBasis: "0",
    padding: "2rem clamp(1.125rem, 4vw, 2rem) 40vh",
    caretColor: "var(--accent)",
    fontVariantLigatures: "none",
  },
  ".cm-line": {padding: "0 0.25rem"},
  ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--accent)", borderLeftWidth: "2px"},
  ".cm-gutters": {
    backgroundColor: "transparent",
    border: "none",
    color: tint("--faint", 60),
    fontFamily: "var(--ff-mono)",
    fontSize: "0.72em",
    paddingTop: "0",
  },
  ".cm-lineNumbers .cm-gutterElement": {minWidth: "2.25rem", padding: "0 0.25rem 0 0"},
  ".cm-foldGutter .cm-gutterElement": {color: "var(--faint)", cursor: "pointer"},
  ".cm-activeLine": {backgroundColor: tint("--ink", 4), borderRadius: "0.25rem"},
  ".cm-activeLineGutter": {backgroundColor: "transparent", color: "var(--muted)"},
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground": {
    backgroundColor: tint("--accent", 24),
  },
  ".cm-selectionMatch": {backgroundColor: tint("--accent", 14)},
  "&.cm-focused .cm-matchingBracket": {backgroundColor: tint("--accent", 22), outline: "none"},
  ".cm-foldPlaceholder": {
    backgroundColor: "var(--sunken)",
    border: "1px solid var(--line)",
    color: "var(--muted)",
    padding: "0 0.4rem",
  },
  ".cm-tooltip": {
    backgroundColor: "var(--surface)",
    border: "1px solid var(--line-strong)",
    borderRadius: "0.5rem",
    boxShadow: "var(--elev-2)",
    color: "var(--ink)",
    overflow: "hidden",
  },
  ".cm-tooltip-autocomplete ul li[aria-selected]": {backgroundColor: "var(--accent)", color: "var(--accent-ink)"},
  ".cm-panels": {backgroundColor: "var(--sunken)", color: "var(--ink)", fontFamily: "var(--ff-sans)"},
  ".cm-panels.cm-panels-top": {borderBottom: "1px solid var(--line)"},
  ".cm-panels.cm-panels-bottom": {borderTop: "1px solid var(--line)"},
  ".cm-panel.cm-search": {padding: "0.5rem 0.75rem"},
  ".cm-textfield": {
    backgroundColor: "var(--surface)",
    border: "1px solid var(--line-strong)",
    borderRadius: "0.375rem",
    color: "var(--ink)",
    padding: "0.2rem 0.5rem",
  },
  ".cm-button": {
    backgroundImage: "none",
    backgroundColor: "var(--surface)",
    border: "1px solid var(--line-strong)",
    borderRadius: "0.375rem",
    color: "var(--ink)",
    padding: "0.2rem 0.6rem",
  },
  ".cm-searchMatch": {backgroundColor: tint("--warn", 30), borderRadius: "2px"},
  ".cm-searchMatch.cm-searchMatch-selected": {backgroundColor: tint("--warn", 60)},
  ".cm-ySelectionInfo": {
    fontFamily: "var(--ff-sans)",
    fontSize: "0.6875rem",
    fontWeight: "600",
    padding: "1px 5px",
    borderRadius: "4px 4px 4px 0",
    opacity: "1",
  },
})

const marks = HighlightStyle.define([
  {tag: tags.heading1, fontFamily: "var(--ff-serif)", fontSize: "1.55em", fontWeight: "700", letterSpacing: "-0.015em"},
  {tag: tags.heading2, fontFamily: "var(--ff-serif)", fontSize: "1.3em", fontWeight: "700", letterSpacing: "-0.01em"},
  {tag: tags.heading3, fontFamily: "var(--ff-serif)", fontSize: "1.12em", fontWeight: "700"},
  {tag: [tags.heading4, tags.heading5, tags.heading6], fontWeight: "700"},
  {tag: tags.strong, fontWeight: "700"},
  {tag: tags.emphasis, fontStyle: "italic"},
  {tag: tags.strikethrough, textDecoration: "line-through", color: "var(--faint)"},
  {tag: tags.link, color: "var(--accent)"},
  {tag: tags.url, color: "var(--accent)", opacity: "0.75"},
  {tag: tags.monospace, fontFamily: "var(--ff-mono)", fontSize: "0.9em", color: "var(--muted)"},
  {tag: tags.quote, color: "var(--muted)", fontStyle: "italic"},
  {tag: [tags.processingInstruction, tags.meta, tags.contentSeparator, tags.comment], color: "var(--faint)", fontWeight: "400"},
  {tag: [tags.labelName, tags.string], color: "var(--muted)"},
  {tag: tags.atom, color: "var(--accent)"},
  {tag: tags.documentMeta, fontFamily: "var(--ff-mono)", fontSize: "0.85em", color: "var(--faint)"},
])

const frontmatterFence = /^---\s*$/

const frontmatter = {
  defineNodes: [{name: "Frontmatter", block: true, style: tags.documentMeta}],
  parseBlock: [
    {
      name: "Frontmatter",
      before: "HorizontalRule",
      parse(cx, line) {
        if (cx.lineStart !== 0 || !frontmatterFence.test(line.text)) return false

        let end = line.text.length
        while (cx.nextLine()) {
          end = cx.lineStart + line.text.length
          if (frontmatterFence.test(line.text)) {
            cx.nextLine()
            break
          }
        }

        cx.addElement(cx.elt("Frontmatter", 0, end))
        return true
      },
    },
  ],
}

export const Editor = {
  mounted() {
    const {entryId, token, writable, userName, userColor} = this.el.dataset
    const client = sharedClient(token)

    this.session = client.doc(entryId)
    this.session.awareness.setLocalStateField("user", {
      name: userName,
      color: userColor,
      colorLight: userColor.replace("45%)", "45% / 0.25)"),
    })

    const undoManager = new Y.UndoManager(this.session.text)
    const editable = writable === "true"

    this.view = new EditorView({
      parent: this.el,
      state: EditorState.create({
        doc: this.session.text.toString(),
        extensions: [
          keymap.of(yUndoManagerKeymap),
          basicSetup,
          markdown({extensions: [frontmatter]}),
          syntaxHighlighting(marks),
          EditorView.lineWrapping,
          EditorState.readOnly.of(!editable),
          EditorView.editable.of(editable),
          yCollab(this.session.text, this.session.awareness, {undoManager}),
          theme,
        ],
      }),
    })
  },

  destroyed() {
    this.view?.destroy()
    this.session?.close()
  },
}
