defmodule BabelSync.History do
  @moduledoc """
  The saved versions of a note as people browse them: when each was
  saved, by whom, how many lines it added and removed, and what it
  changed compared with the version before it or with the note as it is
  now.
  """

  import Ecto.Query

  alias BabelSync.Accounts.User
  alias BabelSync.Repo
  alias BabelSync.Sync
  alias BabelSync.Sync.{Changes, Version}

  @counted_bytes 500_000

  @type summary :: %{
          id: integer(),
          saved_at: DateTime.t(),
          bytes: non_neg_integer(),
          author: String.t() | nil,
          app: String.t() | nil,
          added: non_neg_integer() | nil,
          removed: non_neg_integer() | nil,
          earliest: boolean()
        }

  @type against :: :previous | :now

  @spec versions(Ecto.UUID.t()) :: [summary()]
  def versions(entry_id) do
    :ok = Sync.flush(entry_id)
    versions = Sync.list_versions(entry_id)
    authors = authors(versions)

    versions
    |> Enum.zip(Enum.drop(versions, 1) ++ [nil])
    |> Enum.map(fn {version, previous} ->
      {added, removed} = counts(previous, version)

      %{
        id: version.id,
        saved_at: version.inserted_at,
        bytes: byte_size(version.content),
        author: Map.get(authors, version.author_id),
        app: version.author_app,
        added: added,
        removed: removed,
        earliest: is_nil(previous)
      }
    end)
  end

  @spec compare(Ecto.UUID.t(), integer(), against()) ::
          {:ok, %{version: Version.t(), text: String.t(), changes: Changes.t()}}
          | {:error, :not_found}
  def compare(entry_id, version_id, against) do
    case Sync.get_version(entry_id, version_id) do
      nil ->
        {:error, :not_found}

      version ->
        {old, new} =
          case against do
            :previous -> {previous_content(version), version.content}
            :now -> {version.content, Sync.text(entry_id)}
          end

        {:ok, %{version: version, text: version.content, changes: Changes.compare(old, new)}}
    end
  end

  defp previous_content(version) do
    Repo.one(
      from v in Version,
        where: v.entry_id == ^version.entry_id and v.id < ^version.id,
        order_by: [desc: v.id],
        limit: 1,
        select: v.content
    ) || ""
  end

  defp counts(previous, version) do
    old = if previous, do: previous.content, else: ""

    if byte_size(old) + byte_size(version.content) > @counted_bytes,
      do: {nil, nil},
      else: Changes.count(old, version.content)
  end

  @spec authors([Sync.Version.t()]) :: %{Ecto.UUID.t() => String.t()}
  def authors(versions) do
    ids = versions |> Enum.map(& &1.author_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from u in User, where: u.id in ^ids, select: {u.id, u.name, u.email})
    |> Map.new(fn {id, name, email} -> {id, if(name in [nil, ""], do: email, else: name)} end)
  end
end
