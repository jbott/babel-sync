defmodule BabelSync.Bases.Index do
  @moduledoc """
  What bases need from each note, its properties, tags and links, kept in
  the database so a base reads small rows rather than parsing every
  note's text each time it runs. Parsing front matter is nearly all the
  cost of a base, and a server may hold many vaults, so this lives on
  disk rather than in memory.

  A row records the hash of the text it was read from, and is used only
  while that hash matches the note's own `content_hash`, which changes
  whenever the note's text is saved, by anyone. A note open for editing
  may be ahead of its last save, so its live text is always looked at,
  and read again only when it is not the text the row was read from.
  Rows that are missing or out of date are read again and saved as a
  base runs, so nothing that changes notes has to remember to keep the
  index current, and a change to how notes are read needs only the rows
  emptied. Rows go with their note.
  """

  use Ecto.Schema

  import Ecto.Query

  alias BabelSync.Bases.Note
  alias BabelSync.Repo
  alias BabelSync.Sync
  alias BabelSync.Sync.Store
  alias BabelSync.Vaults.Entry

  @batch 500

  @primary_key {:entry_id, :binary_id, autogenerate: false}
  schema "note_index" do
    field :content_hash, :string
    field :data, :binary
    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @spec notes([Entry.t()]) :: [Note.t()]
  def notes(entries) do
    readable = for %Entry{kind: :doc} = entry <- entries, markdown?(entry.path), do: entry
    stored = stored(Enum.map(readable, & &1.id))
    unsettled = MapSet.new(Sync.Store.unsettled(Enum.map(readable, & &1.id)))

    {current, stale} =
      Enum.split_with(readable, fn entry ->
        match?({hash, _facts} when hash == entry.content_hash, stored[entry.id]) and
          not is_nil(entry.content_hash) and not Sync.live?(entry.id) and
          entry.id not in unsettled
      end)

    facts =
      Map.merge(
        Map.new(current, fn entry -> {entry.id, elem(stored[entry.id], 1)} end),
        refresh(stale, stored)
      )

    for entry <- entries do
      Note.new(
        path: entry.path,
        size: entry.size,
        created: entry.inserted_at,
        modified: entry.updated_at,
        facts: Map.get(facts, entry.id, Note.read(""))
      )
    end
  end

  defp stored(ids) do
    ids
    |> Enum.chunk_every(@batch)
    |> Enum.flat_map(fn batch ->
      Repo.all(
        from row in __MODULE__,
          where: row.entry_id in ^batch,
          select: {row.entry_id, row.content_hash, row.data}
      )
    end)
    |> Map.new(fn {id, hash, data} -> {id, {hash, :erlang.binary_to_term(data, [:safe])}} end)
  end

  defp refresh([], _stored), do: %{}

  defp refresh(entries, stored) do
    now = DateTime.utc_now()

    entries
    |> Enum.chunk_every(@batch)
    |> Enum.flat_map(fn batch ->
      hashed =
        for {id, text} <- Sync.texts(Enum.map(batch, & &1.id)), do: {id, Store.hash(text), text}

      {kept, changed} =
        Enum.split_with(hashed, fn {id, hash, _text} -> match?({^hash, _facts}, stored[id]) end)

      read = for {id, hash, text} <- changed, do: {id, hash, Note.read(text)}

      rows =
        for {id, hash, facts} <- read do
          %{
            entry_id: id,
            content_hash: hash,
            data: :erlang.term_to_binary(facts),
            updated_at: now
          }
        end

      Repo.insert_all(__MODULE__, rows,
        on_conflict: {:replace, [:content_hash, :data, :updated_at]},
        conflict_target: :entry_id
      )

      for({id, _hash, _text} <- kept, do: {id, elem(stored[id], 1)}) ++
        for({id, _hash, facts} <- read, do: {id, facts})
    end)
    |> Map.new()
  end

  defp markdown?(path), do: path |> Path.extname() |> String.downcase() == ".md"
end
