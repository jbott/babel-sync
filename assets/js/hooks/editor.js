export const Editor = {
  mounted() {
    this.loaded = import("./note_editor").then(({ NoteEditor }) => {
      if (this.left) return null;
      const { mounted, updated, destroyed, ...helpers } = NoteEditor;
      Object.assign(this, helpers);
      mounted.call(this);
      return { updated, destroyed };
    });
  },

  updated() {
    this.loaded.then((editor) => editor?.updated.call(this));
  },

  destroyed() {
    this.left = true;
    this.loaded.then((editor) => editor?.destroyed.call(this));
  },
};
