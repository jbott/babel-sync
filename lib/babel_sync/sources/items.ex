defmodule BabelSync.Sources.Items do
  @moduledoc """
  Brings one outside thing into the vault as a note, and keeps doing so
  to the same note.

  A source names each thing by a key of its own. The first time a key is
  seen, a note that already holds it is taken over, found by a property
  the source says identifies it or else by the path it would be made at;
  failing that the note is made. From then on the key leads to that
  note wherever it is moved or whatever it is renamed to.

  Only the properties the source names are set, by
  `BabelSync.Markdown.FrontMatter.merge/3` against what it set last
  time. The body is written when the note is made and never again. A
  note whose text would come out the same is not written at all, so it
  costs no version and no device hears of it. A note a person deleted
  stays deleted, and is kept up again once it is restored from the trash.
  """

  import Ecto.Query

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Bases, Repo, Sync, Vaults}
  alias BabelSync.Markdown.FrontMatter
  alias BabelSync.Sources.{Item, Source}
  alias BabelSync.Vaults.Entry

  @type wanted :: %{
          key: String.t(),
          path: String.t(),
          properties: [{String.t(), FrontMatter.value()}],
          body: String.t(),
          match: {String.t(), String.t()} | nil
        }
  @type outcome :: :created | :changed | :unchanged | :gone
  @type shown :: :all | :current | :deleted
  @type found :: (String.t(), String.t() -> Entry.t() | nil)

  @spec put(Source.t(), Scope.t(), [String.t()], wanted(), found()) ::
          {:ok, outcome(), String.t() | nil} | {:error, String.t()}
  def put(%Source{} = source, %Scope{} = scope, folders, wanted, found) do
    case Repo.one(from i in Item, where: i.source_id == ^source.id and i.key == ^wanted.key) do
      %Item{} = item ->
        case item.entry_id && Vaults.get_entry(item.entry_id) do
          %Entry{deleted_at: nil, kind: :doc} = entry -> update(scope, item, entry, wanted)
          _deleted -> forget(item)
        end

      nil ->
        with :ok <- within(wanted.path, folders) do
          case existing(source.vault_id, wanted, folders, found) do
            %Entry{} = entry ->
              update(scope, %Item{source_id: source.id, key: wanted.key}, entry, wanted)

            nil ->
              create(source, scope, wanted)
          end
        end
    end
  end

  @spec within(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def within(path, folders) do
    folded = Vaults.Path.fold(path)

    cond do
      not Vaults.Path.valid?(Vaults.Path.normalize(path)) ->
        {:error, "#{path} is not a path a note can have"}

      Enum.any?(folders, &String.starts_with?(folded, Vaults.Path.fold(&1) <> "/")) ->
        :ok

      true ->
        {:error, "#{path} is outside the folders this source may use"}
    end
  end

  defp existing(vault_id, %{match: {property, value}} = wanted, folders, found) do
    case found.(property, value) do
      %Entry{path: path} = entry -> if(within(path, folders) == :ok, do: entry)
      nil -> existing(vault_id, %{wanted | match: nil}, folders, found)
    end
  end

  defp existing(vault_id, %{path: path}, _folders, _found) do
    case Vaults.get_entry_by_path(vault_id, path) do
      %Entry{kind: :doc, deleted_at: nil} = entry -> entry
      _none -> nil
    end
  end

  defp create(source, scope, wanted) do
    with :ok <- markdown(wanted.path),
         {:ok, text} <- FrontMatter.merge(wanted.body, wanted.properties, %{}),
         {:ok, %{path: path}} <-
           written(Agent.write_file(scope, source.vault_id, wanted.path, text)) do
      %Entry{id: entry_id} = Vaults.get_entry_by_path(source.vault_id, path)
      remember(%Item{source_id: source.id, key: wanted.key}, entry_id, wanted.properties)
      {:ok, :created, path}
    else
      {:error, :invalid_front_matter} ->
        {:error, "the body given for #{wanted.path} has properties that cannot be read"}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp update(scope, item, %Entry{} = entry, wanted) do
    before = Jason.decode!(item.written)
    merge = &FrontMatter.merge(&1, wanted.properties, before)

    with :ok <- may_write(scope, entry),
         current = Sync.text(entry.id),
         {:ok, merged} <- merge.(current) do
      outcome =
        if merged == current do
          :unchanged
        else
          by = Keyword.put(Scope.author(scope), :origin, :source)
          {:ok, _old, _new} = Sync.rewrite_text(entry.id, merge, by)
          :ok = Sync.flush(entry.id)
          :changed
        end

      remember(item, entry.id, wanted.properties)
      {:ok, outcome, entry.path}
    else
      {:error, :invalid_front_matter} ->
        {:error, "#{entry.path} has properties that cannot be read"}

      {:error, :forbidden} ->
        {:error, "whoever approved this source may no longer write #{entry.path}"}
    end
  end

  defp may_write(scope, entry), do: Scope.authorize_write(scope, entry.vault_id, entry.path)

  defp markdown(path) do
    if Vaults.Path.markdown?(path), do: :ok, else: {:error, "#{path} is not a Markdown note"}
  end

  defp written({:ok, done}), do: {:ok, done}

  defp written({:error, :forbidden}),
    do: {:error, "whoever approved this source may no longer write to the vault"}

  defp written({:error, reason}), do: {:error, "could not make the note: #{inspect(reason)}"}

  defp remember(%Item{} = item, entry_id, properties) do
    written = Jason.encode!(Map.new(properties))
    now = DateTime.utc_now()

    if item.gone or item.entry_id != entry_id or item.written != written do
      Repo.insert!(
        %Item{
          item
          | entry_id: entry_id,
            written: written,
            gone: false,
            inserted_at: item.inserted_at || now,
            updated_at: now
        },
        on_conflict: [set: [entry_id: entry_id, written: written, gone: false, updated_at: now]],
        conflict_target: [:source_id, :key]
      )
    end

    :ok
  end

  defp forget(%Item{gone: true}), do: {:ok, :gone, nil}

  defp forget(%Item{} = item) do
    Repo.update_all(from(i in Item, where: i.id == ^item.id),
      set: [gone: true, updated_at: DateTime.utc_now()]
    )

    {:ok, :gone, nil}
  end

  @doc """
  The notes a source keeps, each with its entry: all of them, only those
  whose note is in the vault (`:current`), or only those whose note was
  deleted (`:deleted`). `matching` narrows them to keys and paths that
  hold that text. A deleted note's entry is there while the note is still
  in the trash.
  """
  @spec list(Source.t(), shown(), String.t(), pos_integer()) :: [{Item.t(), Entry.t() | nil}]
  def list(%Source{} = source, shown, matching, limit) do
    Repo.all(
      from [i, e] in listed(source, shown, matching),
        order_by: [asc: e.folded, asc: i.key],
        limit: ^limit,
        select: {i, e}
    )
  end

  @spec counts(Source.t(), String.t()) :: %{shown() => non_neg_integer()}
  def counts(%Source{} = source, matching) do
    Map.new([:all, :current, :deleted], fn shown ->
      {shown, Repo.aggregate(listed(source, shown, matching), :count)}
    end)
  end

  defp listed(source, shown, matching) do
    from(i in Item,
      left_join: e in Entry,
      on: e.id == i.entry_id,
      where: i.source_id == ^source.id
    )
    |> shown(shown)
    |> matching(String.trim(matching))
  end

  defp shown(query, :all), do: query

  defp shown(query, :current),
    do: from([i, e] in query, where: is_nil(e.deleted_at) and not is_nil(e.id))

  defp shown(query, :deleted),
    do: from([i, e] in query, where: not is_nil(e.deleted_at) or is_nil(e.id))

  defp matching(query, ""), do: query

  defp matching(query, text) do
    pattern = "%" <> String.replace(String.downcase(text), ["!", "%", "_"], &("!" <> &1)) <> "%"

    from [i, e] in query,
      where:
        fragment("? LIKE ? ESCAPE '!'", e.folded, ^pattern) or
          fragment("lower(?) LIKE ? ESCAPE '!'", i.key, ^pattern)
  end

  @doc """
  Puts a deleted note back under the source's care. While the note is in
  the trash it is restored as it was. Once it has left the trash the
  source forgets it, so the next run makes it anew.
  """
  @spec reinstate(Source.t(), Ecto.UUID.t()) ::
          {:ok, :restored | :forgotten} | {:error, :not_found}
  def reinstate(%Source{id: source_id}, item_id) do
    item = Repo.get_by(Item, id: item_id, source_id: source_id)

    case item && {item, item.entry_id && Vaults.get_entry(item.entry_id)} do
      {_item, %Entry{deleted_at: nil}} ->
        {:error, :not_found}

      {_item, %Entry{} = trashed} ->
        with {:ok, _restored} <- Vaults.restore_entry(trashed), do: {:ok, :restored}

      {item, nil} ->
        Repo.delete!(item)
        {:ok, :forgotten}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Finds notes by the value of a property, among the notes in `folders`.
  Reading every note's properties is the costly part, so it is done once
  for each property asked about and the answer kept by `keep`.
  """
  @spec finder(Ecto.UUID.t(), [String.t()], (term(), (-> term()) -> term())) :: found()
  def finder(vault_id, folders, keep) do
    fn property, value ->
      by_value =
        keep.({:by, property}, fn ->
          by_value(keep.(:entries, fn -> entries(vault_id, folders) end), property)
        end)

      by_value[value]
    end
  end

  defp entries(vault_id, folders) do
    for %Entry{kind: :doc} = entry <- Vaults.list_entries(vault_id),
        within(entry.path, folders) == :ok,
        into: %{},
        do: {entry.path, entry}
  end

  defp by_value(entries, property) do
    for %Bases.Note{path: path, properties: %{^property => held}} <-
          Bases.Index.notes(Map.values(entries)),
        into: %{},
        do: {to_string(held), entries[path]}
  end
end
