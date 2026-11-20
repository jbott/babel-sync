defmodule BabelSync.Sources.ConnectionsTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.Sources.{Scheduler, Script}
  alias BabelSync.{Agent, Connectors, Sources, Sync, Vaults}

  @host "fixture.example"
  @url "https://fixture.example/account"
  @cookie "fixture-session"

  setup do
    previous = Application.get_env(:babel_sync, :connector_adapter)
    Application.put_env(:babel_sync, :connector_adapter, __MODULE__)

    on_exit(fn ->
      Application.delete_env(:babel_sync, __MODULE__)

      if previous,
        do: Application.put_env(:babel_sync, :connector_adapter, previous),
        else: Application.delete_env(:babel_sync, :connector_adapter)
    end)

    :ok
  end

  test "an approved source reads authenticated HTML and preserves renamed notes through reconnect" do
    owner = user()
    vault = vault(owner, %{sources_folder: "Data"})
    scope = Scope.for_user(owner, session_id: Ecto.UUID.generate())
    id = Ecto.UUID.generate()
    assert {:ok, _} = Connectors.connect(scope, vault.id, id, payload())
    assert {:ok, _} = Agent.write_file(scope, vault.id, "Data/Account.js", source(id))
    assert [%{status: :new, entry: entry, script: {:ok, script}}] = Sources.drafts(vault.id)
    assert Scheduler.queue_due(DateTime.utc_now()) == []

    agent = Scope.for_user(owner, grant_id: Ecto.UUID.generate())
    assert {:error, :forbidden} = Sources.approve(agent, entry.id, Script.hash(script))
    assert {:ok, source} = Sources.approve(scope, entry.id, Script.hash(script))
    assert %{status: :done, created: 1} = scheduled(source)

    path = "Data/Account/item-1.md"
    note = Vaults.get_entry_by_path(vault.id, path)
    assert Sync.text(note.id) =~ "A & B"
    refute Sync.text(note.id) =~ @cookie
    reviewed = "Data/Account/Reviewed.md"
    assert {:ok, _} = Agent.move_file(scope, vault.id, path, reviewed)
    assert %{status: :done, created: 0, changed: 0, unchanged: 1} = scheduled(source)
    assert Vaults.get_entry_by_path(vault.id, reviewed).id == note.id

    Application.put_env(:babel_sync, __MODULE__, :expired)
    assert %{status: :failed, created: 0, error: error} = scheduled(source)
    assert error =~ "reconnect server sync"
    assert Sources.get(source.id).attention =~ "reconnect server sync"

    assert :ok = Connectors.disconnect(scope, vault.id, id)
    Application.delete_env(:babel_sync, __MODULE__)
    assert %{status: :failed, created: 0} = scheduled(source)
    assert {:ok, _} = Connectors.connect(scope, vault.id, id, payload())
    assert %{status: :done, created: 0, unchanged: 1} = scheduled(source)
    assert Sources.get(source.id).attention == nil
    assert Vaults.get_entry_by_path(vault.id, reviewed).id == note.id
    refute Vaults.get_entry_by_path(vault.id, path)
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t()}
  def run(request) do
    assert Req.Request.get_header(request, "cookie") == ["session=#{@cookie}"]
    assert request.url.host == @host

    response =
      case Application.get_env(:babel_sync, __MODULE__) do
        :expired ->
          %Req.Response{status: 401, body: ""}

        nil ->
          %Req.Response{
            status: 200,
            body: ~s|<main id="account"><article data-id="item-1">A &amp; B</article></main>|
          }
      end

    {request, response}
  end

  defp payload do
    %{
      "landing_url" => @url,
      "hosts" => [@host],
      "check_selector" => "#account",
      "user_agent" => "Fixture Chrome",
      "cookies" => [
        %{
          "name" => "session",
          "value" => @cookie,
          "domain" => @host,
          "path" => "/",
          "hostOnly" => true,
          "httpOnly" => true
        }
      ]
    }
  end

  defp source(id) do
    """
    /* source
    schedule: every 1h
    hosts: [#{@host}]
    connections: [#{id}]
    params:
      connection: #{id}
    */
    const response = connections.get(params.connection, "#{@url}")
    for (const item of html.select(response.text(), "article")) {
      const id = item.attributes["data-id"]
      vault.item(id, {path: id + ".md", properties: {item_id: id}, body: item.text})
    }
    """
  end

  defp scheduled(source) do
    now = DateTime.add(Sources.get(source.id).next_run_at, 1, :second)
    assert [%{trigger: "schedule"}] = Scheduler.queue_due(now)
    assert Scheduler.queue_due(now) == []
    assert [{run, claimed}] = Scheduler.claim(now)
    Scheduler.carry_out(run, claimed)
  end
end
