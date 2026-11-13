# Babel Sync

A self-hosted live-sync server for [Obsidian](https://obsidian.md) vaults.

- **Live sync** between devices through an Obsidian plugin, desktop and mobile. Notes are merged character by character (a CRDT, [Yjs](https://yjs.dev)), so two devices editing the same note, online or offline, never overwrite each other.
- **Web app** to browse, read and edit vaults, with live cursors when several people are in the same note. Reading view renders Obsidian's Markdown: properties, callouts, embedded notes and sections, links to headings and blocks, tags, highlights, comments, math and Mermaid diagrams. PDFs open in place. Canvases and bases open in reading view. A canvas is drawn as its board of cards and arrows, which you can pan and zoom by dragging, scrolling or pinching, and a base is shown with a tab for each view: a table of its notes, grouped as the view says, or for map views a map of them, drawn as Obsidian's Maps plugin draws it, with OpenFreeMap's tiles.
- **MCP server** at `/mcp` that gives agents the vault as a file system: list, find, search, read by line range, edit in place, move, trash and restore.
- **Attachments** of any size, uploaded in resumable 8 MiB parts.
- **History and trash** for notes and attachments, kept for a configurable number of days. Each saved version of a note shows what it changed, word by word, or everything since then, in the web app and in a version history pane in Obsidian (the Show version history command, or Version history in a note's menu).
- **One user or many**: a single-user server on a disk, or a multi-user server on PostgreSQL and S3 with shared vaults and owner, editor and viewer roles.

## Run it

Everything runs inside the Nix dev shell (`nix develop`, or `direnv allow` once).

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>. With no configuration this is a single-user server with sign-in turned off, storing its data under `.dev/data`.

To try multi-user mode locally, `bin/dev-services up` starts PostgreSQL and an S3-compatible server, then:

```sh
BABELSYNC_MODE=multi BABELSYNC_AUTH=magic_link BABELSYNC_ALLOWED_EMAILS='*' mix phx.server
```

Sign-in mail lands in the development mailbox at <http://localhost:4000/dev/mailbox>.

## Package it

The flake builds the production release and a container image without touching the network after its dependencies are fetched.

```sh
nix build                 # the release, at ./result/bin/babel_sync
nix build .#container     # a Linux image for this machine's CPU, built with nix2container
nix run .#container.copyTo -- docker-archive:babelsync.tar:babelsync:0.1.0
docker load -i babelsync.tar
docker run -p 127.0.0.1:4000:4000 -v babelsync:/data babelsync:0.1.0
```

On macOS the image is built by a Linux builder (`nix.linux-builder` or any remote builder). The image runs as an unprivileged user, keeps everything under `/data`, and listens on all of the container's interfaces, so who can reach it is decided by how the port is published. Sign-in is by passkey: the first start prints a one-time setup address to the log (`docker logs`). `SECRET_KEY_BASE` is generated on first start and kept in `/data` unless you set it. All the settings below are passed with `-e`.

Run one copy of the server per database. Each open note is kept by one process on the server it was opened on, and two copies sharing a database would each keep their own, so typing on one would not reach people on the other, and each would save over what the other had saved.

Each Mix dependency is its own Nix derivation, listed in `nix/deps.nix`, so a build only compiles what changed. When `mix.lock` changes, regenerate that file with `mix deps.nix --output nix/deps.nix`. The npm dependencies and the crates of the two Rust extensions are still pinned by hash in `nix/package.nix`: clear the stale one to `""`, build, and paste the hash Nix prints.

## Running it

- **HTTPS.** Passkeys, Claude and ChatGPT connectors, and phones on other networks all need the server at an `https://` address. Put it behind a reverse proxy that terminates TLS (Caddy, nginx, Traefik) on the same machine, and set `BABELSYNC_URL` to the public address. The server redirects plain HTTP to HTTPS only when `BABELSYNC_URL` is an `https://` address, and believes the proxy's `X-Forwarded-Proto` only when the proxy connects from the same machine. A server at a plain `http://` address on a home network works for the plugin and the web app, but not for passkeys.
- **Backups.** In local mode, `babel_sync eval 'BabelSync.Backup.run("/backups/babelsync")'` writes a consistent snapshot of the database next to a copy of the attachments, while the server runs; run it from cron, with `keep: 14` as a second argument to keep only the newest fourteen snapshots. Copying `babel_sync.db` itself can catch it half written. To restore, stop the server, move any database out of the data directory, and run `babel_sync eval 'BabelSync.Backup.restore("/backups/babelsync")'`, which puts the newest snapshot and the attachments back. In remote mode, use `pg_dump` for the database and the bucket's own versioning or replication for attachments. Any vault can also be downloaded as a ZIP of plain files from its settings page.
- **Upgrades.** Database migrations run when the server starts. Take a backup first.
- **Health.** `GET /health` answers 200 while the database does and 503 when it does not.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BABELSYNC_MODE` | `single` | `single` for one owner, `multi` for accounts and shared vaults |
| `BABELSYNC_STORAGE` | `local` in single mode, `remote` in multi | `local` is SQLite plus a directory; `remote` is PostgreSQL plus S3 |
| `BABELSYNC_AUTH` | `none` in single mode, `oidc` in multi | Comma-separated: `oidc`, `passkey`, `magic_link`; or `none` (single mode only) |
| `BABELSYNC_URL` | `http://localhost:$PORT` | The address people use. Sign-in links, passkeys and OAuth depend on it |
| `BABELSYNC_BIND` | `local` when sign-in is off, else `all` | Listen on localhost only, or on every interface |
| `BABELSYNC_TRUST_NETWORK` | unset | Set to `true` to allow `BABELSYNC_BIND=all` with sign-in off. Anyone who can reach the port can then read and change every note |
| `BABELSYNC_DATA_DIR` | required in production | Where local mode keeps its database and attachments |
| `BABELSYNC_RETENTION_DAYS` | `30` | How long history and trash are kept; `0` keeps them forever |
| `BABELSYNC_MAX_BLOB_BYTES` | 5 GiB | Largest attachment accepted |
| `BABELSYNC_VAULT_QUOTA_BYTES` | none | Most attachment bytes one vault may hold; a new attachment that would pass it is refused |
| `SECRET_KEY_BASE` | required in production | `mix phx.gen.secret` |
| `PORT` | `4000` | HTTP port |

Remote storage:

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | `ecto://user:pass@host/database` |
| `BABELSYNC_S3_ENDPOINT`, `BABELSYNC_S3_BUCKET`, `BABELSYNC_S3_REGION` | Where attachments go |
| `BABELSYNC_S3_ACCESS_KEY_ID`, `BABELSYNC_S3_SECRET_ACCESS_KEY` | Credentials for it |

Sign-in:

| Variable | Meaning |
|---|---|
| `BABELSYNC_OIDC_ISSUER`, `BABELSYNC_OIDC_CLIENT_ID`, `BABELSYNC_OIDC_CLIENT_SECRET` | The OpenID Connect provider. Register `$BABELSYNC_URL/login/oidc/callback` as the redirect address |
| `BABELSYNC_OIDC_REQUIRE` | Claims a person must have, as `claim=value,claim=value`. Required in single mode, for example `email=you@example.com` |
| `BABELSYNC_OIDC_LABEL`, `BABELSYNC_OIDC_SCOPES` | Button text (default "single sign-on") and scopes (default `openid email profile`) |
| `BABELSYNC_ALLOWED_EMAILS` | Who may sign in by emailed link without already having an account: addresses, `*@domain`, or `*` |
| `BABELSYNC_SMTP_HOST`, `_PORT`, `_USERNAME`, `_PASSWORD`, `BABELSYNC_MAIL_FROM` | Mail server for sign-in links |

### Signing in on a single-user server

- `none`: no sign-in. The server listens on localhost only, and answers only requests addressed to its own host name, so a web page cannot reach it by pointing its own domain at your machine. Listening on every interface without sign-in needs `BABELSYNC_TRUST_NETWORK=true` as well.
- `passkey`: on first start the log prints a one-time setup address. Open it to register your passkey; more can be added on the account page.
- `oidc`: sign in with one identity at your provider, named by `BABELSYNC_OIDC_REQUIRE`.

## Obsidian plugin

The server hands out its own copy of the plugin, so a device is set up from the server it will sync with. Open a vault in the web app and choose **Connect Obsidian**:

1. **Get the plugin onto the device, once.** Download the vault folder (the plugin is inside, switched on and already pointed at the vault) and open it in Obsidian, or download the plugin alone and unzip it into an existing vault's `.obsidian/plugins/` folder, then enable it under Community plugins. Obsidian can install a plugin from a link only when it is in the community directory, and Babel Sync is not there yet. A device that already syncs fetches new builds of the plugin from the server and offers to reload into them.
2. **Tap Open in Obsidian.** The link (`obsidian://babelsync-connect?server=…&id=…`) opens Obsidian, which asks whether to sync the open vault with that server vault, then sends you to the server's consent page to approve the device. Nothing is typed and nothing is picked from a list.

The same can be done by hand in Settings › Babel Sync, which shows the next step at the top: enter the server address, sign in, choose a vault.

A release built with Nix or `mix assets.deploy` includes the plugin. In development, `mix plugin.build` (part of `mix assets.build`) builds it into `priv/plugin`.

Notes sync as you type. Themes, snippets, hotkeys and plugins under `.obsidian` sync too (this can be turned off); window layout stays per device. In a shared vault only an owner can change `.obsidian/plugins`, since a plugin is code that would run on every member's devices: an owner's plugins sync between the owner's own devices, and other members install their own. On mobile, attachments over 50 MiB are left on the server by default.

## Agents (MCP)

Add `$BABELSYNC_URL/mcp` to an MCP client as a Streamable HTTP server. The client registers itself and sends you to the consent page; approved agents are listed on the account page, where each can be disconnected. An agent that asks for the `vault:read` scope cannot change anything.

Apps register themselves without signing in, so registration is bounded: a redirect address is at most 2000 bytes and must be `https`, loopback `http` or an app scheme such as `obsidian://`; one address may register 30 apps an hour; and a registration nobody approves is forgotten after a day.

Agents cannot see or change the `.obsidian` folder, which holds the plugins Obsidian runs. An owner can open it to agents per vault, in the vault's settings. Even then, the plugins themselves can only be changed by an agent acting for an owner.

Any file that holds text can be read, searched, edited and written by an agent, whatever its extension. Markdown, `.txt`, `.base` and `.canvas` files are notes, merged character by character with what people type; other text files such as `.csv` or `.json` are edited by an agent in the same way, passage by passage, but are stored as attachments, so a change made by a person at the same moment is not merged with the agent's. Images are shown to the agent. An agent without a shell can still move any file of up to 8 MiB: `write_file` takes its bytes as base64, and `read_file` with `encoding: "base64"` returns them.

Any file, note or attachment, can also move outside the conversation. `upload_file` and `download_file` return an HTTPS link, and the agent moves the bytes with `curl` from a shell, up to the attachment size limit. A link carries only a random handle; who may use it, for which vault and file, is kept on the server, so a link in a log or transcript says nothing about the vault. Links last an hour, an upload link works once and only for the size it was made for, and access to the vault is checked again when a link is used. An upload is staged in the data directory, then stored in parts like any device's upload (a multipart upload on S3), so the server needs free disk as large as the file while it arrives. The replies also carry the links in the shape of the draft `io.modelcontextprotocol/files` extension's upload and download targets.

The agent gets the vault as a file system:

| Tool | What it does |
| --- | --- |
| `list_vaults`, `list_directory`, `find_files` | Look around: folders with file counts, files by path pattern (`Projects/**/*.md`) |
| `search_files` | Search note text, plain or regular expression, with line numbers and context; includes what is being typed right now |
| `query_notes`, `list_properties` | Treat notes as a table of their properties, like an Obsidian base: filter with a Bases expression, keep notes within a distance of a point, sort, count by a value, or run a `.base` file's own filters, formulas and views |
| `file_outline`, `read_file` | Headings and properties with line numbers, then any line range; image attachments are shown as images |
| `edit_file`, `append_file` | Replace exact passages, or add to the end of a note or of the section under a heading |
| `write_file` | Create a note, or replace a whole one |
| `upload_file`, `download_file` | A link to PUT or GET any file's bytes with curl, for files too large for a tool call or kept on a disk the agent can reach |
| `create_directory`, `move_file`, `delete_file` | Folders move and are deleted with their contents; deleted files go to the trash |
| `list_trash`, `restore_file`, `file_history` | Bring back deleted files and earlier versions of a note |
| `list_changes` | What was written or deleted since a cursor |

Edits are applied inside the note's live document on the server, as the smallest insertions and deletions that make the change. An agent sends only the passage it changes, does not need to read the note first, and does not disturb what people are typing elsewhere in it. Every read returns a `rev` that names the note's exact text; replacing a whole note requires that rev and is refused if the note has changed since, so a person's edit is never undone by an agent working from an old copy.

## Development

```sh
mix precommit                        # compile without warnings, format, test (SQLite, no services)
bin/dev-services up
BABELSYNC_STORAGE=remote mix test    # the same suite on PostgreSQL and S3
mix dialyzer
```

The end-to-end tests run the JavaScript client and two copies of the plugin's sync engine against the real server under Node. When Chrome or Chromium is installed (or `CHROME_BIN` names one) they also drive the web app in a headless browser: two tabs editing one note, uploads, rename, history, trash, and passkey sign-in through a virtual authenticator. Without a browser those tests are skipped. The MCP server is driven by the official `@modelcontextprotocol/sdk` client, alone and while a note is being typed in.

The plugin can be exercised inside Obsidian itself. With a server running and an empty vault on it:

```sh
npm run build -w plugin
BABELSYNC_URL=http://localhost:4000 node plugin/test/real-obsidian.mjs
```

This opens two Obsidian windows on throwaway profiles and vaults in the temp directory, never your own, installs the plugin in both, signs in, and checks live typing, cursors, an agent editing over MCP and a web editor on the same open note, attachments, renames, deletions, settings sync, catching up after being off, and Obsidian's mobile emulation. `OBSIDIAN_BIN` points at the Obsidian executable when it is not in `/Applications`.

Layout: `lib/babel_sync` is the server core, `lib/babel_sync_web` the web app, channels and HTTP API, `js/core` the sync client shared by the web editor and the plugin, `plugin` the Obsidian plugin.

### Not yet verified

The plugin has not been run on a real phone or tablet, only under Obsidian's mobile emulation on the desktop.
