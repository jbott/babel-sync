# How sync works

This is the reference for what the server and a device promise each other, how the plugin keeps those promises, and what has and has not been checked.

## The pieces

**The server** holds each vault as a set of entries. An entry has an id that never changes, a path, and a kind:

| Kind | What it is | How two edits combine |
|---|---|---|
| doc | A text file: `.md`, `.txt`, `.base`, `.canvas` | Merged character by character in a Yjs document |
| blob | Any other file, stored whole by content hash | The later writer wins on the server; the other device keeps its version as a conflict copy |
| folder | A folder someone made on purpose | Nothing to combine |

Every change to an entry (create, rename, new content, delete) takes the next number from a per-vault counter. That number is the entry's `seq`. It is both the entry's version and its place in the vault's change feed. A deleted entry stays, marked deleted, until the trash is purged.

**A device** keeps three things:

- its files on disk;
- a record per entry: id, path, kind, the hash, size and modification time of the file as last synced, and the server `seq` it last applied for that entry;
- a cursor: the highest `seq` up to which it has applied every change.

## What "in sync" means

A device reports "synced" only when all of these hold:

1. The cursor has reached the end of the feed.
2. The digest of its `(id, seq)` pairs equals the server's. The digest is a SHA-256 over the sorted pairs of every live entry.
3. A scan of its own files found nothing that differs from its records.

The first is what the original design checked. The second and third were added on 2026-11-11 after a phone sat at 1,208 of 2,279 entries while saying it was in sync: it had moved its cursor past changes it never applied, and nothing compared actual state.

## The steps

### Joining

The device joins the vault's channel with its cursor. The server replies with every entry changed since then, its current `seq` and its digest. If the cursor is older than the oldest purged deletion, the server sends the complete listing and says so, and the device removes anything it holds that is not in it.

### Applying a remote change

For each change, in `seq` order:

- If the device already holds that `seq` or a later one for the entry, skip it.
- An entry the device does not have is adopted: the file is written. If a different file is already at that path, the device asks the server whether that content is an earlier version of the same entry. If so it is replaced quietly; if not it is kept as a conflict copy and sent up as a new file.
- An entry the device has is updated: moved if the path changed, re-read if the content changed. A doc is merged through its Yjs document, so local edits survive. A blob whose local file also changed is kept as a conflict copy.
- A deletion removes the local file, unless it changed locally or holds edits not yet sent, in which case it is sent up as a new file. The file is removed before the record, so a removal that fails is tried again rather than mistaken for a new file.
- A change that the device's file system refuses three times (a name it cannot hold, for instance) is left out with one error message, and the cursor moves on. It is tried again each time the plugin starts.

The cursor moves only after the change is applied. If applying fails, the device marks itself behind, leaves the cursor where it is, and retries the whole comparison after 20 seconds, doubling up to 5 minutes.

### The audit

If the digests differ after the feed is applied, or the device was behind, it sends the server its `(id, seq)` pairs. The server answers with every live entry whose `seq` differs or that the device lacks, and the ids it no longer has. Those are applied like any other change. This is what makes the device's state a function of the server's state rather than of the messages it happened to receive.

### The local scan

After any burst of work the device lists its files and compares them with its records:

- a file with no record is sent as new;
- a file whose size or modification time differs is re-hashed and sent if the content changed;
- a record whose file is gone is deleted on the server;
- a record whose path was taken over by another entry is deleted on the server;
- a rename not yet sent is sent.

If a scan found anything to do, another follows, up to five in a row. Only a scan that finds nothing lets the device say "synced".

### File events are hints

Obsidian reports every change to a file, including the ones the plugin itself just made. So the plugin never trusts an event's description of what happened. Each event only says where to look, and the plugin compares the disk with its records there:

