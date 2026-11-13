defmodule BabelSync.MCP.SessionStoreTest do
  use BabelSync.DataCase, async: false

  alias BabelSync.MCP.SessionStore

  test "a saved session is read back as it was written" do
    :ok = SessionStore.save("s1", %{id: "s1", initialized: true, frame: %{"assigns" => %{}}}, [])

    assert {:ok, %{"id" => "s1", "initialized" => true, "frame" => %{"assigns" => %{}}}} =
             SessionStore.load("s1", [])

    assert {:ok, ["s1"]} = SessionStore.list_active([])
  end

  test "a session past its time is gone, and cleanup removes it" do
    :ok = SessionStore.save("old", %{id: "old"}, ttl: -1)
    :ok = SessionStore.save("new", %{id: "new"}, [])

    assert {:error, :not_found} = SessionStore.load("old", [])
    assert {:error, :not_found} = SessionStore.update_ttl("old", 60_000, [])
    assert {:ok, 1} = SessionStore.cleanup_expired([])
    assert {:ok, ["new"]} = SessionStore.list_active([])
  end

  test "a session can be changed, kept longer and deleted" do
    :ok = SessionStore.save("s1", %{id: "s1", log_level: "info"}, ttl: 1_000)
    :ok = SessionStore.update("s1", %{log_level: "debug"}, [])
    :ok = SessionStore.update_ttl("s1", 60_000, [])

    assert {:ok, %{"id" => "s1", "log_level" => "debug"}} = SessionStore.load("s1", [])
    :ok = SessionStore.delete("s1", [])
    :ok = SessionStore.delete("s1", [])
    assert {:error, :not_found} = SessionStore.load("s1", [])
    assert {:error, :not_found} = SessionStore.update("s1", %{log_level: "debug"}, [])
  end
end
