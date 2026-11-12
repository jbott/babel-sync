import { Compartment, type Extension } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { type App, MarkdownView } from "obsidian";
import { yCollab } from "y-codemirror.next";
import * as Y from "yjs";
import type { OpenDoc, SyncEngine } from "./engine.ts";

const SETTLE_ATTEMPTS = 3;
const RETRY_MS = 2000;

type Binding = { path: string; doc: OpenDoc | null; generation: number; unavailable: boolean };

export class Collab {
  readonly extension: Extension;

  private compartment = new Compartment();
  private bindings = new Map<EditorView, Binding>();
  private generation = 0;
  private app: App;
  private engine: () => SyncEngine | null;
  private user: () => { name: string; color: string };

  constructor(app: App, engine: () => SyncEngine | null, user: () => { name: string; color: string }) {
    this.app = app;
    this.engine = engine;
    this.user = user;
    this.extension = this.compartment.of([]);
  }

  refresh(): void {
    const visible = new Set<EditorView>();

    for (const leaf of this.app.workspace.getLeavesOfType("markdown")) {
      const view = leaf.view;
      if (!(view instanceof MarkdownView) || !view.file) continue;

      const editor = (view.editor as unknown as { cm?: EditorView }).cm;
      if (!editor) continue;

      visible.add(editor);
      const bound = this.bindings.get(editor);
      if (!bound || bound.path !== view.file.path || bound.unavailable) void this.bind(editor, view);
    }

    for (const editor of [...this.bindings.keys()]) {
      if (!visible.has(editor)) this.unbind(editor);
    }
  }

  releaseAll(): void {
    for (const editor of [...this.bindings.keys()]) this.unbind(editor);
  }

  private async bind(editor: EditorView, view: MarkdownView): Promise<void> {
    const path = view.file!.path;
    this.unbind(editor);
    const binding: Binding = { path, doc: null, generation: ++this.generation, unavailable: false };
    this.bindings.set(editor, binding);

    const doc = await this.openSettled(editor, view, binding);
    if (!doc) return;
    binding.doc = doc;

    const shared = doc.text.toString();
    if (editor.state.doc.toString() !== shared) {
      editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: shared } });
    }

    const { name, color } = this.user();
    doc.awareness.setLocalStateField("user", { name, color, colorLight: color + "40" });

    editor.dispatch({
      effects: this.compartment.reconfigure(yCollab(doc.text, doc.awareness, { undoManager: new Y.UndoManager(doc.text) })),
    });
    editor.dispatch({ selection: editor.state.selection });
  }

  private async openSettled(editor: EditorView, view: MarkdownView, binding: Binding): Promise<OpenDoc | null> {
    for (let attempt = 0; attempt < SETTLE_ATTEMPTS; attempt++) {
      const typed = editor.state.doc.toString();
      await view.save().catch(() => {});
      const doc =
        (await this.engine()
          ?.openDoc(binding.path)
          .catch(() => null)) ?? null;

      if (this.bindings.get(editor) !== binding) {
        doc?.release();
        return null;
      }
      if (!doc) {
        binding.unavailable = true;
        return null;
      }
      if (editor.state.doc.toString() === typed) return doc;
      doc.release();
    }
    binding.unavailable = true;
    window.setTimeout(() => this.refresh(), RETRY_MS);
    return null;
  }

  private unbind(editor: EditorView): void {
    const binding = this.bindings.get(editor);
    if (!binding) return;
    this.bindings.delete(editor);

    try {
      editor.dispatch({ effects: this.compartment.reconfigure([]) });
    } catch {
      binding.generation = -1;
    }

    binding.doc?.awareness.setLocalState(null);
    binding.doc?.release();
  }
}
