defmodule BabelSyncWeb.DocController do
  @moduledoc """
  Hands a device the stored updates of many notes at once, so a device
  filling an empty vault need not open a channel for every note.
  """

  use BabelSyncWeb, :controller

  import Ecto.Query

  alias BabelSync.Accounts.Scope
  alias BabelSync.Repo
  alias BabelSync.Sync.Store
  alias BabelSync.Vaults.Entry

  @most 200

  def index(conn, %{"vault_id" => vault_id, "ids" => ids}) when is_list(ids) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(conn.assigns.current_scope, vault_id, :read),
         true <- length(ids) <= @most,
         {:ok, ids} <- cast_all(ids) do
      notes =
        Repo.all(
          from e in Entry,
            where: e.vault_id == ^vault_id and e.id in ^ids,
            where: e.kind == :doc and is_nil(e.deleted_at),
            select: e.id
        )

      docs =
        notes
        |> Store.load_many()
        |> Map.new(fn {id, updates} -> {id, Enum.map(updates, &Base.encode64/1)} end)

      json(conn, %{docs: docs})
    else
      false -> conn |> put_status(:payload_too_large) |> json(%{error: "too_many"})
      :error -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid"})
      {:error, _denied} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def index(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid"})

  defp cast_all(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, cast} ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> {:cont, {:ok, [id | cast]}}
        :error -> {:halt, :error}
      end
    end)
  end
end