- "changed" re-hashes the file and sends it only if it differs from the record;
- "deleted" does nothing if a file is at that path;
- "renamed" is treated as a rename only if nothing is left at the old path, a file is at the new one, and no other entry already holds the new path. Otherwise both paths are checked as plain changes. When a file is renamed over another entry (an editor saving through a temporary file), the entry at the destination keeps its identity and history and takes the new content.

### Names

- The server refuses two entries whose paths differ only by case, because most phones and laptops cannot hold both. It compares names folded the way the plugin folds them (NFC, then Unicode lowercase), so `Ärger.md` and `ärger.md` collide as `Note.md` and `note.md` do. The check also covers a restore from the trash, which takes a free name instead, and every child of a renamed folder. A device that has such a second file keeps it under a conflict name.
- A folder holds every entry under its name in any case, so deleting `Notes` only when empty counts `notes/x.md` as inside it.
- A rename that changes only the case is a rename, on every device.
- Files under `.obsidian` never get a conflict copy. When two devices change the same settings file, the one that reaches the server first wins and the other device takes it. A copy of a plugin's settings is clutter nobody reads, and the next change rewrites the file anyway.
- Conflict copies are named `<name> (conflict <device> <date time>)`. A name never carries two such suffixes, and characters in the device name that a file name cannot hold are dropped.

### Folders

A device that deletes a folder asks the server to delete it only if it is empty there. If another device added a note the first never saw, the folder stays and the note arrives.

### Read-only devices

A device signed in as a viewer applies remote changes and sends nothing. Local edits stay local.

### Sending a local change

- A doc edit goes through the Yjs document, so it merges with whatever others typed.
- A blob is uploaded, then the entry is pointed at it, naming the hash the device last saw. If the server's hash is different, the server's version is downloaded and the device's is kept as a conflict copy.
- A delete or rename names the entry by id.

## What is checked, and how

| Claim | How it is checked | Strength |
|---|---|---|
| The protocol converges, a device that says "synced" equals the server, and no written value is lost, even when changes are missed or records forgotten | `spec/Sync.tla`, model-checked with TLC: 2 devices, 2 entries, 4 edits, 2 faults; 2.7 million states | Proof for that size of model. Says nothing about the code |
| Without the audit, a missed change leaves a device wrong but "synced" | `spec/SyncFeedOnly.cfg`: TLC finds the counterexample in four steps | Confirms the model can express the bug that happened |
| One device's engine, taken a step at a time against a server anyone may change, loses no text, duplicates none, keeps each record's base equal to what its file was last reconciled against, never moves its cursor past a change it has not applied, and equals the server when it says "synced", with edits, deletions and crashes between any two steps | `spec/Engine.tla`, model-checked with TLC: 3 paths, 4 identities, 2 local edits, 2 changes by others, 2 crashes; 2.75 million states | Proof for that size of model, under the assumptions listed below. Says nothing about the code |
| The engine model can see the bugs of 2026-11-14 | Eight more configurations of `spec/Engine.tla`, each putting one fault back; TLC finds a counterexample for each | Confirms the model can express them |
| The TypeScript engine converges under crashes, restarts and offline edits | `plugin/test/simulation.test.ts`: three engines against a real server, random operations, crash injection, and a state database that fails and stalls at random | Evidence, not proof. Seeded and repeatable in content, but timing varies between runs |
| Named scenarios behave as intended | `plugin/test/engine.test.ts`. The test file system reports every change back to the engine, including the engine's own, as Obsidian does, and can be made blind to case or made to refuse names | One case each |
| The plugin works inside Obsidian | `plugin/test/real-obsidian.mjs`, two isolated Obsidian instances | Desktop only |

To run every model and compare each result with what is expected:

```
spec/check.sh
```

It prints one line per configuration and exits non-zero if any result is not the expected one. To run one by hand:

```
cd spec
nix shell nixpkgs#tlaplus -c tlc -deadlock -config Sync.cfg Sync.tla
nix shell nixpkgs#tlaplus -c tlc -deadlock -config SyncFeedOnly.cfg Sync.tla
nix shell nixpkgs#tlaplus -c tlc -deadlock -workers auto -config Engine.cfg Engine.tla
```

