defmodule BabelSyncWeb.HealthController do
  @moduledoc """
  Answers a load balancer or container health check. `/health` is 200
  when the server can do its work and 503 when it cannot: the database
  answers a query and the place attachments are kept can be reached.

  Asked for JSON, it says which of those failed, and how much is going
  on: nothing in the answer names a vault, a note or a person.
  """

  use BabelSyncWeb, :controller

  def show(conn, _params) do
    checks = %{database: database(), attachments: attachments()}
    healthy? = Enum.all?(Map.values(checks), &(&1 == :ok))
    status = if healthy?, do: 200, else: 503

    case wants_json?(conn) do
      true ->
        conn
        |> put_status(status)
        |> json(%{
          status: if(healthy?, do: "ok", else: "failing"),
          checks: Map.new(checks, fn {name, result} -> {name, result == :ok} end),
          live: BabelSync.Stats.live()
        })

      false ->
        send_resp(conn, status, if(healthy?, do: "ok", else: failing(checks)))
    end
  end

  defp wants_json?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "application/json"))
  end

  defp failing(checks) do
    for({name, :error} <- checks, do: "#{name} unavailable") |> Enum.join(", ")
  end

  defp database do
    case BabelSync.Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp attachments do
    if BabelSync.Blobs.Store.impl().reachable?(), do: :ok, else: :error
  end
end
