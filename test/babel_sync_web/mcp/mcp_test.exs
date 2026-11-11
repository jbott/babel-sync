defmodule BabelSyncWeb.MCPTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Sync, Vaults}

  @protocol "2025-06-18"

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner, %{name: "Notes"})
    %{bare: conn, owner: owner, vault: vault, session: start_session(conn, owner)}
  end

  defp token(user, opts), do: user |> Scope.for_user(opts) |> Auth.socket_token()

  defp rpc(conn, token, session_id, body) do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @protocol)

    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn
    post(conn, "/mcp", Jason.encode!(body))
  end

  defp start_session(conn, user, opts \\ []) do
    token = token(user, opts)

    response =
      rpc(conn, token, nil, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: @protocol,
          capabilities: %{},
          clientInfo: %{name: "test", version: "1"}
        }
      })

    assert %{"result" => %{"serverInfo" => %{"name" => "BabelSync"}}} = decode(response)
    [session_id] = get_resp_header(response, "mcp-session-id")
    rpc(conn, token, session_id, %{jsonrpc: "2.0", method: "notifications/initialized"})
    %{conn: conn, token: token, id: session_id}
  end

  defp decode(response) do
    body = response(response, 200)

    case get_resp_header(response, "content-type") do
      ["text/event-stream" <> _] ->
        body
        |> String.split("\n")
        |> Enum.find_value(fn
          "data: " <> json -> Jason.decode!(json)
          _other -> nil
        end)

      _json ->
        Jason.decode!(body)
    end
  end

  defp call(session, tool, arguments) do
    response =
      rpc(session.conn, session.token, session.id, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: tool, arguments: arguments}
      })

    %{"result" => result} = decode(response)
    text = result["content"] |> Enum.map_join(& &1["text"])
    if result["isError"], do: {:error, text}, else: {:ok, text}
  end

  test "lists the tools with descriptions and input schemas", %{session: session} do
    response =
      rpc(session.conn, session.token, session.id, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

    %{"result" => %{"tools" => tools}} = decode(response)

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
             ~w(append_note delete_file edit_note list_files list_vaults move_file note_history read_note search_notes write_note)

    write = Enum.find(tools, &(&1["name"] == "write_note"))
    assert write["description"] =~ "merged"
    assert write["inputSchema"]["required"] |> Enum.sort() == ["content", "path"]
  end

  test "an agent writes, edits, searches and reads notes", %{session: session, vault: vault} do
    assert {:ok, vaults} = call(session, "list_vaults", %{})
    assert vaults =~ "Notes"

    assert {:ok, "created Inbox/idea.md"} =
             call(session, "write_note", %{path: "Inbox/idea.md", content: "# Idea\n\nbuy milk\n"})

    assert {:ok, "updated Inbox/idea.md"} =
             call(session, "edit_note", %{
               path: "Inbox/idea.md",
               old_text: "milk",
               new_text: "oat milk"
             })

    assert {:ok, "updated Inbox/idea.md"} =
             call(session, "append_note", %{path: "Inbox/idea.md", content: "- call mum"})

    assert {:ok, "# Idea\n\nbuy oat milk\n- call mum"} =
             call(session, "read_note", %{path: "Inbox/idea.md"})

    assert {:ok, found} = call(session, "search_notes", %{query: "oat"})
    assert found =~ "Inbox/idea.md"
    assert {:ok, files} = call(session, "list_files", %{folder: "Inbox"})
    assert files =~ "idea.md"
    assert {:ok, history} = call(session, "note_history", %{path: "Inbox/idea.md"})
    assert history =~ "saved_at"

    assert {:ok, "moved to Archive/idea.md"} =
             call(session, "move_file", %{from: "Inbox/idea.md", to: "Archive/idea.md"})

    note = Vaults.get_entry_by_path(vault.id, "Archive/idea.md")
    assert Sync.text(note.id) == "# Idea\n\nbuy oat milk\n- call mum"

    assert {:ok, "deleted Archive/idea.md"} =
             call(session, "delete_file", %{path: "Archive/idea.md"})

    assert Vaults.list_entries(vault.id) == []
  end

  test "problems come back as tool errors an agent can act on", %{session: session} do
    assert {:error, message} = call(session, "read_note", %{path: "missing.md"})
    assert message =~ "list_files"

    {:ok, _} = call(session, "write_note", %{path: "a.md", content: "x x"})

    assert {:error, message} =
             call(session, "edit_note", %{path: "a.md", old_text: "x", new_text: "y"})

    assert message =~ "more than once"
  end

  test "a read-only credential can read but not write", %{
    bare: conn,
    owner: owner,
    session: session
  } do
    {:ok, _} = call(session, "write_note", %{path: "a.md", content: "secret"})
    read_only = start_session(conn, owner, read_only: true)

    assert {:ok, "secret"} = call(read_only, "read_note", %{path: "a.md"})
    assert {:error, message} = call(read_only, "write_note", %{path: "a.md", content: "defaced"})
    assert message =~ "may not"
    assert {:ok, "secret"} = call(session, "read_note", %{path: "a.md"})
  end

  test "another user's vault is invisible", %{bare: conn, session: session, vault: vault} do
    {:ok, _} = call(session, "write_note", %{path: "a.md", content: "secret"})
    stranger = start_session(conn, user())

    assert {:ok, "[]"} = call(stranger, "list_vaults", %{})
    assert {:error, _} = call(stranger, "read_note", %{vault: vault.id, path: "a.md"})
  end

  test "requests without a credential are refused", %{bare: conn} do
    Application.put_env(:babel_sync, :auth, [:passkey])
    on_exit(fn -> Application.put_env(:babel_sync, :auth, []) end)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"}))

    assert json_response(response, 401)
  end
end
