defmodule BabelSyncWeb.BlobControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Blobs, Vaults}

  @part 8 * 1024 * 1024

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner)
    %{conn: as(conn, owner), bare: conn, owner: owner, vault: vault}
  end

  defp as(conn, user, opts \\ []) do
    token = user |> Scope.for_user(opts) |> Auth.socket_token()
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp upload_part(conn, vault, id, number, data) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> put("/api/vaults/#{vault.id}/uploads/#{id}/parts/#{number}", data)
  end

  defp digest(data), do: :crypto.hash(:sha256, data)

  test "a file is uploaded in parts, resumed, completed and downloaded", %{
    conn: conn,
    vault: vault
  } do
    first = :crypto.strong_rand_bytes(@part)
    second = :crypto.strong_rand_bytes(100)
    body = %{hash: Blobs.hash([digest(first), digest(second)]), size: @part + 100}

    assert %{"status" => "upload", "id" => id, "missing" => [1, 2], "part_size" => @part} =
             conn |> post("/api/vaults/#{vault.id}/uploads", body) |> json_response(200)

    assert conn |> upload_part(vault, id, 2, second) |> response(204)

    assert %{"error" => "missing_parts", "missing" => [1]} =
             conn |> post("/api/vaults/#{vault.id}/uploads/#{id}/complete") |> json_response(409)

    assert %{"missing" => [1]} =
             conn |> post("/api/vaults/#{vault.id}/uploads", body) |> json_response(200)

    assert conn |> upload_part(vault, id, 1, first) |> response(204)

    assert %{"hash" => hash, "size" => size} =
             conn |> post("/api/vaults/#{vault.id}/uploads/#{id}/complete") |> json_response(200)

    assert {hash, size} == {body.hash, body.size}

    assert %{"status" => "exists"} =
             conn |> post("/api/vaults/#{vault.id}/uploads", body) |> json_response(200)

    download = get(conn, "/api/vaults/#{vault.id}/blobs/#{hash}")
    assert response(download, 200) == first <> second
    assert get_resp_header(download, "content-security-policy") |> hd() =~ "sandbox"
  end

  test "byte ranges are served", %{conn: conn, vault: vault} do
    {:ok, blob} = Blobs.put(vault.id, "0123456789")
    path = "/api/vaults/#{vault.id}/blobs/#{blob.hash}"

    middle = conn |> put_req_header("range", "bytes=2-5") |> get(path)
    assert response(middle, 206) == "2345"
    assert get_resp_header(middle, "content-range") == ["bytes 2-5/10"]

    assert conn |> put_req_header("range", "bytes=7-") |> get(path) |> response(206) == "789"
    assert conn |> put_req_header("range", "bytes=-3") |> get(path) |> response(206) == "789"

    assert conn |> put_req_header("range", "bytes=4-999") |> get(path) |> response(206) ==
             "456789"

    assert conn |> put_req_header("range", "bytes=10-") |> get(path) |> response(416)
    assert conn |> put_req_header("range", "bytes=x-y") |> get(path) |> response(416)
  end

  test "a part larger than the part size is refused", %{conn: conn, vault: vault} do
    {:ok, upload, _} = Blobs.begin_upload(vault.id, %{hash: String.duplicate("a", 64), size: 10})

    assert conn
           |> upload_part(vault, upload.id, 1, :crypto.strong_rand_bytes(@part + 1))
           |> json_response(413)

    assert conn |> upload_part(vault, upload.id, 1, "short") |> json_response(422) == %{
             "error" => "wrong_size"
           }
  end

  test "corrupt uploads are rejected", %{conn: conn, vault: vault} do
    {:ok, upload, _} = Blobs.begin_upload(vault.id, %{hash: String.duplicate("a", 64), size: 4})
    assert conn |> upload_part(vault, upload.id, 1, "evil") |> response(204)

    assert %{"error" => "hash_mismatch"} =
             conn
             |> post("/api/vaults/#{vault.id}/uploads/#{upload.id}/complete")
             |> json_response(422)
  end

  test "requests without a valid credential are refused", %{bare: bare, vault: vault} do
    Application.put_env(:babel_sync, :auth, [:passkey])
    on_exit(fn -> Application.put_env(:babel_sync, :auth, []) end)

    assert bare |> get("/api/vaults/#{vault.id}/blobs/abc") |> json_response(401)

    assert bare
           |> put_req_header("authorization", "Bearer nope")
           |> get("/api/vaults/#{vault.id}/blobs/abc")
           |> json_response(401)
  end

  test "access follows vault roles", %{bare: bare, owner: owner, vault: vault} do
    {:ok, blob} = Blobs.put(vault.id, "secret")
    viewer = user()
    {:ok, _} = Vaults.put_member(vault, viewer, :viewer)
    body = %{hash: String.duplicate("a", 64), size: 1}

    assert bare
           |> as(user())
           |> get("/api/vaults/#{vault.id}/blobs/#{blob.hash}")
           |> json_response(403)

    assert bare
           |> as(viewer)
           |> get("/api/vaults/#{vault.id}/blobs/#{blob.hash}")
           |> response(200) == "secret"

    assert bare
           |> as(viewer)
           |> post("/api/vaults/#{vault.id}/uploads", body)
           |> json_response(403)

    assert bare
           |> as(owner, read_only: true)
           |> post("/api/vaults/#{vault.id}/uploads", body)
           |> json_response(403)
  end

  test "an upload cannot be reached through another vault", %{
    conn: conn,
    owner: owner,
    vault: vault
  } do
    other = vault(owner)
    {:ok, upload, _} = Blobs.begin_upload(other.id, %{hash: String.duplicate("a", 64), size: 1})

    assert conn |> upload_part(vault, upload.id, 1, "x") |> json_response(404)

    assert conn
           |> post("/api/vaults/#{vault.id}/uploads/#{upload.id}/complete")
           |> json_response(404)
  end
end
