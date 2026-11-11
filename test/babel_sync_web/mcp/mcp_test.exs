defmodule BabelSyncWeb.MCPTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.Agent.Text
  alias BabelSync.{Auth, Blobs, Sync, Vaults}

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

    assert %{"result" => %{"serverInfo" => %{"name" => "Babel Sync"}, "instructions" => guide}} =
             decode(response)

    assert guide =~ "edit_file"
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

  defp result(session, tool, arguments) do
    response =
      rpc(session.conn, session.token, session.id, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: tool, arguments: arguments}
      })

    %{"result" => result} = decode(response)
    result
  end

  defp call(session, tool, arguments) do
    result = result(session, tool, arguments)
    text = result["content"] |> Enum.map_join("\n", & &1["text"])
    if result["isError"], do: {:error, text}, else: {:ok, text}
  end

  defp read(session, path) do
    {:ok, reply} = call(session, "read_file", %{path: path})
    [_header, text] = String.split(reply, "\n", parts: 2)
    text
  end

  test "lists the tools with descriptions and input schemas", %{session: session} do
    response =
      rpc(session.conn, session.token, session.id, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

    %{"result" => %{"tools" => tools}} = decode(response)

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
             ~w(append_file create_directory delete_file edit_file file_history file_outline find_files list_changes list_directory list_trash list_vaults move_file read_file restore_file search_files write_file)

    write = Enum.find(tools, &(&1["name"] == "write_file"))
    assert write["description"] =~ "if_rev"
    assert write["inputSchema"]["required"] |> Enum.sort() == ["content", "path"]

    edit = Enum.find(tools, &(&1["name"] == "edit_file"))
    edits = edit["inputSchema"]["properties"]["edits"]
    assert edits["type"] == "array"
    assert edits["items"]["required"] |> Enum.sort() == ["new_text", "old_text"]
  end

  test "an agent finds its way around a vault", %{session: session, vault: vault} do
    {:ok, _} =
      call(session, "write_file", %{path: "Inbox/idea.md", content: "# Idea\n\nbuy milk\n"})

    {:ok, _} = call(session, "write_file", %{path: "Inbox/Old/done.md", content: "bought bread"})
    {:ok, blob} = Blobs.put(vault.id, "not really a pdf")
    entry(vault, "Inbox/paper.pdf", %{blob_hash: blob.hash, size: blob.size})

    assert {:ok, vaults} = call(session, "list_vaults", %{})
    assert vaults =~ "Notes"

    assert {:ok, "Inbox/\tfolder\t3 files"} = call(session, "list_directory", %{})
    assert {:ok, listed} = call(session, "list_directory", %{path: "Inbox"})

    assert [
             "Inbox/Old/\tfolder\t1 files",
             "Inbox/idea.md\tnote\t17 bytes\t" <> _when,
             "Inbox/paper.pdf\tattachment\t16 bytes\t" <> _then
           ] = String.split(listed, "\n")

    assert {:ok, deep} = call(session, "list_directory", %{depth: 3})
    assert deep =~ "Inbox/Old/done.md\tnote"
    assert {:ok, "created Empty/"} = call(session, "create_directory", %{path: "Empty"})
    assert {:ok, "The folder is empty."} = call(session, "list_directory", %{path: "Empty"})

    assert {:ok, "Inbox/Old/done.md\nInbox/idea.md"} =
             call(session, "find_files", %{pattern: "*.md"})

    assert {:ok, "Inbox/paper.pdf"} = call(session, "find_files", %{pattern: "Inbox/*.pdf"})
    assert {:ok, "No file matches."} = call(session, "find_files", %{pattern: "*.zip"})

    assert {:ok, "Inbox/idea.md\n3: buy milk"} = call(session, "search_files", %{query: "MILK"})

    assert {:ok, "Inbox/idea.md\n2- \n3: buy milk"} =
             call(session, "search_files", %{query: "b.y m", regex: true, context: 1})

    assert {:ok, "Inbox/Old/done.md\n1: bought bread"} =
             call(session, "search_files", %{query: "b", glob: "Inbox/Old/**"})

    assert {:ok, "No note matches."} =
             call(session, "search_files", %{
               query: "milk",
               case_sensitive: true,
               glob: "Inbox/Old/*"
             })

    assert {:error, pattern} = call(session, "search_files", %{query: "(", regex: true})
    assert pattern =~ "malformed"
  end

  test "an agent reads a note whole, in part, numbered and as an outline", %{session: session} do
    text = "---\ntags: [a]\n---\n# Title\n\none\ntwo\n\n## Part\nthree\n"
    {:ok, _} = call(session, "write_file", %{path: "a.md", content: text})
    rev = Text.rev(text)

    assert %{
             "content" => [
               %{"type" => "text", "text" => header},
               %{"type" => "text", "text" => ^text}
             ]
           } =
             result(session, "read_file", %{path: "a.md"})

    assert header == "a.md · lines 1-10 of 10 · rev #{rev}"

    assert {:ok, part} = call(session, "read_file", %{path: "a.md", offset: 6, limit: 2})
    assert part == "a.md · lines 6-7 of 10 · rev #{rev}\none\ntwo"

    assert {:ok, numbered} =
             call(session, "read_file", %{path: "a.md", offset: 9, line_numbers: true})

    assert numbered == "a.md · lines 9-10 of 10 · rev #{rev}\n     9\t## Part\n    10\tthree"

    assert {:ok, beyond} = call(session, "read_file", %{path: "a.md", offset: 99})
    assert beyond =~ "no lines in that range, the note has 10"

    assert {:ok, outline} = call(session, "file_outline", %{path: "a.md"})

    assert outline ==
             "a.md · 10 lines · rev #{rev}\nproperties: tags\n4\t# Title\n9\t## Part"
  end

  test "an agent is shown an image and told about other attachments", %{
    session: session,
    vault: vault
  } do
    pixel =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    {:ok, blob} = Blobs.put(vault.id, Base.decode64!(pixel))
    entry(vault, "pixel.png", %{blob_hash: blob.hash, size: blob.size})
    entry(vault, "paper.pdf", %{size: 9})

    assert %{"content" => [%{"type" => "text", "text" => header}, image]} =
             result(session, "read_file", %{path: "pixel.png"})

    assert header == "pixel.png · image/png · 70 bytes"
    assert image == %{"type" => "image", "data" => pixel, "mimeType" => "image/png"}

    assert {:ok, described} = call(session, "read_file", %{path: "paper.pdf"})
    assert described =~ "application/pdf, 9 bytes"
  end

  test "an agent changes a note by sending only the passage it changes", %{
    session: session,
    vault: vault
  } do
    assert {:ok, created} =
             call(session, "write_file", %{path: "Inbox/idea.md", content: "# Idea\n\nbuy milk\n"})

    assert created ==
             "created Inbox/idea.md · rev #{Text.rev("# Idea\n\nbuy milk\n")} · 3 lines\n" <>
               "     1\t# Idea\n     2\t\n     3\tbuy milk"

    assert {:ok, edited} =
             call(session, "edit_file", %{
               path: "Inbox/idea.md",
               edits: [
                 %{old_text: "milk", new_text: "oat milk"},
                 %{old_text: "# Idea", new_text: "# Shopping"}
               ]
             })

    assert edited ==
             "updated Inbox/idea.md · rev #{Text.rev("# Shopping\n\nbuy oat milk\n")} · 3 lines\n" <>
               "     1\t# Shopping\n     2\t\n     3\tbuy oat milk"

    assert {:ok, appended} =
             call(session, "append_file", %{path: "Inbox/idea.md", content: "- call mum"})

    assert appended =~ "     4\t- call mum"

    assert {:ok, _} =
             call(session, "append_file", %{path: "Inbox/idea.md", content: "\n# Later\n"})

    assert {:ok, under} =
             call(session, "append_file", %{
               path: "Inbox/idea.md",
               content: "and eggs",
               heading: "Shopping"
             })

    assert under =~ "     5\tand eggs"

    assert read(session, "Inbox/idea.md") ==
             "# Shopping\n\nbuy oat milk\n- call mum\nand eggs\n\n# Later\n"

    note = Vaults.get_entry_by_path(vault.id, "Inbox/idea.md")
    assert Sync.text(note.id) == read(session, "Inbox/idea.md")
  end

  test "replacing a whole note needs its rev or an explicit overwrite", %{
    session: session,
    vault: vault
  } do
    {:ok, _} = call(session, "write_file", %{path: "a.md", content: "v1"})
    rev = Text.rev("v1")

    assert {:error, unguarded} = call(session, "write_file", %{path: "a.md", content: "v2"})
    assert unguarded =~ "edit_file"
    assert unguarded =~ "Nothing was changed"

    note = Vaults.get_entry_by_path(vault.id, "a.md")
    {:ok, _before, _after} = Sync.rewrite_text(note.id, &{:ok, &1 <> " and a person typed"})

    assert {:error, stale} =
             call(session, "write_file", %{path: "a.md", content: "v2", if_rev: rev})

    assert stale =~ "now at rev #{Text.rev("v1 and a person typed")}"
    assert read(session, "a.md") == "v1 and a person typed"

    assert {:ok, _} =
             call(session, "write_file", %{
               path: "a.md",
               content: "v2",
               if_rev: Text.rev("v1 and a person typed")
             })

    assert {:ok, _} = call(session, "write_file", %{path: "a.md", content: "v3", overwrite: true})
    assert read(session, "a.md") == "v3"
  end

  test "problems come back as tool errors an agent can act on", %{session: session} do
    assert {:error, message} = call(session, "read_file", %{path: "missing.md"})
    assert message =~ "list_directory"

    {:ok, _} = call(session, "write_file", %{path: "a.md", content: "x x\n# H\n# H\n"})

    assert {:error, message} =
             call(session, "edit_file", %{
               path: "a.md",
               edits: [%{old_text: "# H\n# H", new_text: "# H"}, %{old_text: "x", new_text: "y"}]
             })

    assert message =~ "Edit 2"
    assert message =~ "more than once"
    assert message =~ "Nothing was changed"
    assert read(session, "a.md") == "x x\n# H\n# H\n"

    assert {:error, message} =
             call(session, "edit_file", %{path: "a.md", edits: [%{old_text: "z", new_text: "y"}]})

    assert message =~ "Edit 1: old_text was not found"

    assert {:error, message} =
             call(session, "append_file", %{path: "a.md", content: "x", heading: "H"})

    assert message =~ "More than one heading"

    assert {:error, message} =
             call(session, "append_file", %{path: "a.md", content: "x", heading: "Nope"})

    assert message =~ "file_outline"
    assert {:error, _} = call(session, "append_file", %{path: "../x.md", content: "x"})
    assert {:error, _} = call(session, "write_file", %{path: "pic.png", content: "x"})
    assert {:error, message} = call(session, "list_directory", %{path: "a.md"})
    assert message =~ "not a folder"
    assert {:error, message} = call(session, "read_file", %{path: "a.md", vault: "Nope"})
    assert message =~ "list_vaults"
  end

  test "an agent moves, deletes, restores and follows changes", %{session: session} do
    {:ok, _} = call(session, "write_file", %{path: "Log/a.md", content: "first"})
    {:ok, start} = call(session, "list_changes", %{})
    ["cursor " <> cursor | _recent] = String.split(start, "\n")

    {:ok, _} =
      call(session, "write_file", %{path: "Log/a.md", content: "second", overwrite: true})

    {:ok, _} = call(session, "append_file", %{path: "Log/a.md", content: "third"})

    assert {:ok, history} = call(session, "file_history", %{path: "Log/a.md"})
    assert [%{"version" => newest}, _second, %{"version" => oldest}] = Jason.decode!(history)

    assert {:ok, old} = call(session, "read_file", %{path: "Log/a.md", version: oldest})
    assert old =~ "lines 1-1 of 1"
    assert String.ends_with?(old, "\nfirst")
    assert {:error, _} = call(session, "read_file", %{path: "Log/a.md", version: 0})

    assert {:ok, restored} = call(session, "restore_file", %{path: "Log/a.md", version: oldest})
    assert restored =~ "updated Log/a.md"
    assert read(session, "Log/a.md") == "first"
    assert newest > oldest

    assert {:ok, "moved to Done/Log"} = call(session, "move_file", %{from: "Log", to: "Done/Log"})
    assert {:error, _} = call(session, "move_file", %{from: "Log/a.md", to: "x.md"})
    assert {:ok, "deleted Done/Log/a.md"} = call(session, "delete_file", %{path: "Done"})
    assert {:ok, "No file matches."} = call(session, "find_files", %{pattern: "**"})

    assert {:ok, trash} = call(session, "list_trash", %{})
    assert trash =~ "Done/Log/a.md\tnote\tdeleted "

    assert {:ok, "restored Done/Log/a.md"} =
             call(session, "restore_file", %{path: "Done/Log/a.md"})

    assert {:ok, "The trash is empty."} = call(session, "list_trash", %{})
    assert read(session, "Done/Log/a.md") == "first"

    assert {:ok, changes} = call(session, "list_changes", %{since: String.to_integer(cursor)})
    assert ["cursor " <> later | lines] = String.split(changes, "\n")
    assert String.to_integer(later) > String.to_integer(cursor)
    assert List.last(lines) =~ "written\tDone/Log/a.md\tnote\t"
  end

  test "a read-only credential can read but not write", %{
    bare: conn,
    owner: owner,
    session: session
  } do
    {:ok, _} = call(session, "write_file", %{path: "a.md", content: "secret"})
    read_only = start_session(conn, owner, read_only: true)

    assert read(read_only, "a.md") == "secret"

    for {tool, arguments} <- [
          {"write_file", %{path: "a.md", content: "defaced", overwrite: true}},
          {"write_file", %{path: "new.md", content: "defaced"}},
          {"edit_file", %{path: "a.md", edits: [%{old_text: "secret", new_text: "x"}]}},
          {"append_file", %{path: "a.md", content: "x"}},
          {"create_directory", %{path: "Folder"}},
          {"move_file", %{from: "a.md", to: "b.md"}},
          {"delete_file", %{path: "a.md"}},
          {"restore_file", %{path: "a.md", version: 1}}
        ] do
      assert {:error, message} = call(read_only, tool, arguments)
      assert message =~ "may not"
    end

    assert read(session, "a.md") == "secret"
  end

  test "another user's vault is invisible", %{bare: conn, session: session, vault: vault} do
    {:ok, _} = call(session, "write_file", %{path: "a.md", content: "secret"})
    stranger = start_session(conn, user())

    assert {:ok, "[]"} = call(stranger, "list_vaults", %{})
    assert {:error, _} = call(stranger, "read_file", %{vault: vault.id, path: "a.md"})
    assert {:error, _} = call(stranger, "search_files", %{vault: vault.id, query: "secret"})
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

  test "a tool run without a signed-in caller says so" do
    assert {:reply, response, %{assigns: %{}}} =
             BabelSync.MCP.Reply.run(%{assigns: %{}}, fn _scope -> {:ok, "x"} end)

    assert response.isError
  end
end
