defmodule BabelSync.Agent do
  @moduledoc """
  What an AI agent can do in a vault: a file system of notes, attachments
  and folders, addressed by path.

  Every function takes the caller's scope and checks it. Changes to a note
  are worked out from its text at the moment they are applied, inside the
  Yjs document people are editing, and land as minimal edits. An agent
  therefore sends only the passage it changes, never the whole note, and
  does not overwrite what someone is typing.

  A note's `rev` names its exact text. A write that carries the rev of an
  earlier read is refused when the note has changed since.
  """

  alias BabelSync.Accounts.Scope
  alias BabelSync.Agent.{Glob, Text}
  alias BabelSync.Blobs
  alias BabelSync.Sync
  alias BabelSync.Sync.Version
  alias BabelSync.Vaults
  alias BabelSync.Vaults.{Entry, Vault}

  @type reason ::
          :forbidden
          | :vault_not_found
          | :ambiguous_vault
          | :not_found
          | :not_a_note
          | :not_a_folder
          | :exists
          | :invalid_path
          | :invalid_pattern
          | :unguarded
          | :no_heading
          | :ambiguous_heading
          | {:stale, String.t()}
          | {:no_match | :ambiguous_match, pos_integer()}

  @type error :: {:error, reason()}
  @type vault_reference :: String.t() | nil

  @read_lines 2000
  @listed 500
  @searched_files 50
  @search_batch 200
  @image_bytes 4_000_000
  @recent_changes 50

  @spec list_vaults(Scope.t()) :: [%{id: String.t(), name: String.t(), role: atom()}]
  def list_vaults(%Scope{user: user}) do
    for vault <- Vaults.list_vaults(user) do
      %{id: vault.id, name: vault.name, role: Vaults.role(user, vault.id)}
    end
  end

  @spec list_directory(Scope.t(), vault_reference(), String.t() | nil, pos_integer()) ::
          {:ok, [map()]} | error()
  def list_directory(scope, vault, path \\ nil, depth \\ 1) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      folder = Vaults.Path.normalize(path || "")
      inside = vault.id |> Vaults.list_entries() |> within(folder)

      case {inside, folder == "" or Vaults.get_entry_by_path(vault.id, folder)} do
        {[], nil} -> {:error, :not_found}
        {[], %Entry{kind: kind}} when kind != :folder -> {:error, :not_a_folder}
        _a_folder -> {:ok, listing(inside, folder, depth)}
      end
    end
  end

  @spec find_files(Scope.t(), vault_reference(), String.t()) :: {:ok, [String.t()]} | error()
  def find_files(scope, vault, pattern) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, glob} <- Glob.compile(pattern) do
      {:ok,
       for(
         %Entry{kind: kind, path: path} <- Vaults.list_entries(vault.id),
         kind != :folder and Regex.match?(glob, path),
         do: path
       )
       |> Enum.take(@listed)}
    end
  end

  @spec search_files(Scope.t(), vault_reference(), String.t(), keyword()) ::
          {:ok, [%{path: String.t(), matches: [map()]}]} | error()
  def search_files(scope, vault, query, opts \\ []) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, pattern} <- pattern(query, opts),
         {:ok, glob} <- Glob.compile(opts[:glob] || "**") do
      context = opts[:context] || 0

      found =
        for(
          %Entry{kind: :doc} = entry <- Vaults.list_entries(vault.id),
          Regex.match?(glob, entry.path),
          do: entry
        )
        |> Stream.chunk_every(@search_batch)
        |> Stream.flat_map(fn batch ->
          texts = Sync.texts(Enum.map(batch, & &1.id))
          Enum.map(batch, &%{path: &1.path, matches: Text.search(texts[&1.id], pattern, context)})
        end)
        |> Stream.reject(&(&1.matches == []))
        |> Enum.take(@searched_files)

      {:ok, found}
    end
  end

  @spec read_file(Scope.t(), vault_reference(), String.t(), keyword()) :: {:ok, map()} | error()
  def read_file(scope, vault, path, opts \\ []) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- entry(vault, path) do
      case entry do
        %Entry{kind: :doc} ->
          with {:ok, text} <- text(entry, opts[:version]) do
            part =
              Text.slice(text, max(opts[:offset] || 1, 1), max(opts[:limit] || @read_lines, 1))

            {:ok, Map.merge(part, %{path: entry.path, kind: :note, rev: Text.rev(text)})}
          end

        %Entry{kind: :blob} ->
          {:ok, attachment(entry)}

        %Entry{kind: :folder} ->
          {:error, :not_a_note}
      end
    end
  end

  @spec outline(Scope.t(), vault_reference(), String.t()) :: {:ok, map()} | error()
  def outline(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- note(vault, path) do
      text = Sync.text(entry.id)

      {:ok,
       text
       |> Text.outline()
       |> Map.merge(%{path: entry.path, rev: Text.rev(text), lines: Text.line_count(text)})}
    end
  end

  @spec write_file(Scope.t(), vault_reference(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | error()
  def write_file(scope, vault, path, content, opts \\ []) do
    content = Sync.normalize(content)
    replace = fn _current -> {:ok, content} end

    with {:ok, vault} <- vault(scope, vault, :write) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :doc} = entry ->
          if opts[:if_rev] || opts[:overwrite] do
            written(:updated, entry, rewrite(scope, entry, opts[:if_rev], replace))
          else
            {:error, :unguarded}
          end

        %Entry{} ->
          {:error, :not_a_note}

        nil ->
          with {:ok, entry} <- create(vault, path) do
            written(:created, entry, rewrite(scope, entry, nil, replace))
          end
      end
    end
  end

  @spec edit_file(Scope.t(), vault_reference(), String.t(), [map()], keyword()) ::
          {:ok, map()} | error()
  def edit_file(scope, vault, path, edits, opts \\ []) do
    edits =
      for edit <- edits do
        %{
          old_text: Sync.normalize(edit.old_text),
          new_text: Sync.normalize(edit.new_text),
          replace_all: edit[:replace_all] == true
        }
      end

    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, entry} <- note(vault, path) do
      written(:updated, entry, rewrite(scope, entry, opts[:if_rev], &Text.edit(&1, edits)))
    end
  end

  @spec append_file(Scope.t(), vault_reference(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | error()
  def append_file(scope, vault, path, content, opts \\ []) do
    content = Sync.normalize(content)
    heading = opts[:heading]

    with {:ok, vault} <- vault(scope, vault, :write) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :doc} = entry ->
          written(:updated, entry, rewrite(scope, entry, nil, &Text.append(&1, content, heading)))

        %Entry{} ->
          {:error, :not_a_note}

        nil when is_nil(heading) ->
          write_file(scope, vault.id, path, content)

        nil ->
          {:error, :not_found}
      end
    end
  end

  @spec create_directory(Scope.t(), vault_reference(), String.t()) :: {:ok, String.t()} | error()
  def create_directory(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :write) do
      case Vaults.create_entry(vault.id, %{path: path, kind: :folder}) do
        {:ok, folder} -> {:ok, folder.path}
        {:error, {:exists, %Entry{kind: :folder} = folder}} -> {:ok, folder.path}
        {:error, {:exists, _file}} -> {:error, :exists}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid_path}
      end
    end
  end

  @spec move_file(Scope.t(), vault_reference(), String.t(), String.t()) ::
          {:ok, String.t()} | error()
  def move_file(scope, vault, from, to) do
    from = Vaults.Path.normalize(from)
    to = Vaults.Path.normalize(to)

    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, moving} <- named(vault, from),
         :ok <- move_each(moving, from, to) do
      {:ok, to}
    end
  end

  @spec delete_file(Scope.t(), vault_reference(), String.t()) :: {:ok, [String.t()]} | error()
  def delete_file(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, doomed} <- named(vault, Vaults.Path.normalize(path)) do
      deleted =
        for entry <- doomed,
            {:ok, gone} <- [Vaults.delete_entry(entry)],
            %Entry{} = one <- gone do
          one.path
        end

      {:ok, Enum.sort(deleted)}
    end
  end

  @spec list_trash(Scope.t(), vault_reference()) :: {:ok, [map()]} | error()
  def list_trash(scope, vault) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      {:ok,
       for entry <- Vaults.list_trash(vault.id) do
         %{path: entry.path, kind: kind(entry), deleted_at: entry.deleted_at}
       end}
    end
  end

  @spec restore_file(Scope.t(), vault_reference(), String.t()) :: {:ok, String.t()} | error()
  def restore_file(scope, vault, path) do
    path = Vaults.Path.normalize(path)

    with {:ok, vault} <- vault(scope, vault, :write),
         %Entry{} = trashed <- Enum.find(Vaults.list_trash(vault.id), &(&1.path == path)),
         {:ok, restored} <- Vaults.restore_entry(trashed) do
      {:ok, restored.path}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec restore_version(Scope.t(), vault_reference(), String.t(), integer()) ::
          {:ok, map()} | error()
  def restore_version(scope, vault, path, version_id) do
    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, entry} <- note(vault, path),
         {:ok, content} <- text(entry, version_id) do
      written(:updated, entry, rewrite(scope, entry, nil, fn _current -> {:ok, content} end))
    end
  end

  @spec history(Scope.t(), vault_reference(), String.t()) :: {:ok, [map()]} | error()
  def history(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- note(vault, path) do
      :ok = Sync.flush(entry.id)

      {:ok,
       for version <- Sync.list_versions(entry.id) do
         %{version: version.id, saved_at: version.inserted_at, bytes: byte_size(version.content)}
       end}
    end
  end

  @spec list_changes(Scope.t(), vault_reference(), non_neg_integer() | nil) ::
          {:ok, %{cursor: non_neg_integer(), changes: [map()]}} | error()
  def list_changes(scope, vault, since \\ nil) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      changed =
        case since do
          nil -> vault.id |> Vaults.changes_since(0) |> Enum.take(-@recent_changes)
          since -> vault.id |> Vaults.changes_since(since) |> Enum.take(@listed)
        end

      {:ok,
       %{
         cursor: changed |> Enum.map(& &1.seq) |> Enum.max(fn -> since || 0 end),
         changes:
           for entry <- changed do
             %{
               path: entry.path,
               kind: kind(entry),
               change: if(entry.deleted_at, do: :deleted, else: :written),
               at: entry.updated_at
             }
           end
       }}
    end
  end

  defp vault(%Scope{user: user} = scope, reference, access) do
    vaults = Vaults.list_vaults(user)

    found =
      case reference do
        nil -> vaults
        "" -> vaults
        reference -> Enum.filter(vaults, &(&1.id == reference or &1.name == reference))
      end

    case found do
      [%Vault{} = vault] ->
        with :ok <- Scope.authorize(scope, vault.id, access), do: {:ok, vault}

      [] ->
        {:error, :vault_not_found}

      _several ->
        {:error, :ambiguous_vault}
    end
  end

  defp entry(vault, path) do
    case Vaults.get_entry_by_path(vault.id, path) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  defp note(vault, path) do
    case entry(vault, path) do
      {:ok, %Entry{kind: :doc} = entry} -> {:ok, entry}
      {:ok, %Entry{}} -> {:error, :not_a_note}
      error -> error
    end
  end

  defp named(vault, path) do
    case Vaults.get_entry_by_path(vault.id, path) do
      %Entry{} = entry ->
        {:ok, [entry]}

      nil ->
        case vault.id |> Vaults.list_entries() |> within(path) do
          [] -> {:error, :not_found}
          inside -> {:ok, Enum.reject(inside, &nested?(&1, inside))}
        end
    end
  end

  defp nested?(entry, entries) do
    Enum.any?(entries, &(&1.kind == :folder and String.starts_with?(entry.path, &1.path <> "/")))
  end

  defp move_each(moving, from, to) do
    Enum.reduce_while(moving, :ok, fn entry, :ok ->
      case Vaults.rename_entry(entry, to <> String.replace_prefix(entry.path, from, "")) do
        {:ok, _moved} -> {:cont, :ok}
        {:error, {:exists, _entry}} -> {:halt, {:error, :exists}}
        {:error, :not_found} -> {:halt, {:error, :not_found}}
        {:error, %Ecto.Changeset{}} -> {:halt, {:error, :invalid_path}}
      end
    end)
  end

  defp within(entries, ""), do: entries

  defp within(entries, folder),
    do: Enum.filter(entries, &String.starts_with?(&1.path, folder <> "/"))

  defp listing(entries, folder, depth) do
    base = level(folder)
    shown? = &((level(&1) - base) in 1..depth//1)
    files = Enum.reject(entries, &(&1.kind == :folder))
    counts = files |> Enum.flat_map(&ancestors(&1.path)) |> Enum.frequencies()

    folders =
      for entry <- entries,
          path <- if(entry.kind == :folder, do: [entry.path], else: []) ++ ancestors(entry.path),
          shown?.(path),
          uniq: true do
        %{path: path <> "/", kind: :folder, files: Map.get(counts, path, 0)}
      end

    listed =
      for entry <- files, shown?.(entry.path) do
        %{path: entry.path, kind: kind(entry), bytes: entry.size, modified: entry.updated_at}
      end

    Enum.sort_by(folders ++ listed, & &1.path)
  end

  defp level(""), do: 0
  defp level(path), do: path |> String.split("/") |> length()

  defp ancestors(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.scan(&(&2 <> "/" <> &1))
  end

  defp kind(%Entry{kind: :doc}), do: :note
  defp kind(%Entry{kind: :blob}), do: :attachment
  defp kind(%Entry{kind: :folder}), do: :folder

  defp pattern(query, opts) do
    source = if opts[:regex], do: query, else: Regex.escape(query)
    flags = if opts[:case_sensitive], do: "u", else: "iu"

    with true <- query != "",
         {:ok, pattern} <- Regex.compile(source, flags) do
      {:ok, pattern}
    else
      _invalid -> {:error, :invalid_pattern}
    end
  end

  defp text(entry, nil), do: {:ok, Sync.text(entry.id)}

  defp text(entry, version_id) do
    case Sync.get_version(entry.id, version_id) do
      %Version{content: content} -> {:ok, content}
      nil -> {:error, :not_found}
    end
  end

  defp attachment(%Entry{} = entry) do
    type = MIME.from_path(entry.path)
    blob = entry.blob_hash && Blobs.get(entry.vault_id, entry.blob_hash)
    viewable? = blob && String.starts_with?(type, "image/") && entry.size <= @image_bytes

    %{
      path: entry.path,
      kind: :attachment,
      type: type,
      bytes: entry.size,
      image: if(viewable?, do: Blobs.read(blob))
    }
  end

  defp create(vault, path) do
    if Vaults.Path.kind_for(path) == :doc do
      case Vaults.create_entry(vault.id, %{path: path}) do
        {:ok, entry} -> {:ok, entry}
        {:error, {:exists, _entry}} -> {:error, :exists}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid_path}
      end
    else
      {:error, :not_a_note}
    end
  end

  defp rewrite(%Scope{user: user}, %Entry{id: id}, if_rev, change) do
    guarded = fn current ->
      current_rev = Text.rev(current)

      if if_rev in [nil, "", current_rev],
        do: change.(current),
        else: {:error, {:stale, current_rev}}
    end

    with {:ok, old, new} <- Sync.rewrite_text(id, guarded, author_id: user.id, origin: :agent),
         :ok <- Sync.flush(id) do
      {:ok, old, new}
    end
  end

  defp written(outcome, entry, {:ok, old, new}) do
    {:ok,
     %{
       outcome: outcome,
       path: entry.path,
       rev: Text.rev(new),
       lines: Text.line_count(new),
       changed: Text.changed(old, new)
     }}
  end

  defp written(_outcome, _entry, {:error, _reason} = refused), do: refused
end