The first and third should report no error. The second should report that `SyncedMeansEqual` is violated.

There are two models because they answer different questions. `Sync.tla` has several devices and whole-step actions, and asks whether they converge when changes are missed or records forgotten. `Engine.tla` has one device and asks whether its steps are in a safe order.

### The engine model

`spec/Engine.tla` has one device and a server that anyone else may change at any moment: create, edit, rename, delete. Devices only meet through the server, so what holds for one device against every possible server holds for each of any number of devices. The header of the module gives that argument, and the one for why 3 paths and 4 identities are enough for anything a single engine action does.

A note's text is a set of tokens, and a note is the set of tokens ever added and the set ever deleted. Taking a file into a note against a base adds what the file has and the base lacks, and deletes what the base has and the file lacks. Against the wrong base that deletes a token nobody chose to delete, or adds one the note already had, and the model sees both.

The engine's work is split into the steps the code awaits between: fetch the note, clear the path, record the intent, re-read the disk, write the file, record the base. Between any two the user may edit or delete any file, someone else may change the server, and the device may crash, losing what it held in memory and keeping its files and records. The feed replays every event in order, each with the path the entry had then.

| Configuration | What it changes | Expected |
|---|---|---|
| `Engine.cfg` | Nothing | No error |
| `EngineDeep.cfg` | 3 local edits, 2 changes by others, 1 crash; 14.7 million states and several minutes. Run with `spec/check.sh deep` | No error |
| `EngineLive.cfg` | Checks that the device ends up synced, or the model ran out of paths or identities, once edits and crashes stop. 2 local edits, 1 change by others, 1 crash, no symmetry | No error |
| `EngineStaleCheck.cfg` | The disk is read before the intent is recorded, not after | `NothingLost`: an edit made in between is overwritten |
| `EngineFirstWrite.cfg` | The same, for a note arriving for the first time | `NothingLost`: a file the user made at that path is overwritten |
| `EngineNoIntent.cfg` | No intent is recorded before writing | `BaseMatchesFile`: a crash after the write leaves the old base beside the new file |
| `EngineSendFirst.cfg` | A local edit is sent before the new base is recorded | `NothingDuplicated`: after a crash the edit is taken in a second time |
| `EngineSeqWithoutEntry.cfg` | A note pushed off its path keeps its recorded seq | `CursorHonest`: its later event is skipped and the device goes without it |
| `EngineWriteWindow.cfg` | An edit may land between the re-read and the write | `NothingLost`. No order of steps closes this; see below |
| `EngineRecoveryAsBriefed.cfg` | After a crash, a pending intent with no base is always adopted | `NothingLost`: see below |
| `EngineVacateFileFirst.cfg` | When a note is pushed off its path, its file is removed before its record | `NothingLost`: see below |

### What the engine model found

Three things the model needed changed before it would pass. The engine was changed to follow the first two; the third is an assumption the code cannot fully honour, as a file system offers no way to read and write in one step.

1. **Recovering a pending intent.** The rule "adopt the intent if the file equals its text, or there was no base, or the file is closer to its text than to the base" loses text in three ways. With no base and no file (a crash before the first write), adopting makes the record say the file once existed, the scan takes the missing file for a deletion, and the note is deleted on the server. With no base and a file the user made at that path, that file is taken for the note; when the user then deletes their file, the note is deleted on the server, though nobody on this device ever saw its text. With a base, "closer" guesses wrong when the file was written and then edited by as much as the server's change, and the server's change is taken in a second time. The rule the model passes with: adopt only when the file equals the intent's text; keep the old base when the file is missing, equals the old base, or there was no base; in every other case forget the base, so the next pass treats the file as a stranger's and keeps it as a conflict copy.
2. **Clearing a path.** When an arriving note needs a path that another note's unchanged file holds, the code removes that file and then forgets that note's record. A crash between the two leaves a record whose file is gone, which the scan takes for a deletion by the user, and the other note is deleted on the server for everyone. The model passes with the order reversed: forget the record, then remove the file if it still has the text it had.
3. **The re-read and the write are assumed to be one step.** If an edit can land between them it is overwritten, whatever the order of the other steps. The same goes for "check the file is unchanged, then remove it". The model assumes it cannot; `EngineWriteWindow.cfg` drops the assumption.

