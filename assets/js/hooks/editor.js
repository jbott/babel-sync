import {basicSetup} from "codemirror"
import {EditorState} from "@codemirror/state"
import {EditorView, keymap} from "@codemirror/view"
import {markdown} from "@codemirror/lang-markdown"
import {yCollab, yUndoManagerKeymap} from "y-codemirror.next"
import * as Y from "yjs"
import {sharedClient} from "./client"

const theme = EditorView.theme({
  "&": {height: "100%", fontSize: "15px", backgroundColor: "transparent", color: "var(--color-base-content)"},
  ".cm-scroller": {fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", lineHeight: "1.6"},
  ".cm-content": {maxWidth: "52rem", margin: "0 auto", padding: "1.5rem 2rem", caretColor: "var(--color-primary)"},
  ".cm-gutters": {backgroundColor: "transparent", border: "none", color: "color-mix(in oklab, var(--color-base-content) 40%, transparent)"},
  ".cm-activeLine, .cm-activeLineGutter": {backgroundColor: "color-mix(in oklab, var(--color-base-content) 5%, transparent)"},
  "&.cm-focused": {outline: "none"},
})

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
          markdown(),
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
