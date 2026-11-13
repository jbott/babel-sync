defmodule BabelSync.Agent do
  @moduledoc """
  What an AI agent can do in a vault: a file system of notes, attachments
  and folders, addressed by path.

  Every function takes the caller's scope and checks it. Changes to a note
  are worked out from its text at the moment they are applied, inside the
  Yjs document people are editing, and land as minimal edits. An agent
  therefore sends only the passage it changes, never the whole note, and
  does not overwrite what someone is typing.

  The `.obsidian` folder holds the plugins Obsidian runs and their
  settings. Unless the vault's owner opens it to agents, an agent can
  neither see it nor put anything there.

  A note's `rev` names its exact text. A write that carries the rev of an
  earlier read is refused when the note has changed since.
  """

  require Logger

  alias BabelSync.Accounts.Scope
  alias BabelSync.Agent.{Glob, Text}
  alias BabelSync.Bases
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
          | :not_an_attachment
          | :invalid_encoding
          | :too_large
          | :not_a_folder
          | :exists
          | :invalid_path
          | :invalid_pattern
          | {:invalid_query, String.t()}
          | :no_coordinates
          | :off_limits
          | :unguarded
          | :no_heading
          | :ambiguous_heading
          | {:stale, String.t()}
          | {:no_match | :ambiguous_match, pos_integer()}
          | :not_text
          | :invalid_size
          | :not_a_folder_target
          | :storage_unavailable
          | :search_timeout
          | :too_large_to_read

  @type error :: {:error, reason()}
  @type vault_reference :: String.t() | nil

  @read_lines 2000
  @listed 500
  @searched_files 50
  @search_batch 200
  @image_bytes 4_000_000
  @text_bytes 2 * 1024 * 1024
  @written_bytes 8 * 1024 * 1024
  @searched_bytes 512 * 1024
  @never_text ~w(image/ audio/ video/ font/ application/pdf application/zip)
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
    folder = Vaults.Path.normalize(path || "")

    with {:ok, vault} <- vault(scope, vault, :read),
         :ok <- reachable(vault, folder) do
      inside = vault |> entries() |> within(folder)

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
         %Entry{kind: kind, path: path} <- entries(vault),
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

      search =
        Task.async(fn -> search_entries(vault, glob, pattern, context) end)

      case Task.yield(search, search_time()) || Task.shutdown(search, :brutal_kill) do
        {:ok, found} -> {:ok, found}
        _slow -> {:error, :search_timeout}
      end
    end
  end

  @spec query_notes(Scope.t(), vault_reference(), keyword()) ::
          {:ok, Bases.table() | Bases.groups() | Bases.places()} | error()
  def query_notes(scope, vault, opts \\ []) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, definition} <- definition(vault, opts[:base]),
         notes = notes(vault, opts[:folder]),
         {:ok, near} <- near(notes, opts[:near], opts[:coordinates]) do
      query =
        opts
        |> Keyword.take(
          ~w(view folder where radius_km coordinates sort select group_by limit as)a
        )
        |> Keyword.merge(definition: definition, near: near)
        |> Enum.reject(fn {_name, value} -> value in [nil, "", []] end)

      with {:error, message} <- Bases.query(notes, query), do: {:error, {:invalid_query, message}}
    end
  end

  @spec list_properties(Scope.t(), vault_reference(), String.t() | nil) ::
          {:ok, %{notes: non_neg_integer(), properties: [map()]}} | error()
  def list_properties(scope, vault, folder \\ nil) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      notes = notes(vault, folder)
      {:ok, %{notes: length(notes), properties: Bases.survey(notes)}}
    end
  end

  @spec read_file(Scope.t(), vault_reference(), String.t(), keyword()) :: {:ok, map()} | error()
  def read_file(scope, vault, path, opts \\ [])

  def read_file(scope, vault, path, [{:encoding, "base64"} | opts]) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- entry(vault, path),
         {:ok, bytes} <- raw(entry, opts[:version]) do
      {:ok,
       %{
         kind: :bytes,
         path: entry.path,
         type: MIME.from_path(entry.path),
         bytes: byte_size(bytes),
         data: Base.encode64(bytes)
       }}
    end
  end

  def read_file(scope, vault, path, opts) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- entry(vault, path) do
      case text(entry, opts[:version]) do
        {:ok, text} ->
          part = Text.slice(text, max(opts[:offset] || 1, 1), max(opts[:limit] || @read_lines, 1))
          {:ok, Map.merge(part, %{path: entry.path, kind: :note, rev: Text.rev(text)})}

        {:error, :not_a_note} when entry.kind == :blob ->
          {:ok, Map.put(attachment(entry), :download, download(scope, entry, entry.size))}

        refused ->
          refused
      end
    end
  end

  defp search_entries(vault, glob, pattern, context) do
    for(
      %Entry{} = entry <- entries(vault),
      searchable?(entry),
      Regex.match?(glob, entry.path),
      do: entry
    )
    |> Stream.chunk_every(@search_batch)
    |> Stream.flat_map(fn batch ->
      notes = Sync.texts(for %Entry{kind: :doc, id: id} <- batch, do: id)

      for entry <- batch, {:ok, text} <- [searched(entry, notes)] do
        %{path: entry.path, matches: Text.search(text, pattern, context)}
      end
    end)
    |> Stream.reject(&(&1.matches == []))
    |> Enum.take(@searched_files)
  end

  @spec outline(Scope.t(), vault_reference(), String.t()) :: {:ok, map()} | error()
  def outline(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- note(vault, path),
         {:ok, text} <- content(entry) do
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

    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :folder} ->
          {:error, :not_a_note}

        %Entry{} = entry ->
          cond do
            opts[:if_rev] ->
              written(:updated, entry, rewrite(scope, entry, opts[:if_rev], replace))

            opts[:overwrite] ->
              written(:updated, entry, overwrite(scope, entry, content))

            true ->
              {:error, :unguarded}
          end

        nil ->
          create_file(scope, vault, path, content, replace)
      end
    end
  end

  defp create_file(scope, vault, path, content, replace) do
    if Vaults.Path.kind_for(path) == :doc do
      with {:ok, entry} <- create(vault, path) do
        written(:created, entry, rewrite(scope, entry, nil, replace))
      end
    else
      with :ok <- may_hold_text(path),
           {:ok, entry} <- attach(vault, path, content) do
        written(:created, entry, {:ok, "", content})
      end
    end
  end

  @spec upload_link(Scope.t(), vault_reference(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | error()
  def upload_link(%Scope{user: user} = scope, vault, path, size, opts \\ []) do
    path = Vaults.Path.normalize(path)
    overwrite? = opts[:overwrite] == true
    note? = Vaults.Path.kind_for(path) == :doc

    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path),
         true <- Vaults.Path.valid?(path) || {:error, :invalid_path},
         true <- (is_integer(size) and size >= 0) || {:error, :invalid_size},
         true <-
           size <= if(note?, do: @written_bytes, else: Blobs.max_size()) || {:error, :too_large},
         :ok <- replaceable(Vaults.get_entry_by_path(vault.id, path), note?, overwrite?) do
      target =
        BabelSync.Transfers.upload_target(%{
          user_id: user.id,
          vault_id: vault.id,
          path: path,
          size: size,
          overwrite: overwrite?
        })

      {:ok, Map.merge(target, %{path: path, size: size})}
    end
  end

  @spec download_link(Scope.t(), vault_reference(), String.t()) :: {:ok, map()} | error()
  def download_link(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- entry(vault, path) do
      case entry do
        %Entry{kind: :folder} ->
          {:error, :not_a_note}

        %Entry{kind: :doc} ->
          with {:ok, text} <- content(entry),
               do: {:ok, Map.put(download(scope, entry, byte_size(text)), :path, entry.path)}

        %Entry{kind: :blob} ->
          {:ok, Map.put(download(scope, entry, entry.size), :path, entry.path)}
      end
    end
  end

  @spec place_upload(Scope.t(), Ecto.UUID.t(), String.t(), Path.t(), boolean()) ::
          {:ok, map()} | error()
  def place_upload(scope, vault_id, path, file, overwrite?) do
    with {:ok, vault} <- vault(scope, vault_id, :write),
         :ok <- reachable(vault, path) do
      if Vaults.Path.kind_for(path) == :doc do
        place_text(scope, vault, path, File.read!(file), overwrite?)
      else
        place_blob(vault, path, file, overwrite?)
      end
    end
  end

  defp place_text(scope, vault, path, text, overwrite?) do
    if String.valid?(text),
      do: write_file(scope, vault.id, path, text, overwrite: overwrite?),
      else: {:error, :not_text}
  end

  defp place_blob(vault, path, file, overwrite?) do
    with {:ok, blob} <- put_blob_file(vault.id, file) do
      attrs = %{blob_hash: blob.hash, size: blob.size}

      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :blob} = entry when overwrite? ->
          with {:ok, entry} <- Vaults.update_entry(entry, attrs),
               do:
                 {:ok,
                  %{outcome: :updated, path: entry.path, kind: :attachment, bytes: blob.size}}

        %Entry{kind: :blob} ->
          {:error, :unguarded}

        %Entry{} ->
          {:error, :not_an_attachment}

        nil ->
          case Vaults.create_entry(vault.id, Map.merge(attrs, %{path: path, kind: :blob})) do
            {:ok, entry} ->
              {:ok, %{outcome: :created, path: entry.path, kind: :attachment, bytes: blob.size}}

            {:error, {:exists, _entry}} ->
              {:error, :exists}

            {:error, %Ecto.Changeset{}} ->
              {:error, :invalid_path}
          end
      end
    end
  end

  defp put_blob_file(vault_id, file) do
    case Blobs.put_file(vault_id, file) do
      {:ok, blob} ->
        {:ok, blob}

      {:error, :too_large} ->
        {:error, :too_large}

      {:error, reason} ->
        Logger.error("could not store an uploaded file: #{inspect(reason)}")
        {:error, :storage_unavailable}
    end
  end

  defp replaceable(nil, _note?, _overwrite?), do: :ok
  defp replaceable(%Entry{kind: :folder}, _note?, _overwrite?), do: {:error, :not_a_folder_target}
  defp replaceable(%Entry{kind: :doc}, true, true), do: :ok
  defp replaceable(%Entry{kind: :blob}, false, true), do: :ok
  defp replaceable(%Entry{}, _note?, true), do: {:error, :not_an_attachment}
  defp replaceable(%Entry{}, _note?, false), do: {:error, :unguarded}

  @spec write_binary(Scope.t(), vault_reference(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | error()
  def write_binary(scope, vault, path, encoded, opts \\ []) do
    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path),
         :ok <- attachment_path(path),
         {:ok, bytes} <- decoded(encoded) do
      overwrite? = opts[:overwrite] == true

      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :blob} = entry when overwrite? ->
          with :ok <- store(entry, bytes), do: {:ok, stored(:updated, entry, bytes)}

        %Entry{kind: :blob} ->
          {:error, :unguarded}

        %Entry{} ->
          {:error, :not_an_attachment}

        nil ->
          with {:ok, entry} <- attach(vault, path, bytes),
               do: {:ok, stored(:created, entry, bytes)}
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

    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :folder} ->
          {:error, :not_a_note}

        %Entry{} = entry ->
          written(:updated, entry, rewrite(scope, entry, nil, &Text.append(&1, content, heading)))

        nil when is_nil(heading) ->
          write_file(scope, vault.id, path, content)

        nil ->
          {:error, :not_found}
      end
    end
  end

  @spec create_directory(Scope.t(), vault_reference(), String.t()) :: {:ok, String.t()} | error()
  def create_directory(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path) do
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
         :ok <- reachable(vault, from),
         :ok <- reachable(vault, to),
         {:ok, moving} <- named(vault, from),
         :ok <- move_each(moving, from, to) do
      {:ok, to}
    end
  end

  @spec delete_file(Scope.t(), vault_reference(), String.t()) :: {:ok, [String.t()]} | error()
  def delete_file(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path),
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
       for entry <- Vaults.list_trash(vault.id), not hidden?(vault, entry.path) do
         %{path: entry.path, kind: kind(entry), deleted_at: entry.deleted_at}
       end}
    end
  end

  @spec restore_file(Scope.t(), vault_reference(), String.t()) :: {:ok, String.t()} | error()
  def restore_file(scope, vault, path) do
    path = Vaults.Path.normalize(path)

    with {:ok, vault} <- vault(scope, vault, :write),
         :ok <- reachable(vault, path),
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
          nil -> vault |> changes_since(0) |> Enum.take(-@recent_changes)
          since -> vault |> changes_since(since) |> Enum.take(@listed)
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
    with :ok <- reachable(vault, path) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{} = entry -> {:ok, entry}
        nil -> {:error, :not_found}
      end
    end
  end

  defp entries(vault),
    do: vault.id |> Vaults.list_entries() |> Enum.reject(&hidden?(vault, &1.path))

  defp changes_since(vault, seq),
    do: vault.id |> Vaults.changes_since(seq) |> Enum.reject(&hidden?(vault, &1.path))

  defp reachable(vault, path),
    do: if(hidden?(vault, path), do: {:error, :off_limits}, else: :ok)

  defp hidden?(%Vault{agents_see_config: true}, _path), do: false

  defp hidden?(%Vault{}, path) do
    [top | _rest] = path |> Vaults.Path.normalize() |> String.split("/", parts: 2)
    String.downcase(top) == ".obsidian"
  end

  defp notes(vault, folder) do
    for(
      %Entry{kind: kind} = entry <- entries(vault),
      kind != :folder,
      Bases.Note.in_folder?(%Bases.Note{path: entry.path}, folder || ""),
      do: entry
    )
    |> Bases.Index.notes()
  end

  defp definition(_vault, base) when base in [nil, ""], do: {:ok, nil}

  defp definition(vault, path) do
    with {:ok, entry} <- entry(vault, path),
         {:ok, text} <- content(entry) do
      with {:error, message} <- Bases.Definition.parse(text),
           do: {:error, {:invalid_query, message}}
    end
  end

  defp near(_notes, near, _property) when near in [nil, ""], do: {:ok, nil}

  defp near(notes, near, property) do
    place = Enum.find(notes, &(&1.path == near))

    case Bases.Geo.point(near) || (place && Bases.Geo.of(place.properties, property)) do
      nil -> {:error, :no_coordinates}
      point -> {:ok, point}
    end
  end

  defp note(vault, path) do
    with {:ok, entry} <- entry(vault, path),
         {:ok, _text} <- content(entry) do
      {:ok, entry}
    end
  end

  defp content(%Entry{kind: :doc} = entry), do: {:ok, Sync.text(entry.id)}

  defp content(%Entry{kind: :blob, size: size, blob_hash: hash} = entry)
       when size <= @text_bytes and is_binary(hash) do
    with %Blobs.Blob{} = blob <- Blobs.get(entry.vault_id, hash),
         bytes = Blobs.read(blob),
         true <- String.valid?(bytes) and not String.contains?(bytes, <<0>>) do
      {:ok, Sync.normalize(bytes)}
    else
      _binary -> {:error, :not_a_note}
    end
  end

  defp content(%Entry{}), do: {:error, :not_a_note}

  defp searched(%Entry{kind: :doc, id: id}, notes), do: Map.fetch(notes, id)
  defp searched(%Entry{} = entry, _notes), do: content(entry)

  defp searchable?(%Entry{kind: :doc}), do: true

  defp searchable?(%Entry{kind: :blob, size: size, path: path}),
    do: size <= @searched_bytes and may_hold_text(path) == :ok

  defp searchable?(%Entry{}), do: false

  defp may_hold_text(path) do
    if String.starts_with?(MIME.from_path(path), @never_text),
      do: {:error, :not_a_note},
      else: :ok
  end

  defp named(_vault, ""), do: {:error, :invalid_path}

  defp named(vault, path) do
    case Vaults.get_entry_by_path(vault.id, path) do
      %Entry{} = entry ->
        {:ok, [entry]}

      nil ->
        case vault |> entries() |> within(path) do
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

  defp text(entry, nil), do: content(entry)
  defp text(%Entry{kind: kind}, _version_id) when kind != :doc, do: {:error, :not_found}

  defp text(entry, version_id) do
    case Sync.get_version(entry.id, version_id) do
      %Version{content: content} -> {:ok, content}
      nil -> {:error, :not_found}
    end
  end

  defp raw(%Entry{kind: :folder}, _version), do: {:error, :not_a_note}

  defp raw(%Entry{kind: :blob} = entry, nil) do
    case entry.blob_hash && Blobs.get(entry.vault_id, entry.blob_hash) do
      %Blobs.Blob{size: size} when size > @written_bytes -> {:error, :too_large_to_read}
      %Blobs.Blob{} = blob -> {:ok, Blobs.read(blob)}
      _missing -> {:error, :not_found}
    end
  end

  defp raw(entry, version) do
    with {:ok, text} <- text(entry, version) do
      if byte_size(text) > @written_bytes, do: {:error, :too_large_to_read}, else: {:ok, text}
    end
  end

  defp download(%Scope{user: user}, %Entry{} = entry, size) do
    BabelSync.Transfers.download_target(
      %{user_id: user.id, vault_id: entry.vault_id, entry_id: entry.id},
      %{
        name: Elixir.Path.basename(entry.path),
        mimeType: MIME.from_path(entry.path),
        size: size
      }
    )
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

  defp attachment_path(path) do
    if Vaults.Path.kind_for(path) == :blob, do: :ok, else: {:error, :not_an_attachment}
  end

  defp decoded(encoded) do
    case Base.decode64(encoded, ignore: :whitespace, padding: false) do
      {:ok, bytes} when byte_size(bytes) <= @written_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, :too_large}
      :error -> {:error, :invalid_encoding}
    end
  end

  defp stored(outcome, %Entry{path: path}, bytes) do
    %{
      outcome: outcome,
      path: path,
      kind: :attachment,
      type: MIME.from_path(path),
      bytes: byte_size(bytes)
    }
  end

  defp attach(vault, path, content) do
    with {:ok, blob} <- put_blob(vault.id, content) do
      attrs = %{path: path, kind: :blob, blob_hash: blob.hash, size: blob.size}

      case Vaults.create_entry(vault.id, attrs) do
        {:ok, entry} -> {:ok, entry}
        {:error, {:exists, _entry}} -> {:error, :exists}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid_path}
      end
    end
  end

  defp overwrite(scope, %Entry{kind: :doc} = entry, content),
    do: rewrite(scope, entry, nil, fn _current -> {:ok, content} end)

  defp overwrite(_scope, %Entry{kind: :blob} = entry, content) do
    with {:ok, old} <- content(entry),
         :ok <- store(entry, content) do
      {:ok, old, content}
    end
  end

  defp store(%Entry{} = entry, content) do
    with {:ok, blob} <- put_blob(entry.vault_id, content),
         {:ok, _entry} <- Vaults.update_entry(entry, %{blob_hash: blob.hash, size: blob.size}) do
      :ok
    end
  end

  defp put_blob(vault_id, content) do
    case Blobs.put(vault_id, content) do
      {:ok, blob} ->
        {:ok, blob}

      {:error, :too_large} ->
        {:error, :too_large}

      {:error, reason} ->
        Logger.error("could not store an agent's file: #{inspect(reason)}")
        {:error, :storage_unavailable}
    end
  end

  defp search_time, do: Application.get_env(:babel_sync, __MODULE__, [])[:search_ms] || 10_000

  defp guarded(if_rev, change) do
    fn current ->
      current_rev = Text.rev(current)

      if if_rev in [nil, "", current_rev],
        do: change.(current),
        else: {:error, {:stale, current_rev}}
    end
  end

  defp rewrite(%Scope{}, %Entry{kind: :blob} = entry, if_rev, change) do
    with {:ok, old} <- content(entry),
         {:ok, new} <- guarded(if_rev, change).(old),
         :ok <- store(entry, new) do
      {:ok, old, new}
    end
  end

  defp rewrite(%Scope{user: user}, %Entry{id: id}, if_rev, change) do
    guarded = guarded(if_rev, change)

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
