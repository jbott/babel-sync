defmodule BabelSync.Sync.Store do
  @moduledoc """
  Durable form of a note's Yjs document: one compacted state plus the
  updates received since, and the plain-text versions kept as history.
  """

  import Ecto.Query

  alias BabelSync.Repo
  alias BabelSync.Sync.{State, Update, Version}

  @spec load(Ecto.UUID.t()) :: {binary() | nil, [{integer(), binary()}]}
  def load(entry_id) do
    state = Repo.one(from s in State, where: s.entry_id == ^entry_id, select: s.data)

    updates =
      Repo.all(
        from u in Update, where: u.entry_id == ^entry_id, order_by: u.id, select: {u.id, u.data}
      )

    {state, updates}
  end

  @spec append(Ecto.UUID.t(), binary()) :: integer()
  def append(entry_id, update) do
    Repo.insert!(%Update{entry_id: entry_id, data: update, inserted_at: DateTime.utc_now()}).id
  end

  @spec compact(Ecto.UUID.t(), binary(), [integer()]) :: :ok
  def compact(entry_id, full_state, applied) do
    {:ok, :ok} =
      Repo.transact(fn ->
        Repo.insert!(
          %State{entry_id: entry_id, data: full_state, updated_at: DateTime.utc_now()},
          on_conflict: {:replace, [:data, :updated_at]},
          conflict_target: :entry_id
        )

        applied
        |> Enum.chunk_every(500)
        |> Enum.each(&Repo.delete_all(from u in Update, where: u.id in ^&1))

        {:ok, :ok}
      end)

    :ok
  end

  @spec put_version(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) :: Version.t()
  def put_version(entry_id, content, author_id) do
    Repo.insert!(%Version{
      entry_id: entry_id,
      content: content,
      content_hash: hash(content),
      author_id: author_id,
      inserted_at: DateTime.utc_now()
    })
  end

  @spec list_versions(Ecto.UUID.t()) :: [Version.t()]
  def list_versions(entry_id) do
    Repo.all(from v in Version, where: v.entry_id == ^entry_id, order_by: [desc: v.id])
  end

  @spec get_version(Ecto.UUID.t(), integer()) :: Version.t() | nil
  def get_version(entry_id, id), do: Repo.get_by(Version, entry_id: entry_id, id: id)

  @spec latest_contents([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def latest_contents(entry_ids) do
    latest =
      from v in Version,
        where: v.entry_id in ^entry_ids,
        group_by: v.entry_id,
        select: %{id: max(v.id)}

    Repo.all(
      from v in Version,
        join: l in subquery(latest),
        on: l.id == v.id,
        select: {v.entry_id, v.content}
    )
    |> Map.new()
  end

  @spec prune_versions(DateTime.t()) :: non_neg_integer()
  def prune_versions(older_than) do
    newest =
      from n in Version, where: n.entry_id == parent_as(:version).entry_id, select: max(n.id)

    {count, _} =
      Repo.delete_all(
        from v in Version,
          as: :version,
          where: v.inserted_at < ^older_than and v.id < subquery(newest)
      )

    count
  end

  @spec hash(String.t()) :: String.t()
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
