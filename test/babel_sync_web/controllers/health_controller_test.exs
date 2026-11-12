defmodule BabelSyncWeb.HealthControllerTest do
  use BabelSyncWeb.ConnCase, async: true

  test "answers ok while the database does", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end
end
