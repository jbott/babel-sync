defmodule BabelSyncWeb.HealthController do
  @moduledoc """
  Answers a load balancer or container health check: 200 when the
  database answers, 503 when it does not.
  """

  use BabelSyncWeb, :controller

  def show(conn, _params) do
    case BabelSync.Repo.query("SELECT 1") do
      {:ok, _result} -> send_resp(conn, 200, "ok")
      {:error, _reason} -> send_resp(conn, 503, "database unavailable")
    end
  end
end
