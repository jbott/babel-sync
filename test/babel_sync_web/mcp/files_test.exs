defmodule BabelSyncWeb.MCP.FilesTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Auth, Blobs, Sync, Vaults}

  @extension "io.modelcontextprotocol/files"
  @version "2026-07-28"
  @features %{"upload" => %{}, "download" => %{}}

  setup do
    owner = user()
    %{vault: vault(owner), scope: Scope.for_user(owner)}
  end

  defp rpc(scope, method, params, features \\ @features) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{"extensions" => %{@extension => features}}
    }

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("authorization", "Bearer " <> Auth.socket_token(scope))
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", method)

    conn = if params["name"], do: put_req_header(conn, "mcp-name", params["name"]), else: conn

    result =
      post(
        conn,
        "/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: System.unique_integer([:positive]),
          method: method,
          params: Map.put(params, "_meta", meta)
        })
      )

    json_response(result, result.status)
  end

  defp offer(path, content) do
    %{
      "name" => "save_file",
      "arguments" => %{
        "path" => path,
        "file" => %{
          "id" => "file-1",
          "name" => "local.bin",
          "mimeType" => "application/octet-stream",
          "size" => byte_size(content),
          "digest" => %{
            "algorithm" => "sha-256",
            "value" => Base.url_encode64(:crypto.hash(:sha256, content), padding: false)
          }
        }
      }
    }
  end

  defp fetch_target(target, headers \\ []) do
    conn =
      Enum.reduce(headers ++ Map.to_list(target["headers"]), build_conn(), fn {k, v}, conn ->
        put_req_header(conn, k, v)
      end)

    get(conn, URI.parse(target["url"]).path)
  end

  defp stage(target, body) do
    conn =
      Enum.reduce(target["headers"], build_conn(), fn {k, v}, conn ->
        put_req_header(conn, k, v)
      end)

    conn
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> put(URI.parse(target["url"]).path, body)
  end

  test "discovers the extension and its file input on stateless HTTP", %{scope: scope} do
    assert %{
             "result" => %{
               "capabilities" => %{"extensions" => %{@extension => %{"upload" => %{}}}}
             }
           } = rpc(scope, "server/discover", %{})

    %{"result" => %{"tools" => tools}} = rpc(scope, "tools/list", %{}, %{})
    save = Enum.find(tools, &(&1["name"] == "save_file"))
    file = save["inputSchema"]["properties"]["file"]
    assert file["x-mcp-file"]["maxSize"] == Blobs.max_size()
    assert file["required"] == ["id", "mimeType", "size"]
  end

  test "only the original caller can finalize staged bytes at the original path, once", %{
    scope: scope,
    vault: vault
  } do
    body = <<0, 1, 255>>
    call = offer("Inbox/image.bin", body)

    assert %{
             "result" => %{
               "resultType" => "upload_required",
               "requestState" => state,
               "uploads" => [target]
             }
           } = rpc(scope, "tools/call", call)

    assert target["fileId"] == "file-1"
    assert target["credentials"] == "omit"
    retry = Map.put(call, "requestState", state)
    assert %{"result" => %{"isError" => true}} = rpc(scope, "tools/call", retry)
    assert stage(target, body).status == 200
    assert stage(target, body).status == 404
    refute Vaults.get_entry_by_path(vault.id, "Inbox/image.bin")

    assert %{"error" => %{"code" => -32_602}} =
             rpc(scope, "tools/call", put_in(retry, ["arguments", "path"], "changed.bin"))

    assert %{"error" => %{"code" => -32_602}} = rpc(Scope.for_user(user()), "tools/call", retry)

    assert %{"result" => %{"resultType" => "complete", "isError" => false}} =
             rpc(scope, "tools/call", put_in(retry, ["arguments", "file", "size"], 3.0))

    assert %{"error" => %{"code" => -32_602}} = rpc(scope, "tools/call", retry)
    entry = Vaults.get_entry_by_path(vault.id, "Inbox/image.bin")
    assert entry.blob_hash == Blobs.hash_binary(body)
    assert %{"result" => %{"isError" => true}} = rpc(scope, "tools/call", call)
  end

  test "binds the digest, rechecks write access and treats empty files as complete", %{
    vault: vault
  } do
    member = user()
    {:ok, _} = Vaults.put_member(vault, member, :editor)
    scope = Scope.for_user(member)
    call = offer("note.md", "abc")
    %{"result" => %{"uploads" => [bad], "requestState" => state}} = rpc(scope, "tools/call", call)
    assert stage(bad, "abd").status == 422

    assert %{"result" => %{"isError" => true}} =
             rpc(scope, "tools/call", Map.put(call, "requestState", state))

    assert %{"result" => %{"isError" => false}} = rpc(scope, "tools/call", offer("empty.md", ""))
    assert Sync.text(Vaults.get_entry_by_path(vault.id, "empty.md").id) == ""

    %{"result" => %{"uploads" => [target], "requestState" => state}} =
      rpc(scope, "tools/call", call)

    assert stage(target, "abc").status == 200
    :ok = Vaults.remove_member(vault, member)

    assert %{"result" => %{"isError" => true}} =
             rpc(scope, "tools/call", Map.put(call, "requestState", state))

    refute Vaults.get_entry_by_path(vault.id, "note.md")
  end

  test "concurrent confirmations publish a staged note once", %{scope: scope, vault: vault} do
    call = offer("notes/trip.md", "packing list")

    %{"result" => %{"uploads" => [target], "requestState" => state}} =
      rpc(scope, "tools/call", call)

    assert stage(target, "packing list").status == 200

    results =
      [1, 2]
      |> Task.async_stream(fn _ ->
        rpc(scope, "tools/call", Map.put(call, "requestState", state))
      end)
      |> Enum.map(fn {:ok, reply} -> reply end)

    assert Enum.count(results, &match?(%{"result" => %{"isError" => false}}, &1)) == 1
    assert Enum.count(results, &match?(%{"error" => %{"code" => -32_602}}, &1)) == 1
    assert Sync.text(Vaults.get_entry_by_path(vault.id, "notes/trip.md").id) == "packing list"
  end

  test "expiration releases staged bytes without publishing them", %{scope: scope, vault: vault} do
    call = offer("unused.bin", "unused")

    %{"result" => %{"uploads" => [target], "requestState" => state}} =
      rpc(scope, "tools/call", call)

    assert stage(target, "unused").status == 200
    cutoff = DateTime.add(DateTime.utc_now(), 7200, :second)
    Blobs.collect_garbage(cutoff)
    assert Blobs.get(vault.id, Blobs.hash_binary("unused"))
    BabelSync.Transfers.prune(cutoff)
    Blobs.collect_garbage(cutoff)
    refute Blobs.get(vault.id, Blobs.hash_binary("unused"))

    assert %{"error" => %{"code" => -32_602}} =
             rpc(scope, "tools/call", Map.put(call, "requestState", state))

    refute Vaults.get_entry_by_path(vault.id, "unused.bin")
  end

  test "requires upload capability and refuses inline bytes", %{scope: scope} do
    call = offer("note.md", "abc")

    for features <- [%{}, %{"download" => %{}}, Map.put(@features, "revision", "unknown")] do
      assert %{
               "error" => %{
                 "code" => -32_021,
                 "data" => %{
                   "requiredCapabilities" => %{
                     "extensions" => %{@extension => %{"upload" => %{}}}
                   }
                 }
               }
             } = rpc(scope, "tools/call", call, features)
    end

    assert %{"result" => %{"isError" => true}} =
             rpc(scope, "tools/call", put_in(call, ["arguments", "file", "data"], "YWJj"))
  end

  test "downloads return the offered version, with a shell fallback for other clients", %{
    scope: scope,
    vault: vault
  } do
    {:ok, _} = Agent.write_file(scope, vault.id, "note.md", "original")
    call = %{"name" => "download_file", "arguments" => %{"path" => "note.md"}}

    assert %{
             "result" => %{
               "_meta" => %{@extension => %{"downloads" => [target]}},
               "content" => [%{"text" => text}]
             }
           } = rpc(scope, "tools/call", call)

    assert target["size"] == 8
    refute text =~ target["url"]
    refute text =~ target["headers"]["x-babel-transfer"]
    {:ok, _} = Agent.write_file(scope, vault.id, "note.md", "changed", overwrite: true)
    assert response(fetch_target(target), 200) == "original"
    %{"result" => fallback} = rpc(scope, "tools/call", call, %{"upload" => %{}})
    refute get_in(fallback, ["_meta", @extension])
    assert hd(fallback["content"])["text"] =~ "curl"
    {:ok, blob} = Blobs.put(vault.id, "abcdef")
    entry(vault, "paper.pdf", %{blob_hash: blob.hash, size: blob.size})

    %{"result" => %{"_meta" => %{@extension => %{"downloads" => [pdf]}}}} =
      rpc(scope, "tools/call", put_in(call, ["arguments", "path"], "paper.pdf"))

    assert response(fetch_target(pdf, [{"range", "bytes=2-4"}]), 206) == "cde"
  end
end
