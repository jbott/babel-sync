defmodule BabelSync.Accounts.Sessions do
  @moduledoc """
  The browsers signed in as each user: starting one at sign-in, noting
  when it was last seen, and ending one or all the others.
  """

  import Ecto.Query

  alias BabelSync.Accounts.{Scope, Session, User}
  alias BabelSync.Repo

  @agent_bytes 255

  @spec start(User.t(), String.t()) :: Session.t()
  def start(%User{id: user_id}, agent) do
    Repo.insert!(%Session{
      user_id: user_id,
      agent: String.slice(agent, 0, @agent_bytes),
      last_seen_at: DateTime.utc_now()
    })
  end

  @spec fetch(Ecto.UUID.t()) :: {:ok, Session.t()} | :error
  def fetch(id) do
    case Repo.one(from s in Session, where: s.id == ^id, preload: :user) do
      %Session{} = session -> {:ok, session}
      nil -> :error
    end
  end

  @spec seen(Ecto.UUID.t()) :: :ok
  def seen(id) do
    Repo.update_all(from(s in Session, where: s.id == ^id),
      set: [last_seen_at: DateTime.utc_now()]
    )

    :ok
  end

  @spec list(User.t()) :: [Session.t()]
  def list(%User{id: user_id}) do
    Repo.all(from s in Session, where: s.user_id == ^user_id, order_by: [desc: s.last_seen_at])
  end

  @spec finish(User.t(), Ecto.UUID.t()) :: :ok
  def finish(%User{id: user_id}, id) do
    close(from s in Session, where: s.user_id == ^user_id and s.id == ^id)
  end

  @spec finish_others(User.t(), Ecto.UUID.t() | nil) :: :ok
  def finish_others(%User{id: user_id}, kept) do
    others = from s in Session, where: s.user_id == ^user_id
    close(if kept, do: where(others, [s], s.id != ^kept), else: others)
  end

  @spec prune(DateTime.t()) :: :ok
  def prune(unseen_since) do
    Repo.delete_all(from s in Session, where: s.last_seen_at < ^unseen_since)
    :ok
  end

  @spec reconnect(Ecto.UUID.t()) :: :ok
  def reconnect(user_id) do
    disconnect(Scope.user_topic(user_id))

    from(s in Session, where: s.user_id == ^user_id, select: s.id)
    |> Repo.all()
    |> Enum.each(&disconnect_session/1)

    BabelSync.OAuth.reconnect(user_id)
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(id), do: "sessions:" <> id

  defp close(query) do
    {_count, ids} = Repo.delete_all(select(query, [s], s.id))
    Enum.each(ids, &disconnect_session/1)
  end

  defp disconnect_session(id) do
    disconnect(topic(id))
    disconnect(Scope.session_topic(id))
  end

  defp disconnect(topic), do: BabelSyncWeb.Endpoint.broadcast(topic, "disconnect", %{})
end
