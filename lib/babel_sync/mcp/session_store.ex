defmodule BabelSync.MCP.SessionStore do
  @moduledoc """
  Keeps what an agent's session negotiated in the database, so the
  session outlives the server it was opened on. A request that reaches
  another node, or the same one after a restart, picks the session up
  where a memory-only session would have been answered "not found".

  Who the agent acts for is never saved: every request proves that
  again with its own token.
  """

  @behaviour Anubis.Server.Session.Store

  import Ecto.Query

  alias BabelSync.MCP.SavedSession
  alias BabelSync.Repo

  @kept_ms :timer.minutes(30)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def save(session_id, state, opts) do
    Repo.insert!(
      %SavedSession{id: session_id, state: JSON.encode!(state), expires_at: expiry(opts[:ttl])},
      on_conflict: {:replace, [:state, :expires_at]},
      conflict_target: :id
    )

    :ok
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def load(session_id, _opts) do
    case Repo.one(from s in current(), where: s.id == ^session_id, select: s.state) do
      nil -> {:error, :not_found}
      state -> JSON.decode(state)
    end
  end

  @impl true
  def delete(session_id, _opts) do
    Repo.delete_all(from s in SavedSession, where: s.id == ^session_id)
    :ok
  end

  @impl true
  def list_active(_opts), do: {:ok, Repo.all(from s in current(), select: s.id)}

  @impl true
  def update_ttl(session_id, ttl_ms, _opts) do
    found(
      Repo.update_all(from(s in current(), where: s.id == ^session_id),
        set: [expires_at: expiry(ttl_ms)]
      )
    )
  end

  @impl true
  def update(session_id, updates, opts) do
    with {:ok, state} <- load(session_id, opts) do
      changed = Map.merge(state, Map.new(updates, fn {key, value} -> {to_string(key), value} end))

      found(
        Repo.update_all(from(s in current(), where: s.id == ^session_id),
          set: [state: JSON.encode!(changed)]
        )
      )
    end
  end

  @impl true
  def cleanup_expired(_opts) do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from s in SavedSession, where: s.expires_at <= ^now)
    {:ok, count}
  end

  defp current do
    now = DateTime.utc_now()
    from s in SavedSession, where: s.expires_at > ^now
  end

  defp expiry(ttl_ms), do: DateTime.add(DateTime.utc_now(), ttl_ms || @kept_ms, :millisecond)

  defp found({0, _}), do: {:error, :not_found}
  defp found({_some, _}), do: :ok
end
