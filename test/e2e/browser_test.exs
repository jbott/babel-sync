defmodule BabelSync.E2E.BrowserTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.{Accounts, Auth, Sync, Vaults}

  @moduletag :browser
  @moduletag timeout: 180_000

  setup_all do
    Mix.Task.rerun("tailwind", ["babel_sync"])
    Mix.Task.rerun("esbuild", ["babel_sync"])
    Mix.Task.rerun("esbuild", ["maplibre_worker"])
    :ok
  end

  defp chrome(phase, env) do
    {output, status} =
      System.cmd(
        "node",
        ["--test", "--test-force-exit", "--test-timeout=120000", "test/e2e/browser.test.ts"],
        stderr_to_stdout: true,
        env:
          [
            {"BABELSYNC_URL", BabelSyncWeb.Endpoint.url()},
            {"BABELSYNC_PHASE", phase},
            {"CHROME_BIN", BabelSync.Chrome.path()}
          ] ++ env
      )

    assert status == 0, output
  end

  test "the web app works in a real browser" do
    vault = vault(Accounts.single_user!())

    owner = Accounts.single_user!()

    chrome("app", [
      {"BABELSYNC_VAULT_ID", vault.id},
      {"BABELSYNC_TOKEN", owner |> Accounts.Scope.for_user() |> Auth.socket_token()}
    ])

    note = Vaults.get_entry_by_path(vault.id, "Notes/renamed.md")
    :ok = Sync.flush(note.id)
    assert Sync.text(note.id) =~ "tab two says hi\n"
    assert Sync.text(note.id) =~ "after the move\n"
    assert Sync.text(note.id) =~ "# Hello\n\nfrom tab one, says the agent 😀\n"
    assert Sync.text(note.id) =~ "agent line 15\n"
    assert Sync.text(note.id) =~ "typed while the agent was writing\nstill typing"
    assert %{kind: :blob, size: 70} = Vaults.get_entry_by_path(vault.id, "Notes/pixel.png")
    refute Vaults.get_entry_by_path(vault.id, "Notes/browser.md")
  end

  test "passkeys work in a real browser" do
    with_auth([:passkey])
    owner = Accounts.single_user!()

    chrome("passkey", [
      {"BABELSYNC_SETUP_URL", BabelSyncWeb.Endpoint.url() <> "/login?setup=" <> Auth.Setup.code()}
    ])

    assert ["First passkey", "Second key"] =
             owner |> Auth.Passkeys.list() |> Enum.map(& &1.name) |> Enum.sort()
  end
end
