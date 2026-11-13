defmodule BabelSyncWeb.DocChannel do
  @moduledoc """
  Live editing of one note.

  Whether the person may write is settled when they join: a change of
  their role disconnects their sockets, and the note being renamed,
  deleted or restored arrives as it happens, so no frame needs a query.

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

    with :ok <- BabelSyncWeb.Protocol.check(params),
         {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         %Entry{} = entry <- Vaults.get_entry(entry_id),
         :ok <- Scope.authorize(scope, entry.vault_id, :read),
         %Entry{kind: :doc, deleted_at: nil} <- entry,
         {:ok, client_vector} <- decode_vector(params["sv"]),
         :ok = Sync.subscribe(entry_id),
         :ok = Vaults.subscribe(entry.vault_id),
         {:ok, missing} <- Sync.diff(entry_id, client_vector) do
      may = Map.new([:write, :admin], &{&1, Scope.authorize(scope, entry.vault_id, &1) == :ok})
      needed = needed(entry)

      reply = %{
        update: Base.encode64(missing),
        sv: Base.encode64(Sync.state_vector(entry_id)),
        writable: may[needed]
      }

      {:ok, reply, assign(socket, entry_id: entry_id, may: may, needed: needed, live: true)}
    else
      {:error, :upgrade} -> {:error, BabelSyncWeb.Protocol.refusal()}
      nil -> {:error, %{reason: "not_found"}}
      %Entry{deleted_at: nil} -> {:error, %{reason: "not_a_note"}}
      %Entry{} -> {:error, %{reason: "not_found"}}
      _denied -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("update", {:binary, update}, socket) do
    %{scope: scope, entry_id: entry_id} = socket.assigns

    with :ok <- writable(socket),
         :ok <- Sync.apply_update(entry_id, update, [origin: self()] ++ Scope.author(scope)) do
      {:reply, :ok, socket}
    else
      {:error, :forbidden} -> {:reply, {:error, %{reason: "forbidden"}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "not_found"}}, socket}
      {:error, _invalid} -> {:reply, {:error, %{reason: "invalid"}}, socket}
    end
  end

  def handle_in("flush", _payload, socket) do
    case writable(socket) do
      :ok ->
        :ok = Sync.flush(socket.assigns.entry_id)
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
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

  def handle_info({:entry_changed, %Entry{id: id} = entry}, %{assigns: %{entry_id: id}} = socket) do
    {:noreply, assign(socket, needed: needed(entry), live: entry.deleted_at == nil)}
  end

  def handle_info({:entry_changed, _another}, socket), do: {:noreply, socket}
  def handle_info(:vault_deleted, socket), do: {:stop, :normal, socket}

  def handle_info({:awareness, state}, socket) do
    push(socket, "awareness", {:binary, state})
    {:noreply, socket}
  end

  defp writable(%{assigns: %{live: false}}), do: {:error, :not_found}

  defp writable(%{assigns: %{may: may, needed: needed}}) do
    if may[needed], do: :ok, else: {:error, :forbidden}
  end

  defp needed(%Entry{path: path}) do
    if Vaults.Path.holds_code?(path), do: :admin, else: :write
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
