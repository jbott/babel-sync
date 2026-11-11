defmodule BabelSync.E2E.JsClientTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Blobs, Sync, Vaults}

  @moduletag timeout: 120_000

  defp node(phase, vault, token) do
    {output, status} =
      System.cmd(
        "node",
        ["--test", "--test-force-exit", "--test-timeout=30000", "js/core/test/e2e.test.ts"],
        stderr_to_stdout: true,
        env: [
          {"BABELSYNC_URL", BabelSyncWeb.Endpoint.url()},
          {"BABELSYNC_VAULT_ID", vault.id},
          {"BABELSYNC_TOKEN", token},
          {"BABELSYNC_PHASE", phase}
        ]
      )

    assert status == 0, output
  end

  test "browser Yjs clients and the server agree on every byte" do
    owner = user()
    vault = vault(owner)
    token = owner |> Scope.for_user() |> Auth.socket_token()

    node("write", vault, token)

    live = Vaults.get_entry_by_path(vault.id, "Shared/live.md")
    assert Sync.text(live.id) == "a😀😃b 日本語\nbob was here\n"

    offline = Vaults.get_entry_by_path(vault.id, "offline.md")
    assert Sync.text(offline.id) == "carol offline\nline one\nline two\nalice online\n"

    attachment = Vaults.get_entry_by_path(vault.id, "Attachments/big.bin")
    assert Blobs.read(Blobs.get(vault.id, attachment.blob_hash)) == "v2"

    assert Vaults.get_entry_by_path(vault.id, "final.md")
    refute Vaults.get_entry_by_path(vault.id, "doomed.md")

    :ok = Sync.replace_text(live.id, "a😀😃b 日本の語\nbob was here\nand the server too 🎉\n")
    node("verify", vault, token)

    assert Sync.text(live.id) == "a😀😃b 日本の語\nbob was here\nand the server too ✅🎉\n"
  end

  test "two plugin sync engines keep their vaults identical through the server" do
    owner = user()
    vaults = for n <- 1..10, do: vault(owner, %{name: "Device test #{n}"})
    token = owner |> Scope.for_user() |> Auth.socket_token()

    {output, status} =
      System.cmd(
        "node",
        ["--test", "--test-force-exit", "--test-timeout=60000", "plugin/test/engine.test.ts"],
        stderr_to_stdout: true,
        env: [
          {"BABELSYNC_URL", BabelSyncWeb.Endpoint.url()},
          {"BABELSYNC_TOKEN", token},
          {"BABELSYNC_VAULT_IDS", Enum.map_join(vaults, ",", & &1.id)}
        ]
      )

    assert status == 0, output
  end

  test "the plugin signs a device in through the oauth flow" do
    vault = vault(BabelSync.Accounts.single_user!())

    {output, status} =
      System.cmd(
        "node",
        ["--test", "--test-force-exit", "--test-timeout=30000", "plugin/test/oauth.test.ts"],
        stderr_to_stdout: true,
        env: [
          {"BABELSYNC_URL", BabelSyncWeb.Endpoint.url()},
          {"BABELSYNC_VAULT_IDS", vault.id}
        ]
      )

    assert status == 0, output
  end
end
