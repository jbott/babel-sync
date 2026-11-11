defmodule BabelSyncWeb.VaultChannel do
  @moduledoc """
  A vault's tree: what exists, and every create, rename, delete and
  attachment change as it happens.

  A client joins with the last `seq` it saw and receives what changed
  since, deletions included. A new client, or one away for so long that
  deletions it has not seen were purged from the trash, receives the
  whole live tree instead, marked `complete`: whatever it knows that is
  not listed no longer exists.
  """

  use BabelSyncWeb, :channel

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Blobs, Sync, Vaults}
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.EntryJSON

  @impl true
  def join("vault:" <> vault_id, params, socket) do
    scope = socket.assigns.scope

    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         since when is_integer(since) and since >= 0 <- Map.get(params, "since", 0) do
      :ok = Vaults.subscribe(vault_id)
      vault = Vaults.get_vault(vault_id)

      complete = since == 0 or since < vault.purged_seq

      entries =
        if complete,
          do: Vaults.list_entries(vault_id),
          else: Vaults.changes_since(vault_id, since)

      reply = %{
        seq: vault.seq,
        count: Vaults.count_entries(vault_id),
        complete: complete,
        name: vault.name,
        writable: Scope.authorize(scope, vault_id, :write) == :ok,
        entries: Enum.map(entries, &EntryJSON.entry/1)
      }

      {:ok, reply, assign(socket, :vault_id, vault_id)}
    else
      _denied -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in(event, params, socket) do
    with :ok <- Scope.authorize(socket.assigns.scope, socket.assigns.vault_id, :write),
         {:ok, reply} <- handle(event, params, socket) do
      {:reply, {:ok, reply}, socket}
    else
      {:error, reason} -> {:reply, {:error, error(reason)}, socket}
    end
  end

  @impl true
  def handle_info({:entry_changed, %Entry{} = entry}, socket) do
    push(socket, "entry", EntryJSON.entry(entry))
    {:noreply, socket}
  end

  defp handle("create", %{"path" => path} = params, socket) when is_binary(path) do
    kind = kind(params["kind"]) || Vaults.Path.kind_for(path)

    with {:ok, attrs} <- content_attrs(kind, params, socket),
         {:ok, entry} <- Vaults.create_entry(socket.assigns.vault_id, Map.put(attrs, :path, path)) do
      if kind == :doc and is_binary(params["text"]) do
        :ok = Sync.replace_text(entry.id, params["text"], author_id: user_id(socket))
        :ok = Sync.flush(entry.id)
      end

      {:ok, %{entry: EntryJSON.entry(Vaults.get_entry(entry.id))}}
    end
  end

  defp handle("rename", %{"id" => id, "path" => path}, socket) when is_binary(path) do
    with {:ok, entry} <- fetch(id, socket),
         {:ok, moved} <- Vaults.rename_entry(entry, path) do
      {:ok, %{entries: Enum.map(moved, &EntryJSON.entry/1)}}
    end
  end

  defp handle("delete", %{"id" => id}, socket) do
    with {:ok, entry} <- fetch(id, socket),
         {:ok, deleted} <- Vaults.delete_entry(entry) do
      {:ok, %{entries: Enum.map(deleted, &EntryJSON.entry/1)}}
    end
  end

  defp handle("set_blob", %{"id" => id, "blob_hash" => hash} = params, socket) do
    with {:ok, %Entry{kind: :blob} = entry} <- fetch(id, socket),
         :ok <- expect_base(entry, params),
         {:ok, attrs} <- content_attrs(:blob, %{"blob_hash" => hash}, socket),
         {:ok, entry} <- Vaults.update_entry(entry, attrs) do
      {:ok, %{entry: EntryJSON.entry(entry)}}
    else
      {:ok, %Entry{kind: :doc} = note} -> {:error, {:conflict, note}}
      {:ok, %Entry{}} -> {:error, :not_a_blob}
      error -> error
    end
  end

  defp handle(_event, _params, _socket), do: {:error, :bad_request}

  defp content_attrs(:blob, %{"blob_hash" => hash}, socket) when is_binary(hash) do
    case Blobs.get(socket.assigns.vault_id, hash) do
      %Blobs.Blob{size: size} -> {:ok, %{kind: :blob, blob_hash: hash, size: size}}
      nil -> {:error, :unknown_blob}
    end
  end

  defp content_attrs(:blob, _params, _socket), do: {:error, :bad_request}
  defp content_attrs(kind, _params, _socket), do: {:ok, %{kind: kind}}

  defp expect_base(entry, %{"base_hash" => base}) when base != entry.blob_hash do
    {:error, {:conflict, entry}}
  end

  defp expect_base(_entry, _params), do: :ok

  defp fetch(id, socket) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{vault_id: vault_id, deleted_at: nil} = entry <- Vaults.get_entry(id),
         true <- vault_id == socket.assigns.vault_id do
      {:ok, entry}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp kind("doc"), do: :doc
  defp kind("blob"), do: :blob
  defp kind("folder"), do: :folder
  defp kind(_other), do: nil

  defp user_id(socket), do: socket.assigns.scope.user.id

  defp error({:exists, entry}), do: %{reason: "exists", entry: EntryJSON.entry(entry)}
  defp error({:conflict, entry}), do: %{reason: "conflict", entry: EntryJSON.entry(entry)}
  defp error(%Ecto.Changeset{}), do: %{reason: "invalid"}
  defp error(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
end
