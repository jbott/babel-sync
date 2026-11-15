defmodule BabelSync.SourcesTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Repo, Sources, Sync, Vaults}
  alias BabelSync.Sources.{Item, Items, Scheduler, Secrets, Source}

  defmodule Site do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(%Plug.Conn{request_path: "/stars"} = conn, _options) do
      token = conn |> get_req_header("authorization") |> List.first()
      stars = Application.get_env(:babel_sync, __MODULE__, [])

      conn
      |> put_resp_header("x-token", token || "none")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(stars))
    end
  end

  @script """
  const res = http.get(params.site + "/stars")
  state.set("runs", (state.get("runs") || 0) + 1)
  log("token", res.headers["x-token"])
  for (const repo of res.json()) {
    vault.item(repo.url, {
      path: `${vault.name(repo.name)}.md`,
      match: { url: repo.url },
      properties: { url: repo.url, stars: repo.stars, tags: ["type/star", ...repo.topics] },
      body: `# ${repo.name}\\n`,
    })
  }
  """

  defp note(site, code \\ @script, extra \\ "") do
    """
    /* source
    schedule: every 1h
    hosts: ["127.0.0.1"]
    params:
      site: #{site}
    #{extra}*/
    #{code}
    """
  end

  defp stars(stars), do: Application.put_env(:babel_sync, Site, stars)

  defp star(name, stars, topics \\ []),
    do: %{name: name, url: "https://example.com/#{name}", stars: stars, topics: topics}

  setup do
    server = start_supervised!({Bandit, plug: Site, scheme: :http, port: 0, ip: :loopback})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    limits = Application.fetch_env!(:babel_sync, Sources)
    Application.put_env(:babel_sync, Sources, Keyword.put(limits, :private_hosts, ["127.0.0.1"]))

    on_exit(fn ->
      Application.put_env(:babel_sync, Sources, limits)
      Application.delete_env(:babel_sync, Site)
    end)

    owner = user()
    {:ok, vault} = Vaults.update_vault(vault(owner), %{sources_folder: "Data"})
    admin = Scope.for_user(owner, session_id: Ecto.UUID.generate())
    site = "http://127.0.0.1:#{port}"
    {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Data/Stars.js", note(site))

    %{owner: owner, vault: vault, admin: admin, site: site}
  end

  defp draft(vault), do: vault.id |> Sources.drafts() |> List.first()

  defp approved(%{vault: vault, admin: admin}) do
    %{entry: entry, script: {:ok, script}} = draft(vault)
    {:ok, source} = Sources.approve(admin, entry.id, Sources.Script.hash(script))
    source
  end

  defp rewritten(%{owner: owner, vault: vault}, text) do
    entry = Vaults.get_entry_by_path(vault.id, "Data/Stars.js")

    {:ok, _} =
      Agent.write_file(Scope.for_user(owner), vault.id, entry.path, text, overwrite: true)

    draft(vault)
  end

  defp run(source, trigger \\ "manual") do
    Sources.enqueue(source, trigger)
    [{run, claimed}] = Scheduler.claim(DateTime.utc_now())
    Scheduler.carry_out(run, claimed)
  end

  defp text(vault, path), do: Sync.text(Vaults.get_entry_by_path(vault.id, path).id)

  describe "approval" do
    test "a source note is a draft until an admin approves it", %{vault: vault} = context do
      assert %{status: :new, name: "Stars", source: nil} = draft(vault)

      approved(context)

      assert %{status: :approved, source: %Source{}} = draft(vault)
    end

    test "only an admin in a browser session may approve", %{vault: vault, owner: owner} do
      %{entry: entry, script: {:ok, script}} = draft(vault)
      hash = Sources.Script.hash(script)
      editor = user()
      Vaults.put_member(vault, editor, :editor)
      methods = Application.fetch_env!(:babel_sync, :auth)
      Application.put_env(:babel_sync, :auth, [:passkey])
      on_exit(fn -> Application.put_env(:babel_sync, :auth, methods) end)

      refused = [
        Scope.for_user(owner),
        Scope.for_user(owner, grant_id: Ecto.UUID.generate()),
        Scope.for_user(owner, session_id: Ecto.UUID.generate(), grant_id: Ecto.UUID.generate()),
        Scope.for_user(owner, session_id: Ecto.UUID.generate(), read_only: true),
        Scope.for_user(editor, session_id: Ecto.UUID.generate())
      ]

      for scope <- refused do
        assert {:error, :forbidden} = Sources.approve(scope, entry.id, hash)
      end

      assert Sources.list(vault.id) == []
    end

    test "approving what was not the text looked at is refused", %{vault: vault, admin: admin} do
      %{entry: entry} = draft(vault)

      assert {:error, :changed} = Sources.approve(admin, entry.id, "something else")
    end

    test "an edited script runs as edited, with no more than was approved",
         %{vault: vault, site: site} = context do
      source = approved(context)

      code = """
      vault.item("x", { path: "edited.md", body: "!" })
      try { http.get("https://example.com/") } catch (error) { log(error.message) }
      """

      assert %{status: :approved} = rewritten(context, note(site, code))
      assert %{status: :done, created: 1, log: log} = run(source)
      assert log =~ "not a host this source may reach"
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/edited.md")
    end

    test "a script that asks for more runs as it was until approved again",
         %{vault: vault, site: site} = context do
      source = approved(context)
      stars([star("one", 1)])
      code = ~s|vault.item("x", { path: "more.md", body: "!" })\n|

      assert %{status: :changed} = rewritten(context, note(site, code, "reads: [Private]\n"))
      assert %{status: :done, created: 1} = run(source)
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
      refute Vaults.get_entry_by_path(vault.id, "Data/Stars/more.md")
    end

    test "a script given a secret runs only as approved",
         %{vault: vault, site: site, admin: admin} = context do
      extra = ~s|secrets:\n  token: { host: "127.0.0.1", header: "Authorization: Bearer {}" }\n|
      %{entry: entry, script: {:ok, script}} = rewritten(context, note(site, @script, extra))
      {:ok, source} = Sources.approve(admin, entry.id, Sources.Script.hash(script))
      stars([star("one", 1)])
      code = ~s|vault.item("x", { path: "edited.md", body: "!" })\n|

      assert %{status: :changed} = rewritten(context, note(site, code, extra))
      assert %{status: :done, created: 1} = run(source)
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
      refute Vaults.get_entry_by_path(vault.id, "Data/Stars/edited.md")
    end

    test "a source moved to another name asks again, for where it now writes",
         %{vault: vault, owner: owner} = context do
      approved(context)
      {:ok, _} = Agent.move_file(Scope.for_user(owner), vault.id, "Data/Stars.js", "Data/Mine.js")

      assert %{status: :changed, name: "Mine", script: {:ok, %{writes: ["Data/Mine"]}}} =
               draft(vault)
    end

    test "a source moved out of the sources folder does not run",
         %{vault: vault, owner: owner} = context do
      source = approved(context)

      {:ok, _} =
        Agent.move_file(Scope.for_user(owner), vault.id, "Data/Stars.js", "Other/Stars.js")

      assert Sources.drafts(vault.id) == []
      assert %{status: :failed, error: error} = run(source)
      assert error =~ "sources folder"
      assert Scheduler.queue_due(DateTime.add(DateTime.utc_now(), 2, :hour)) == []
    end

    test "a .js file without the opening comment is not a source",
         %{vault: vault, owner: owner} do
      {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Data/lib.js", "log(1)\n")

      assert [%{name: "Stars"}] = Sources.drafts(vault.id)
    end

    test "a vault with no sources folder has no sources", %{vault: vault} do
      {:ok, vault} = Vaults.update_vault(vault, %{sources_folder: nil})

      assert Sources.drafts(vault.id) == []
    end
  end

  describe "a run" do
    test "makes a note for each thing and records what it did", %{vault: vault} = context do
      source = approved(context)
      stars([star("one", 1, ["topic/a"]), star("two", 2)])

      assert %{status: :done, created: 2, changed: 0, error: nil, log: "token none\n"} =
               run(source)

      assert text(vault, "Data/Stars/one.md") ==
               "---\nurl: https://example.com/one\nstars: 1\ntags:\n  - type/star\n  - topic/a\n---\n# one\n"

      assert Jason.decode!(Sources.get(source.id).state) == %{"runs" => 1}
    end

    test "run again with nothing new, writes nothing", %{vault: vault} = context do
      source = approved(context)
      stars([star("one", 1), star("two", 2)])
      run(source)
      seq = Vaults.get_vault(vault.id).seq

      assert %{status: :done, created: 0, changed: 0, unchanged: 2} = run(source)
      assert Vaults.get_vault(vault.id).seq == seq
    end

    test "changes only the properties that differ and keeps what people wrote",
         %{vault: vault, owner: owner} = context do
      source = approved(context)
      stars([star("one", 1, ["topic/a"])])
      run(source)

      {:ok, _} =
        Agent.edit_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md", [
          %{old_text: "  - topic/a\n", new_text: "  - topic/a\n  - mine\nrating: 5\n"},
          %{old_text: "# one\n", new_text: "# one\n\nMy notes.\n"}
        ])

      stars([star("one", 7, ["topic/b"])])

      assert %{status: :done, changed: 1} = run(source)

      assert text(vault, "Data/Stars/one.md") ==
               "---\nurl: https://example.com/one\nstars: 7\ntags:\n  - type/star\n  - topic/b\n  - mine\nrating: 5\n---\n# one\n\nMy notes.\n"
    end

    test "follows a note that was renamed", %{vault: vault, owner: owner} = context do
      source = approved(context)
      stars([star("one", 1)])
      run(source)

      {:ok, _} =
        Agent.move_file(
          Scope.for_user(owner),
          vault.id,
          "Data/Stars/one.md",
          "Data/Stars/Kept/first.md"
        )

      stars([star("one", 2)])

      assert %{changed: 1, created: 0} = run(source)
      assert text(vault, "Data/Stars/Kept/first.md") =~ "stars: 2"
      refute Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
    end

    test "does not bring back a note that was deleted", %{vault: vault, owner: owner} = context do
      source = approved(context)
      stars([star("one", 1)])
      run(source)
      {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md")

      assert %{status: :done, created: 0, changed: 0} = run(source)
      assert %{status: :done, created: 0} = run(source)
      refute Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
      assert Repo.get_by(Item, source_id: source.id).gone
    end

    test "keeps a deleted note up again once it is restored from the trash",
         %{vault: vault, owner: owner} = context do
      source = approved(context)
      stars([star("one", 1)])
      run(source)
      {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md")
      run(source)

      {:ok, _} = Agent.restore_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md")
      stars([star("one", 2)])

      assert %{status: :done, created: 0, changed: 1} = run(source)
      assert text(vault, "Data/Stars/one.md") =~ "stars: 2"
      refute Repo.get_by(Item, source_id: source.id).gone
    end

    test "lists the notes it keeps and the ones deleted, and restores a deleted one",
         %{vault: vault, owner: owner, admin: admin} = context do
      source = approved(context)
      stars([star("one", 1), star("two", 2)])
      run(source)
      {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md")

      assert %{all: 2, current: 1, deleted: 1} = Items.counts(source, "")
      assert %{all: 1, current: 1, deleted: 0} = Items.counts(source, "TWO")
      assert [{item, %{path: "Data/Stars/one.md"}}] = Items.list(source, :deleted, "", 10)
      assert [{_two, %{path: "Data/Stars/two.md"}}] = Items.list(source, :current, "", 10)

      assert {:error, :forbidden} = Sources.reinstate(Scope.for_user(user()), source, item.id)
      assert {:ok, :restored} = Sources.reinstate(admin, source, item.id)
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
      assert %{current: 2, deleted: 0} = Items.counts(source, "")
      assert {:error, :not_found} = Sources.reinstate(admin, source, item.id)
    end

    test "makes a deleted note anew once it has left the trash and is asked for again",
         %{vault: vault, owner: owner, admin: admin} = context do
      source = approved(context)
      stars([star("one", 1)])
      run(source)
      {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Stars/one.md")
      run(source)
      Vaults.purge_trash(DateTime.add(DateTime.utc_now(), 60))

      assert [{item, nil}] = Items.list(source, :deleted, "", 10)
      assert %{status: :done, created: 0} = run(source)
      assert {:ok, :forgotten} = Sources.reinstate(admin, source, item.id)
      assert %{status: :done, created: 1} = run(source)
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
    end

    test "takes over a note that already holds the thing",
         %{vault: vault, owner: owner} = context do
      source = approved(context)

      {:ok, _} =
        Agent.write_file(
          Scope.for_user(owner),
          vault.id,
          "Data/Stars/Old name.md",
          "---\nurl: https://example.com/one\nstars: 0\nmine: yes\n---\nKept body.\n"
        )

      stars([star("one", 3)])

      assert %{created: 0, changed: 1} = run(source)

      assert text(vault, "Data/Stars/Old name.md") ==
               "---\nurl: https://example.com/one\nstars: 3\nmine: yes\ntags:\n  - type/star\n---\nKept body.\n"
    end

    test "sends a secret to its host without the script holding it",
         %{vault: vault, owner: owner, site: site, admin: admin} = context do
      extra = ~s|secrets:\n  token: { host: "127.0.0.1", header: "Authorization: Bearer {}" }\n|

      code =
        ~s|const res = http.get(params.site + "/stars"); log(res.headers["x-token"], JSON.stringify(res.headers))\n|

      {:ok, _} =
        Agent.write_file(
          Scope.for_user(owner),
          vault.id,
          "Data/Stars.js",
          note(site, code, extra),
          overwrite: true
        )

      source = approved(context)
      :ok = Sources.put_secret(admin, source, "token", "hunter2")
      stars([])

      assert %{status: :done, log: log} = run(source)
      assert log =~ "[secret]"
      refute log =~ "hunter2"
      assert Secrets.names(source) == ["token"]
      refute Repo.get_by(Sources.Secret, source_id: source.id).sealed =~ "hunter2"
    end

    test "is refused what it was not approved for",
         %{vault: vault, owner: owner, site: site} = context do
      code = """
      const tried = (name, attempt) => { try { attempt(); log(name, "allowed") } catch (error) { log(name, error.message) } }
      tried("host", () => http.get("https://example.com/"))
      tried("folder", () => vault.item("k", { path: "../Elsewhere/x.md" }))
      tried("config", () => vault.item("k", { path: "../../.obsidian/plugins/x/main.md" }))
      tried("read", () => vault.read("Data/Stars.js"))
      tried("link", () => attention("look", { url: "https://evil.example/" }))
      tried("unknown", () => __host("shell", "\\"rm\\""))
      """

      {:ok, _} =
        Agent.write_file(Scope.for_user(owner), vault.id, "Data/Stars.js", note(site, code),
          overwrite: true
        )

      assert %{status: :done, log: log} = run(approved(context))
      refute log =~ "allowed"
      assert length(String.split(log, "\n", trim: true)) == 6
    end

    test "a script that fails leaves what it remembered as it was",
         %{vault: vault, owner: owner, site: site} = context do
      source = approved(context)
      stars([])
      run(source)
      code = ~s|state.set("runs", 99); throw new Error("no good")\n|

      {:ok, _} =
        Agent.write_file(Scope.for_user(owner), vault.id, "Data/Stars.js", note(site, code),
          overwrite: true
        )

      source = approved(context)

      assert %{status: :failed, error: error} = run(source)
      assert error =~ "no good"
      assert Jason.decode!(Sources.get(source.id).state) == %{"runs" => 1}
    end

    test "stops writing when whoever approved it has left the vault",
         %{vault: vault, owner: owner} = context do
      source = approved(context)
      other = user()
      Vaults.put_member(vault, other, :owner)
      Vaults.remove_member(vault, owner)
      stars([star("one", 1)])

      assert %{status: :failed, error: error} = run(source)
      assert error =~ "approved"
      refute Vaults.get_entry_by_path(vault.id, "Data/Stars/one.md")
    end

    test "records a request for attention and clears it on the next clean run",
         %{vault: vault, owner: owner, site: site} = context do
      code =
        ~s|if (!state.get("asked")) { state.set("asked", true); attention("Sign in again", { url: "https://127.0.0.1/login" }) }\n|

      {:ok, _} =
        Agent.write_file(Scope.for_user(owner), vault.id, "Data/Stars.js", note(site, code),
          overwrite: true
        )

      source = approved(context)

      run(source)

      assert Jason.decode!(Sources.get(source.id).attention) == %{
               "message" => "Sign in again",
               "url" => "https://127.0.0.1/login"
             }

      run(source)
      assert Sources.get(source.id).attention == nil
    end
  end

  describe "scheduling" do
    test "queues a source when it is due and moves its next time on", context do
      source = approved(context)
      now = DateTime.utc_now()

      assert [%{trigger: "schedule"}] = Scheduler.queue_due(now)
      assert Scheduler.queue_due(now) == []
      assert DateTime.diff(Sources.get(source.id).next_run_at, now) == 3600
    end

    test "a paused source is not queued", %{admin: admin} = context do
      source = approved(context)
      :ok = Sources.set_enabled(admin, source, false)

      assert Scheduler.queue_due(DateTime.utc_now()) == []
    end

    test "a source whose note was deleted is not queued",
         %{vault: vault, owner: owner} = context do
      approved(context)
      {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Stars.js")

      assert Scheduler.queue_due(DateTime.utc_now()) == []
    end

    test "a source runs once at a time, whoever asks", context do
      source = approved(context)
      now = DateTime.utc_now()
      Sources.enqueue(source, "manual")
      Sources.enqueue(source, "manual")

      assert [{_run, _source}] = Scheduler.claim(now)
      assert Scheduler.claim(now) == []
    end

    test "a run left behind by a server that stopped is failed and the source freed", context do
      source = approved(context)
      now = DateTime.utc_now()
      Sources.enqueue(source, "manual")
      [{run, _source}] = Scheduler.claim(now)
      later = DateTime.add(now, 3600, :second)

      :ok = Scheduler.expire(later)

      assert %{status: :failed, error: "the server stopped while this was running"} =
               Repo.get(Sources.Run, run.id)

      Sources.enqueue(source, "manual")
      assert [{_run, _source}] = Scheduler.claim(later)
    end
  end

  describe "importing" do
    defp lib(%{owner: owner, vault: vault}, path, code) do
      {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, path, code)
    end

    test "a source uses other files in the sources folder",
         %{vault: vault, site: site} = context do
      lib(context, "Data/lib/names.js", ~s|export { tidy } from "./tidy.js"\n|)
      lib(context, "Data/lib/tidy.js", ~s|export const tidy = (name) => name.toUpperCase()\n|)

      code = """
      import { tidy } from "./lib/names.js"
      vault.item("one", { path: tidy("one") + ".md", body: "!" })
      """

      %{status: :new, entry: entry, script: {:ok, script}} = rewritten(context, note(site, code))
      {:ok, source} = Sources.approve(context.admin, entry.id, Sources.Script.hash(script))

      assert %{status: :done, created: 1, error: nil} = run(source)
      assert Vaults.get_entry_by_path(vault.id, "Data/Stars/ONE.md")
    end

    test "only from the sources folder, and never another source",
         %{vault: vault, owner: owner, site: site} = context do
      {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Private/keys.js", "1\n")
      lib(context, "Data/Zed.js", "/* source\n*/\nlog(1)\n")

      code = """
      const tried = async (name) => { try { await import(name); log(name, "allowed") } catch (error) { log(error.message) } }
      await tried("../Private/keys.js")
      await tried("./Zed.js")
      await tried("./missing.js")
      await tried("https://example.com/x.js")
      """

      %{entry: entry, script: {:ok, script}} = rewritten(context, note(site, code))
      {:ok, source} = Sources.approve(context.admin, entry.id, Sources.Script.hash(script))

      assert %{status: :done, log: log} = run(source)
      refute log =~ "allowed"
      assert log =~ "Private/keys.js is not a .js file in the vault's sources folder"
      assert log =~ "Data/Zed.js is a source"
      assert log =~ "Data/missing.js is not a file in the vault"
      assert length(String.split(log, "\n", trim: true)) == 4
    end

    test "a source given a secret cannot import", %{site: site} = context do
      lib(context, "Data/lib.js", "export const one = 1\n")
      extra = ~s|secrets:\n  token: { host: "127.0.0.1", header: "Authorization: Bearer {}" }\n|
      code = ~s|import { one } from "./lib.js"\nlog(one)\n|

      %{entry: entry, script: {:ok, script}} = rewritten(context, note(site, code, extra))
      {:ok, source} = Sources.approve(context.admin, entry.id, Sources.Script.hash(script))

      assert %{status: :failed, error: error} = run(source)
      assert error =~ "given a secret cannot import"
    end

    test "an error names the file and line it came from", %{site: site} = context do
      lib(context, "Data/lib.js", "export const fail = () => {\n  throw new Error('deep')\n}\n")
      code = ~s|import { fail } from "./lib.js"\nfail()\n|

      %{entry: entry, script: {:ok, script}} = rewritten(context, note(site, code))
      {:ok, source} = Sources.approve(context.admin, entry.id, Sources.Script.hash(script))

      assert %{status: :failed, error: error} = run(source)
      assert error =~ "deep"
      assert error =~ "Data/lib.js:2"
      assert error =~ "Data/Stars.js:8"
    end
  end
end
