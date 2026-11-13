defmodule BabelSyncWeb.DocChannel do
  @moduledoc """
  Live editing of one note.

  The client joins with its Yjs state vector and receives what it is
  missing together with the server's state vector, from which it sends
  back what the server is missing. After that both sides exchange updates
  as binary frames. Cursor and selection state ("awareness") is relayed
  between clients and never stored.
  """

  use BabelSyncWeb, :channel

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Sync, Vaults}
  alias BabelSync.Vaults.Entry

  @impl true
  def join("doc:" <> entry_id, params, socket) do
    scope = socket.assigns.scope

    with {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         %Entry{} = entry <- Vaults.get_entry(entry_id),
         :ok <- Scope.authorize(scope, entry.vault_id, :read),
         %Entry{kind: :doc, deleted_at: nil} <- entry,
         {:ok, client_vector} <- decode_vector(params["sv"]),
         :ok = Sync.subscribe(entry_id),
         {:ok, missing} <- Sync.diff(entry_id, client_vector) do
      reply = %{
        update: Base.encode64(missing),
        sv: Base.encode64(Sync.state_vector(entry_id)),
        writable: Scope.authorize_write(scope, entry.vault_id, entry.path) == :ok
      }

      {:ok, reply,
       assign(socket,
         entry_id: entry_id,
         vault_id: entry.vault_id,
         needed: if(Vaults.Path.holds_code?(entry.path), do: :admin, else: :write)
       )}
    else
      nil -> {:error, %{reason: "not_found"}}
      %Entry{deleted_at: nil} -> {:error, %{reason: "not_a_note"}}
      %Entry{} -> {:error, %{reason: "not_found"}}
      _denied -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("update", {:binary, update}, socket) do
    %{scope: scope, entry_id: entry_id, vault_id: vault_id, needed: needed} = socket.assigns

    with :ok <- Scope.authorize(scope, vault_id, needed),
         :ok <- still_a_note(entry_id),
         :ok <- Sync.apply_update(entry_id, update, [origin: self()] ++ Scope.author(scope)) do
      {:reply, :ok, socket}
    else
      {:error, :forbidden} -> {:reply, {:error, %{reason: "forbidden"}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "not_found"}}, socket}
      {:error, _invalid} -> {:reply, {:error, %{reason: "invalid"}}, socket}
    end
  end

  def handle_in("flush", _payload, socket) do
    %{scope: scope, entry_id: entry_id, vault_id: vault_id, needed: needed} = socket.assigns

    with :ok <- Scope.authorize(scope, vault_id, needed),
         :ok <- still_a_note(entry_id) do
      :ok = Sync.flush(entry_id)
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("awareness", {:binary, state}, socket) do
    Phoenix.PubSub.broadcast_from(
      BabelSync.PubSub,
      self(),
      Sync.topic(socket.assigns.entry_id),
      {:awareness, state}
    )

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "bad_request"}}, socket}
  end

  @impl true
  def handle_info({:doc_update, _entry_id, _update, origin}, socket) when origin == self() do
    {:noreply, socket}
  end

  def handle_info({:doc_update, _entry_id, update, _origin}, socket) do
    push(socket, "update", {:binary, update})
    {:noreply, socket}
  end

  def handle_info({:awareness, state}, socket) do
    push(socket, "awareness", {:binary, state})
    {:noreply, socket}
  end

  defp still_a_note(entry_id) do
    case Vaults.get_entry(entry_id) do
      %Entry{deleted_at: nil} -> :ok
      _deleted -> {:error, :not_found}
    end
  end

  defp decode_vector(nil), do: {:ok, nil}

  defp decode_vector(encoded) when is_binary(encoded) do
    with {:ok, vector} <- Base.decode64(encoded),
         {:ok, _clocks} <- Yex.decode_state_vector(vector) do
      {:ok, vector}
    end
  end

  defp decode_vector(_other), do: :error
end