One thing it found that it accepts: after a crash between writing a file and recording it, if the user has meanwhile undone the server's change exactly, or deleted the file, recovery cannot tell this from the write never having happened. It keeps the old base, and the user's change in that window is undone. No text is lost.

### What the engine model assumes

- The engine runs one task at a time, and after a restart it settles pending intents before anything else.
- One write to the record store is atomic and survives a crash. A file write is all or nothing.
- No edit lands between re-reading a file and writing, removing or renaming it.
- The server refuses to delete a note whose text differs from the text the device names, says "not found" for a deleted note, and answers a create at a taken path with the note that holds it.
- A deleted note does not come back. There is no trash, restore or purge.
- The device learns the seq of a note it created from the reply, and the seq of text it sent from the feed.
- A record with no base and no file is fetched again. In the code this relies on the audit at the next join.

It does not model: a rename made on this device, blobs, folders, case, a note open in the editor, read-only devices, ignored paths, giving up after three attempts, the audit, or the server recognising a file as an older version of a note (the model always keeps a conflict copy). Text is a set, so it has no order, and typing the same words twice is two different tokens.

### What the first model leaves out

`Sync.tla` treats an entry as one value with a version. It does not model:

- paths, renames, folders, or two entries wanting the same path;
- the Yjs merge of docs (it models the blob rule: one side wins, the other is kept);
- the file system: case-insensitive names, invalid characters, modification times;
- Obsidian's file events and their timing relative to the engine's work;
- more than one engine running on the same disk;
- sign-in, token renewal, or the connection itself.

Every bug found on 2026-11-11 after the audit was added lay in one of those areas, and so did the four found by fault injection on 2026-11-14, which is why the engine model exists. Both models are checks on the design; the simulation is the check on the code, and it only covers what it has been taught to do.

## Review of 2026-11-11

A line-by-line review of the engine against this document found ten faults. Seven now have an engine test that fails without the fix, and the folder rule is tested on the server. Three have no test of their own yet: the remote rename that moved the wrong file, viewer devices, and the order of removal.

| Fault | Effect | Fix |
|---|---|---|
| The engine acted on Obsidian's events for its own renames | A conflict copy was deleted on the server, the real entry was renamed to the conflict name, and names grew a suffix per round | Events are hints (above) |
| Offline note edits were not counted as changes when the note was deleted elsewhere | The edits were deleted | Unsent edits count as changes |
| Case-only renames, and two names differing by case | Conflict copies, a deleted entry, two entries sharing one file | Names (above) |
| A remote rename moved whatever file was at the entry's old path | Another entry's file was moved | Only the entry's own file is moved |
| Two notes swapping names while a device was away | A spurious conflict copy | The unchanged file in the way is removed and fetched again under its new name |
| Deleting a folder deleted everything in it on the server | Notes the device never saw were deleted | Folders (above) |
| Attachments over the size limit were recorded as seen | Never downloaded after the limit was raised | Unfetched files are asked for again at each start |
| Viewer devices tried to send | Errors forever | Read-only devices (above) |
| A name the device cannot hold | Error every retry, cursor frozen | Left out after three attempts |
| A record was dropped before its file was removed | A failed removal came back as a new file | Order reversed |

Not yet examined closely: file names in decomposed Unicode on devices that keep them that way, and races between creating and pruning empty folders.
