export const openNotes = new Set();

export function anyNoteUnsent() {
  return [...openNotes].some((session) => session.pending);
}

export function allNotesSaved(timeoutMs) {
  return Promise.all([...openNotes].map((session) => session.whenSynced(timeoutMs)));
}
