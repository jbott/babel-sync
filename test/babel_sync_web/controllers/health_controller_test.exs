defmodule BabelSyncWeb.HealthControllerTest do
  use BabelSyncWeb.ConnCase, async: true

  test "answers ok while the database does", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  test "asked for JSON, says what it checked and how busy it is", %{conn: conn} do
    reply =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/health")
      |> json_response(200)

    assert %{
             "status" => "ok",
             "checks" => %{"database" => true, "attachments" => true},
             "live" => %{"notes_open" => open, "memory_bytes" => bytes}
           } = reply

    assert is_integer(open) and is_integer(bytes)
  end
end
