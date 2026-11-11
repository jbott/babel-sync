# BabelSync

A self-hosted live-sync server for [Obsidian](https://obsidian.md) vaults.

- **Live sync** between devices through an Obsidian plugin, desktop and mobile. Notes are merged character by character (a CRDT, [Yjs](https://yjs.dev)), so two devices editing the same note, online or offline, never overwrite each other.
- **Web app** to browse, read and edit vaults, with live cursors when several people are in the same note.
- **MCP server** at `/mcp` so agents can list, read, search, write and move notes.
- **Attachments** of any size, uploaded in resumable 8 MiB parts.
- **History and trash** for notes and attachments, kept for a configurable number of days.
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

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BABELSYNC_MODE` | `single` | `single` for one owner, `multi` for accounts and shared vaults |
| `BABELSYNC_STORAGE` | `local` in single mode, `remote` in multi | `local` is SQLite plus a directory; `remote` is PostgreSQL plus S3 |
| `BABELSYNC_AUTH` | `none` in single mode, `oidc` in multi | Comma-separated: `oidc`, `passkey`, `magic_link`; or `none` (single mode only) |
| `BABELSYNC_URL` | `http://localhost:$PORT` | The address people use. Sign-in links, passkeys and OAuth depend on it |
| `BABELSYNC_BIND` | `local` when sign-in is off, else `all` | Listen on localhost only, or on every interface |
| `BABELSYNC_DATA_DIR` | required in production | Where local mode keeps its database and attachments |
| `BABELSYNC_RETENTION_DAYS` | `30` | How long history and trash are kept; `0` keeps them forever |
| `BABELSYNC_MAX_BLOB_BYTES` | 5 GiB | Largest attachment accepted |
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

- `none`: no sign-in. The server listens on localhost only unless `BABELSYNC_BIND=all`.
- `passkey`: on first start the log prints a one-time setup address. Open it to register your passkey; more can be added on the account page.
- `oidc`: sign in with one identity at your provider, named by `BABELSYNC_OIDC_REQUIRE`.

## Obsidian plugin

```sh
cd plugin && npm run build
```

Copy `main.js` and `manifest.json` into `<vault>/.obsidian/plugins/babelsync/`, enable the plugin, then in its settings enter the server address, sign in, and pick a vault. Signing in opens the server's consent page in a browser and returns to Obsidian.

Notes sync as you type. Themes, snippets, hotkeys and plugins under `.obsidian` sync too (this can be turned off); window layout stays per device. On mobile, attachments over 50 MiB are left on the server by default.

## Agents (MCP)

Add `$BABELSYNC_URL/mcp` to an MCP client as a Streamable HTTP server. The client registers itself and sends you to the consent page; approved agents are listed on the account page, where each can be disconnected. An agent that asks for the `vault:read` scope cannot change anything.

## Development

```sh
mix precommit                        # compile without warnings, format, test (SQLite, no services)
bin/dev-services up
BABELSYNC_STORAGE=remote mix test    # the same suite on PostgreSQL and S3
mix dialyzer
```

The end-to-end tests run the JavaScript client and two copies of the plugin's sync engine against the real server under Node. When Chrome or Chromium is installed (or `CHROME_BIN` names one) they also drive the web app in a headless browser: two tabs editing one note, uploads, rename, history, trash, and passkey sign-in through a virtual authenticator. Without a browser those tests are skipped.

The plugin can be exercised inside Obsidian itself. With a server running and an empty vault on it:

```sh
npm run build -w plugin
BABELSYNC_URL=http://localhost:4000 node plugin/test/real-obsidian.mjs
```

This opens two Obsidian windows on throwaway profiles and vaults in the temp directory, never your own, installs the plugin in both, signs in, and checks live typing, cursors, attachments, renames, deletions, settings sync, catching up after being off, and Obsidian's mobile emulation. `OBSIDIAN_BIN` points at the Obsidian executable when it is not in `/Applications`.

Layout: `lib/babel_sync` is the server core, `lib/babel_sync_web` the web app, channels and HTTP API, `js/core` the sync client shared by the web editor and the plugin, `plugin` the Obsidian plugin.

### Not yet verified

The plugin has not been run on a real phone or tablet, only under Obsidian's mobile emulation on the desktop.
