# Sources

A source is a script, kept as a note in a vault, that the server runs to
bring outside data into notes: starred repositories, liked posts, papers,
devices. The note is yours to read and change. What it may do is written at
the top of the note, and nothing runs until a vault owner has approved it.

## Writing one

Any Markdown note whose properties say `type: source` is a source. The
properties are what it asks to be allowed; the first `js` code block is the
script; the rest of the note is for people.

````markdown
---
type: source
schedule: every 6h
hosts:
  - api.github.com
secrets:
  github: { host: api.github.com, header: "Authorization: Bearer {}" }
writes:
  - Github/Stars
params:
  user: octocat
---
Keeps one note per starred repository.

```js
const res = http.get(`https://api.github.com/users/${params.user}/starred`)
for (const repo of res.json()) {
  vault.item(repo.html_url, {
    path: `Github/Stars/${vault.name(repo.full_name)}.md`,
    match: { url: repo.html_url },
    properties: { url: repo.html_url, stars: repo.stargazers_count },
    body: `# ${repo.name}\n`,
  })
}
```
````

| Property | Meaning |
|---|---|
| `schedule` | `every 30m`, `every 6h`, `every 1d`; no more often than every 5 minutes. Left out, the source runs only when asked |
| `hosts` | Host names the script may fetch from. `*.example.com` allows every name under one |
| `secrets` | For each name, the host it goes to and the header it is sent in, with `{}` where the secret goes |
| `writes` | Folders the script may make and change notes in |
| `reads` | Further folders it may read |
| `params` | Anything; the script sees it as `params` |

A property that is not in this table is refused, so a misspelt one is not
quietly ignored.

### As a JavaScript file

A source can instead be a file whose name ends in `.source.js`, which is
easier to work on in a code editor or to hand to an agent. The whole file
is the script, and it opens with a comment holding the same properties as
YAML:

```js
/* source
schedule: every 6h
hosts: [api.github.com]
writes: [Github/Stars]
params:
  user: octocat
*/
const res = http.get(`https://api.github.com/users/${params.user}/starred`)
```

Everything else is the same either way, and line numbers in an error are
the file's own.

## Approving

Vault settings, Sources lists every source note in the vault with what it
asks for and its code. Approving copies that into the server's database,
and the copy is what runs.

Editing the note afterwards changes nothing that runs. The page shows what
differs, and the approved script keeps running until the change is
approved too. This is what makes it safe to keep the script where every
synced device and every agent with write access can change it: approving
takes a vault owner signed in through the browser, and neither an agent's
grant nor a device is that.

The source is tied to the note, not its path, so the note can be renamed
or moved. Deleting the note stops the schedule.

Secrets are entered on the same page. They are stored encrypted under the
server's `SECRET_KEY_BASE` and never shown again.

## What a script can do

The script is JavaScript run by QuickJS inside WebAssembly. It has the
language and the following, and nothing else: no files, no sockets, no
timers, no modules.

| | |
|---|---|
| `http.get(url, { headers })`, `http.post(url, { headers, body })`, also `put`, `patch`, `delete`, `head` | A request to one of the source's hosts. Returns `status`, `ok`, `headers`, `url`, `text()`, `json()` and `next`, the next page's address when the answer has a `Link` header naming one |
| `vault.item(key, { path, match, properties, body })` | Makes or updates the note for one outside thing; see below |
| `vault.read(path)` | A note's text, or `null` |
| `vault.list(folder)` | The paths in a folder |
| `vault.name(text)` | The text with the characters a file name cannot hold taken out |
| `state.get(name)`, `state.set(name, value)` | Small things to remember between runs, such as a cursor or an ETag. Saved only when the run ends without an error |
| `log(...)` | A line in the run's log |
| `attention(message, { url })` | Asks the owner to do something, such as sign in again. Shown on the Sources page; the link must be https and on one of the source's hosts |
| `params`, `trigger` | The note's `params`, and what started the run: `schedule` or `manual` |

A call that is refused throws, with the reason as the message.

### `vault.item`

`key` is the script's own name for the thing, such as its web address. The
server remembers which note belongs to each key.

- The first time a key is seen, an existing note is taken over if `match`
  names a property and value that one note in the source's folders has, or
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

## Limits

A run is stopped after three minutes, after a fixed amount of computation,
or at 64 MB of memory. It may make 50 requests of at most 5 MB each and
write 2,000 notes. A source runs once at a time. A run that fails, or is
cut short by a restart, is simply run again at its next time; `vault.item`
does nothing the second time, so that is safe.

Requests go only to the source's hosts, over https, and only when the host
is on the open internet. The operator can name hosts on the server's own
network in `BABELSYNC_SOURCES_PRIVATE_HOSTS`; those may be approved like
any other and may use plain http.

A source writes as the person who approved it. If they leave the vault it
stops being able to write until someone else approves it.

## Turning it off

`BABELSYNC_SOURCES=off` removes the page and runs nothing. It is the
default when `BABELSYNC_MODE=multi`.
