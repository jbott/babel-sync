# Sources

A source is a script, kept as a file in a vault, that the server runs to
bring outside data into notes: starred repositories, liked posts, papers,
devices. The file is yours to read and change. What it may do is written at
the top of it, and nothing runs until a vault owner has approved that.

## Where sources live

Each vault has one folder for sources, picked in vault settings under
Sources. Say it is `Data`. Then:

- a `.js` file anywhere under `Data` that opens with a `/* source` comment
  is a source;
- it makes its notes in the folder beside it that has its name, and
  nowhere else.

```
Data/
  Github/
    Stars.js        the source
    Stars/          the notes it makes
      octocat-hello-world.md
```

A `.js` file under `Data` without the opening comment is not a source. It
is a file sources can import; see below.

## Writing one

The whole file is the script. It opens with a comment holding, as YAML,
what the script asks to be allowed:

```js
/* source
schedule: every 6h
hosts:
  - api.github.com
secrets:
  github: { host: api.github.com, header: "Authorization: Bearer {}" }
params:
  user: octocat
*/
const res = http.get(`https://api.github.com/users/${params.user}/starred`)
for (const repo of res.json()) {
  vault.item(repo.html_url, {
    path: `${vault.name(repo.full_name)}.md`,
    match: { url: repo.html_url },
    properties: { url: repo.html_url, stars: repo.stargazers_count },
    body: `# ${repo.name}\n`,
  })
}
```

| Property | Meaning |
|---|---|
| `schedule` | `every 30m`, `every 6h`, `every 1d`; no more often than every 5 minutes. Left out, the source runs only when asked |
| `hosts` | Host names the script may fetch from. `*.example.com` allows every name under one |
| `secrets` | For each name, the host it goes to and the header it is sent in, with `{}` where the secret goes |
| `reads` | Folders it may read besides its own |
| `params` | Anything; the script sees it as `params` |

A property that is not in this table is refused, so a misspelt one is not
quietly ignored. Line numbers in an error are the file's own.

## Approving

The Sources page lists every source in the vault with what it asks for and
its code. What is approved is the opening comment and where the file is,
since that is where it writes. Approving takes a vault owner signed in
through the browser, and neither an agent's grant nor a device is that.

After that:

- **Editing the script** needs no approval. The next run uses the file as
  it then is, held to what was approved. Anyone who can write to the
  sources folder can therefore change what a source does within its hosts
  and its folders, so give write access to that folder with that in mind.
- **Changing the opening comment, or moving or renaming the file**, asks
  for approval again. Until then the source keeps running as it was.
- **A source that is given a secret** is stricter: its script too runs
  only as approved, and any edit asks again. A secret is sent with every
  request to its host, so an edited script could do whatever the secret
  allows there.

A file moved out of the sources folder stops running, as does one that is
deleted.

Secrets are entered on the same page. They are stored encrypted under the
server's `SECRET_KEY_BASE` and never shown again.

## What a script can do

The script is JavaScript run by QuickJS inside WebAssembly, as a module:
it is in strict mode, may use `await` at the top, and cannot `return`
from the top. It has the language and the following, and nothing else:
no files, no sockets, no timers.

| | |
|---|---|
| `http.get(url, { headers })`, `http.post(url, { headers, body })`, also `put`, `patch`, `delete`, `head` | A request to one of the source's hosts. Returns `status`, `ok`, `headers`, `url`, `text()`, `json()` and `next`, the next page's address when the answer has a `Link` header naming one |
| `vault.item(key, { path, match, properties, body })` | Makes or updates the note for one outside thing; see below |
| `vault.folder` | The source's own folder, such as `Data/Github/Stars` |
| `vault.read(path)` | A note's text, or `null`. The path is from the top of the vault |
| `vault.list(folder)` | The paths in a folder |
| `vault.name(text)` | The text with the characters a file name cannot hold taken out |
| `state.get(name)`, `state.set(name, value)` | Small things to remember between runs, such as a cursor or an ETag. Saved only when the run ends without an error |
| `log(...)` | A line in the run's log |
| `attention(message, { url })` | Asks the owner to do something, such as sign in again. Shown on the Sources page; the link must be https and on one of the source's hosts |
| `params`, `trigger` | The source's `params`, and what started the run: `schedule` or `manual` |

A call that is refused throws, with the reason as the message.

### `vault.item`

`key` is the script's own name for the thing, such as its web address. The
server remembers which note belongs to each key. `path` is within the
source's own folder.

- The first time a key is seen, an existing note is taken over if `match`
  names a property and value that one note in the source's folder has, or
  failing that if a note is already at `path`. Otherwise the note is made
  at `path` with `properties` and `body`.
- After that the key leads to the same note wherever it is moved.
- Only the properties named are set. Others, and the order and formatting
  of the note's properties, are left alone. For a list, the items the
  source wrote last time are replaced by the new ones and items added by
  hand are kept. A property set to `null` is removed.
- The body is written when the note is made and never again.
- If nothing would change, nothing is written: no new version, and no
  device is told.
- A note that was deleted is not made again.

The answer is `{ outcome, path }`, where `outcome` is `created`, `changed`,
`unchanged` or `gone`.

Because every device fetches a note each time it changes, a script should
avoid writing values that change for no reason a person cares about: a
"last synced" time belongs in `state`, and a count that drifts daily is
better rounded.

## Sharing code between sources

A source can import other `.js` files from the vault's sources folder:

```js
import { pages } from "./lib/github.js"
import { slug } from "../shared/names.js"
```

A name that starts with `.` is taken from beside the file importing it.
What can be imported is a `.js` file under the sources folder that is not
itself a source; nothing outside the folder, and nothing from the web. An
imported file sees the same `http`, `vault` and the rest as the source
that imported it, and can do no more than that source was approved for.

Imported files are read as they are when the run starts, like the script
itself. For that reason a source that is given a secret cannot import:
its script runs only as approved, and an imported file would not be.

## Limits

A run is stopped after three minutes, after a fixed amount of computation,
or at 64 MB of memory. It may make 50 requests of at most 5 MB each,
write 2,000 notes and import 50 files. A source runs once at a time. A
run that fails, or is cut short by a restart, is simply run again at its
next time; `vault.item` does nothing the second time, so that is safe.

Requests go only to the source's hosts, over https, and only when the host
is on the open internet. The operator can name hosts on the server's own
network in `BABELSYNC_SOURCES_PRIVATE_HOSTS`; those may be approved like
any other and may use plain http.

A source writes as the person who approved it. If they leave the vault it
stops being able to write until someone else approves it.

## Turning it off

`BABELSYNC_SOURCES=off` removes the page and runs nothing. It is the
default when `BABELSYNC_MODE=multi`.
