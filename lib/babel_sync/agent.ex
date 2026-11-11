defmodule BabelSync.Agent do
  @moduledoc """
  What an AI agent can do in a vault, expressed on paths and plain text.

  Every function takes the caller's scope and checks it. Writes go through
  the same Yjs documents people are editing, as minimal edits, so an agent
  changing a note does not overwrite what someone is typing in it.
  """

  import Ecto.Query

  alias BabelSync.Accounts.Scope
  alias BabelSync.Repo
  alias BabelSync.Sync
  alias BabelSync.Sync.Version
  alias BabelSync.Vaults
  alias BabelSync.Vaults.{Entry, Vault}

  @type error ::
          {:error,
           :forbidden
           | :vault_not_found
           | :ambiguous_vault
           | :not_found
           | :not_a_note
           | :exists
           | :invalid_path
           | :no_match
           | :ambiguous_match}

  @search_limit 50
  @snippet_radius 80

  @spec list_vaults(Scope.t()) :: [%{id: String.t(), name: String.t(), role: atom()}]
  def list_vaults(%Scope{user: user}) do
    for vault <- Vaults.list_vaults(user) do
      %{id: vault.id, name: vault.name, role: Vaults.role(user, vault.id)}
    end
  end

  @spec list_files(Scope.t(), String.t() | nil, String.t() | nil) :: {:ok, [map()]} | error()
  def list_files(scope, vault, folder \\ nil) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      prefix = folder && Vaults.Path.normalize(folder) <> "/"

      files =
        for entry <- Vaults.list_entries(vault.id),
            is_nil(prefix) or prefix == "/" or String.starts_with?(entry.path, prefix) do
          %{path: entry.path, kind: entry.kind, size: entry.size, updated_at: entry.updated_at}
        end

      {:ok, files}
    end
  end

  @spec read_note(Scope.t(), String.t() | nil, String.t()) :: {:ok, String.t()} | error()
  def read_note(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- note(vault, path) do
      {:ok, Sync.text(entry.id)}
    end
  end

  @spec write_note(Scope.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, :created | :updated} | error()
  def write_note(scope, vault, path, content) do
    with {:ok, vault} <- vault(scope, vault, :write) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :doc} = entry ->
          replace(scope, entry, content)
          {:ok, :updated}

        %Entry{} ->
          {:error, :not_a_note}

        nil ->
          with {:ok, entry} <- create(vault, path) do
            replace(scope, entry, content)
            {:ok, :created}
          end
      end
    end
  end

  @spec edit_note(Scope.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, :updated} | error()
  def edit_note(scope, vault, path, old_text, new_text) do
    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, entry} <- note(vault, path) do
      current = Sync.text(entry.id)
      old_text = Sync.normalize(old_text)

      case old_text != "" && String.split(current, old_text) do
        [before, rest] ->
          replace(scope, entry, before <> Sync.normalize(new_text) <> rest)
          {:ok, :updated}

        [_whole] ->
          {:error, :no_match}

        _many_or_empty ->
          {:error, :ambiguous_match}
      end
    end
  end

  @spec append_note(Scope.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, :created | :updated} | error()
  def append_note(scope, vault, path, content) do
    with {:ok, vault} <- vault(scope, vault, :write) do
      case Vaults.get_entry_by_path(vault.id, path) do
        %Entry{kind: :doc} = entry ->
          current = Sync.text(entry.id)
          separator = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
          replace(scope, entry, current <> separator <> content)
          {:ok, :updated}

        %Entry{} ->
          {:error, :not_a_note}

        nil ->
          write_note(scope, vault.id, path, content)
      end
    end
  end

  @spec move_file(Scope.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | error()
  def move_file(scope, vault, from, to) do
    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, entry} <- entry(vault, from) do
      case Vaults.rename_entry(entry, to) do
        {:ok, moved} -> {:ok, Enum.find(moved, &(&1.id == entry.id)).path}
        {:error, {:exists, _entry}} -> {:error, :exists}
        {:error, %Ecto.Changeset{}} -> {:error, :invalid_path}
      end
    end
  end

  @spec delete_file(Scope.t(), String.t() | nil, String.t()) :: {:ok, [String.t()]} | error()
  def delete_file(scope, vault, path) do
    with {:ok, vault} <- vault(scope, vault, :write),
         {:ok, entry} <- entry(vault, path),
         {:ok, deleted} <- Vaults.delete_entry(entry) do
      {:ok, Enum.map(deleted, & &1.path)}
    end
  end

  @spec search_notes(Scope.t(), String.t() | nil, String.t()) :: {:ok, [map()]} | error()
  def search_notes(scope, vault, query) do
    with {:ok, vault} <- vault(scope, vault, :read) do
      needle = String.downcase(query)
      pattern = "%" <> escape_like(needle) <> "%"

      latest =
        from v in Version,
          group_by: v.entry_id,
          select: %{entry_id: v.entry_id, id: max(v.id)}

      rows =
        Repo.all(
          from e in Entry,
            join: l in subquery(latest),
            on: l.entry_id == e.id,
            join: v in Version,
            on: v.id == l.id,
            where: e.vault_id == ^vault.id and is_nil(e.deleted_at),
            where:
              fragment("lower(?) LIKE ? ESCAPE '\\'", v.content, ^pattern) or
                fragment("lower(?) LIKE ? ESCAPE '\\'", e.path, ^pattern),
            order_by: e.path,
            limit: @search_limit,
            select: {e.path, v.content}
        )

      {:ok, for({path, content} <- rows, do: %{path: path, matches: snippets(content, needle)})}
    end
  end

  @spec history(Scope.t(), String.t() | nil, String.t()) :: {:ok, [map()]} | error()
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

  @spec read_version(Scope.t(), String.t() | nil, String.t(), integer()) ::
          {:ok, String.t()} | error()
  def read_version(scope, vault, path, version_id) do
    with {:ok, vault} <- vault(scope, vault, :read),
         {:ok, entry} <- note(vault, path),
         %Version{content: content} <- Sync.get_version(entry.id, version_id) do
      {:ok, content}
    else
      nil -> {:error, :not_found}
      error -> error
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

  defp replace(%Scope{user: user}, %Entry{id: id}, content) do
    :ok = Sync.replace_text(id, content, author_id: user.id, origin: :agent)
    :ok = Sync.flush(id)
  end

  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp snippets(content, needle) do
    lowered = String.downcase(content)

    case :binary.matches(lowered, needle) do
      [] ->
        []

      matches ->
        for {at, length} <- Enum.take(matches, 3) do
          first = max(at - @snippet_radius, 0)
          last = min(at + length + @snippet_radius, byte_size(content))

          content
          |> binary_part(first, last - first)
          |> String.chunk(:valid)
          |> Enum.filter(&String.valid?/1)
          |> Enum.join()
          |> String.trim()
        end
    end
  end
end
