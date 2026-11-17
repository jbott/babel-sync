defmodule BabelSync.Sources do
  @moduledoc """
  Scripts kept as files in a vault that the server runs to bring outside
  data into it.

  A vault names a folder for its sources. A `.js` file there that opens
  with a `/* source` comment is one, and it makes notes in the folder
  beside it that has its name. The file is a draft: anyone who can write
  to the vault, and any agent or device acting for them, can change it.

  What the comment says the script may do, and where the file is, are
  what an admin approves. Approving takes an admin signed in through a
  browser, which no agent grant or device is, however much of the vault
  it may write. Within what was approved the script itself may be
  edited freely and the next run uses it as it then is, unless the
  source is given a secret: then the script too runs only as approved.

  Whether sources run at all is the operator's choice, `BABELSYNC_SOURCES`.
  They are on where one person runs the server for themselves and off
  where it is shared, until turned on.
  """

  import Ecto.Query

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Blobs, Repo, Sync, Vaults}
  alias BabelSync.Sources.{Items, Run, RunNote, Script, Secrets, Source}
  alias BabelSync.Vaults.{Entry, Vault}

  @type draft :: %{
          entry: Entry.t(),
          name: String.t(),
          script: {:ok, Script.t()} | {:error, [String.t()]},
          source: Source.t() | nil,
          status: :new | :approved | :changed | :invalid
        }

  @largest 200_000

  @spec enabled?() :: boolean()
  def enabled?, do: limits()[:enabled]

  @spec limits() :: keyword()
  def limits, do: Application.fetch_env!(:babel_sync, __MODULE__)

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(vault_id), do: Phoenix.PubSub.subscribe(BabelSync.PubSub, topic(vault_id))

  @spec announce(Source.t()) :: :ok
  def announce(%Source{id: id, vault_id: vault_id}) do
    Phoenix.PubSub.broadcast(BabelSync.PubSub, topic(vault_id), {:source_changed, id})
  end

  defp topic(vault_id), do: "sources:" <> vault_id

  @spec browser_admin?(Scope.t(), Ecto.UUID.t()) :: boolean()
  def browser_admin?(%Scope{session_id: session, grant_id: nil} = scope, vault_id)
      when is_binary(session),
      do: Scope.authorize(scope, vault_id, :admin) == :ok

  def browser_admin?(%Scope{session_id: nil, grant_id: nil, app: nil} = scope, vault_id),
    do: BabelSync.Auth.open?() and Scope.authorize(scope, vault_id, :admin) == :ok

  def browser_admin?(%Scope{}, _vault_id), do: false

  @spec drafts(Ecto.UUID.t()) :: [draft()]
  def drafts(vault_id) do
    case Vaults.get_vault(vault_id) do
      %Vault{sources_folder: folder} when is_binary(folder) ->
        approved = Map.new(list(vault_id), &{&1.entry_id, &1})

        for %Entry{kind: kind, path: path} = entry <- Vaults.list_entries(vault_id),
            kind != :folder,
            Script.file?(path, folder),
            {:ok, text} <- [text(entry)],
            Script.source?(text) do
          draft(entry, Script.name(path, folder), Script.parse(text, path), approved[entry.id])
        end
        |> Enum.sort_by(& &1.name)

      _none ->
        []
    end
  end

  @doc """
  The source as its next run should have it: with the script as the file
  now has it, where that is allowed without asking, and otherwise as it
  was approved. A source whose file has left the sources folder does not
  run.
  """
  @spec current(Source.t()) :: {:ok, Source.t()} | {:error, String.t()}
  def current(%Source{} = source) do
    with %Entry{deleted_at: nil} = entry <- Vaults.get_entry(source.entry_id),
         %Vault{sources_folder: folder} <- Vaults.get_vault(source.vault_id),
         true <- Script.file?(entry.path, folder) do
      {:ok, followed(source, parsed(entry))}
    else
      _moved -> {:error, "this source's file is no longer in the vault's sources folder"}
    end
  end

  defp followed(%Source{} = source, {:ok, %Script{} = script}) do
    if not Script.gated?(script) and Script.manifest(script) == source.manifest and
         script.code != source.code do
      Repo.update_all(from(s in Source, where: s.id == ^source.id),
        set: [code: script.code, updated_at: DateTime.utc_now()]
      )

      %{source | code: script.code}
    else
      source
    end
  end

  defp followed(%Source{} = source, {:error, _problems}), do: source

  @doc """
  The text of a file in a vault that a script may hold, or `:error` when
  there is none at that path, or it is not text, or is too large.
  """
  @spec read(Ecto.UUID.t(), String.t()) :: {:ok, String.t()} | :error
  def read(vault_id, path) do
    case Vaults.get_entry_by_path(vault_id, path) do
      %Entry{deleted_at: nil} = entry -> text(entry)
      _none -> :error
    end
  end

  defp parsed(%Entry{} = entry) do
    case text(entry) do
      {:ok, text} -> Script.parse(text, entry.path)
      :error -> {:error, ["the file is not text, or is too large to be a script"]}
    end
  end

  defp text(%Entry{kind: :doc, id: id}), do: {:ok, Sync.text(id)}

  defp text(%Entry{kind: :blob, size: size, blob_hash: hash, vault_id: vault_id})
       when size <= @largest and is_binary(hash) do
    with %Blobs.Blob{} = blob <- Blobs.get(vault_id, hash),
         bytes = Blobs.read(blob),
         true <- String.valid?(bytes) do
      {:ok, Sync.normalize(bytes)}
    else
      _unreadable -> :error
    end
  end

  defp text(%Entry{}), do: :error

  defp draft(entry, name, script, source) do
    status =
      case {script, source} do
        {{:error, _problems}, _source} ->
          :invalid

        {{:ok, _script}, nil} ->
          :new

        {{:ok, script}, %Source{} = source} ->
          if(as_approved?(script, source), do: :approved, else: :changed)
      end

    %{entry: entry, name: name, script: script, source: source, status: status}
  end

  defp as_approved?(%Script{} = script, %Source{} = source) do
    Script.manifest(script) == source.manifest and
      (not Script.gated?(script) or script.code == source.code)
  end

  @spec list(Ecto.UUID.t()) :: [Source.t()]
  def list(vault_id), do: Repo.all(from s in Source, where: s.vault_id == ^vault_id)

  @spec get(Ecto.UUID.t()) :: Source.t() | nil
  def get(id), do: Repo.get(Source, id)

  @spec approve(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Source.t()} | {:error, :forbidden | :not_found | :changed | [String.t()]}
  def approve(%Scope{} = scope, entry_id, seen_hash) do
    with %Entry{deleted_at: nil} = entry <- Vaults.get_entry(entry_id),
         true <- browser_admin?(scope, entry.vault_id) || {:error, :forbidden},
         %Vault{sources_folder: folder} <- Vaults.get_vault(entry.vault_id),
         true <- Script.file?(entry.path, folder) || {:error, :not_found},
         {:ok, script} <- parsed(entry),
         true <- Script.hash(script) == seen_hash || {:error, :changed} do
      now = DateTime.utc_now()

      approved = [
        name: Script.name(entry.path, folder),
        manifest: Script.manifest(script),
        code: script.code,
        approved_hash: Script.hash(script),
        approved_by_id: scope.user.id,
        approved_at: now,
        next_run_at: script.schedule && now,
        updated_at: now
      ]

      source =
        Repo.insert!(
          struct!(
            Source,
            [vault_id: entry.vault_id, entry_id: entry.id, inserted_at: now] ++ approved
          ),
          on_conflict: [set: approved],
          conflict_target: :entry_id,
          returning: true
        )

      announce(source)
      {:ok, source}
    else
      nil -> {:error, :not_found}
      %Entry{} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec set_enabled(Scope.t(), Source.t(), boolean()) :: :ok | {:error, :forbidden}
  def set_enabled(scope, %Source{} = source, enabled?) do
    admin(scope, source, fn ->
      Repo.update_all(from(s in Source, where: s.id == ^source.id),
        set: [enabled: enabled?, updated_at: DateTime.utc_now()]
      )
    end)
  end

  @spec revoke(Scope.t(), Source.t()) :: :ok | {:error, :forbidden}
  def revoke(scope, %Source{} = source), do: admin(scope, source, fn -> Repo.delete!(source) end)

  @spec reinstate(Scope.t(), Source.t(), Ecto.UUID.t()) ::
          {:ok, :restored | :forgotten} | {:error, :forbidden | :not_found}
  def reinstate(scope, %Source{} = source, item_id) do
    if browser_admin?(scope, source.vault_id) do
      with {:ok, done} <- Items.reinstate(source, item_id) do
        announce(source)
        {:ok, done}
      end
    else
      {:error, :forbidden}
    end
  end

  @spec run_now(Scope.t(), Source.t()) :: :ok | {:error, :forbidden}
  def run_now(scope, %Source{} = source) do
    admin(scope, source, fn ->
      enqueue(source, "manual")
      BabelSync.Sources.Scheduler.poke()
    end)
  end

  @spec put_secret(Scope.t(), Source.t(), String.t(), String.t()) :: :ok | {:error, :forbidden}
  def put_secret(scope, %Source{} = source, name, value),
    do: admin(scope, source, fn -> Secrets.put(source, name, value) end)

  @spec delete_secret(Scope.t(), Source.t(), String.t()) :: :ok | {:error, :forbidden}
  def delete_secret(scope, %Source{} = source, name),
    do: admin(scope, source, fn -> Secrets.delete(source, name) end)

  defp admin(scope, %Source{} = source, change) do
    if browser_admin?(scope, source.vault_id) do
      change.()
      announce(source)
    else
      {:error, :forbidden}
    end
  end

  @spec enqueue(Source.t(), String.t()) :: Run.t()
  def enqueue(%Source{id: id}, trigger) do
    Repo.insert!(%Run{
      source_id: id,
      trigger: trigger,
      status: :queued,
      inserted_at: DateTime.utc_now()
    })
  end

  @spec runs(Source.t(), pos_integer()) :: [Run.t()]
  def runs(%Source{id: id}, limit \\ 10) do
    runs =
      Repo.all(
        from r in Run, where: r.source_id == ^id, order_by: [desc: r.inserted_at], limit: ^limit
      )

    noted =
      MapSet.new(
        Repo.all(
          from n in RunNote,
            where: n.run_id in ^Enum.map(runs, & &1.id),
            distinct: true,
            select: n.run_id
        )
      )

    Enum.map(runs, &%{&1 | noted: MapSet.member?(noted, &1.id)})
  end

  @spec run(Source.t(), String.t() | nil) :: Run.t() | nil
  def run(%Source{id: source_id}, id) do
    with true <- is_binary(id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get_by(Run, id: id, source_id: source_id)
    else
      _none -> nil
    end
  end

  @spec prune_runs(pos_integer()) :: non_neg_integer()
  def prune_runs(kept_per_source) do
    crowded =
      Repo.all(
        from r in Run,
          group_by: r.source_id,
          having: count(r.id) > ^kept_per_source,
          select: r.source_id
      )

    for source_id <- crowded, reduce: 0 do
      dropped ->
        oldest_kept =
          Repo.one(
            from r in Run,
              where: r.source_id == ^source_id,
              order_by: [desc: r.inserted_at],
              offset: ^(kept_per_source - 1),
              limit: 1,
              select: r.inserted_at
          )

        {count, _} =
          Repo.delete_all(
            from r in Run, where: r.source_id == ^source_id and r.inserted_at < ^oldest_kept
          )

        dropped + count
    end
  end
end
