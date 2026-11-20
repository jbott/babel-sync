defmodule BabelSyncWeb.ConnectorController do
  use BabelSyncWeb, :controller

  alias BabelSync.Connectors

  plug :valid_connection

  def show(conn, %{"vault_id" => vault_id, "id" => id}) do
    case Connectors.status(conn.assigns.current_scope, vault_id, id) do
      {:ok, status} -> json(conn, %{status: status})
      {:error, reason} -> failed(conn, reason)
    end
  end

  def create(conn, %{"vault_id" => vault_id, "id" => id} = params) do
    case Connectors.connect(conn.assigns.current_scope, vault_id, id, params) do
      {:ok, result} ->
        json(conn, result)

      {:error, reason} ->
        failed(conn, reason)
    end
  end

  def delete(conn, %{"vault_id" => vault_id, "id" => id}) do
    case Connectors.disconnect(conn.assigns.current_scope, vault_id, id) do
      :ok -> json(conn, %{status: :disconnected})
      {:error, reason} -> failed(conn, reason)
    end
  end

  defp valid_connection(conn, _opts) do
    with ["Bearer " <> _token] <- get_req_header(conn, "authorization"),
         {:ok, _} <- Ecto.UUID.cast(conn.params["vault_id"]),
         {:ok, _} <- Ecto.UUID.cast(conn.params["id"]) do
      put_resp_header(conn, "cache-control", "no-store")
    else
      _invalid ->
        conn |> put_status(:bad_request) |> json(%{error: :invalid_connection}) |> halt()
    end
  end

  defp failed(conn, reason) do
    status =
      case reason do
        :forbidden -> :forbidden
        :changed -> :conflict
        :reauthorize -> :unprocessable_entity
        :invalid_session -> :unprocessable_entity
        _unavailable -> :bad_gateway
      end

    conn |> put_status(status) |> json(%{error: reason})
  end
end
