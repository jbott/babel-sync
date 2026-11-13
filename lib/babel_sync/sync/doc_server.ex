defmodule BabelSync.Sync.DocServer do
  @moduledoc """
  Owns the live Yjs document of one note.

  Every update is written to the store before it is acknowledged or
  broadcast, so the process can stop at any time and be rebuilt from the
  database. It stops by itself after a period without activity.
  """

  use GenServer, restart: :temporary

  alias BabelSync.Sync.{Store, TextDiff}
  alias BabelSync.Vaults

  @text_name "content"
  @empty_update <<0, 0>>

  defstruct [
    :entry_id,
    :doc,
    :text,
    :settle_timer,
    :unsettled_since,
    applied: [],
    last_author: {nil, nil},
    versioned_hash: nil
  ]

  def start_link(entry_id) do
    GenServer.start_link(__MODULE__, entry_id, name: via(entry_id))
  end

  def via(entry_id), do: {:via, Registry, {BabelSync.Sync.Registry, entry_id}}

  @impl true
  def init(entry_id) do
    Process.flag(:trap_exit, true)
    doc = Yex.Doc.new()
    {state, updates} = Store.load(entry_id)

    Enum.each(
      List.wrap(state) ++ Enum.map(updates, &elem(&1, 1)),
      &(:ok = Yex.apply_update(doc, &1))
    )

    text = Yex.Doc.get_text(doc, @text_name)

    server = %__MODULE__{
      entry_id: entry_id,
      doc: doc,
      text: text,
      applied: Enum.map(updates, &elem(&1, 0)),
      versioned_hash: settled_hash(entry_id, Yex.Text.to_string(text))
    }

    {:ok, server, {:continue, :settle}}
  end

  @impl true
  def handle_continue(:settle, server), do: {:noreply, settle(server), idle_timeout()}

  @impl true
  def terminate(_reason, server), do: settle(server)

  defp settled_hash(entry_id, content) do
    case Vaults.get_entry(entry_id) do
      %Vaults.Entry{content_hash: nil} when content != "" -> nil
      %Vaults.Entry{content_hash: hash} when is_binary(hash) -> hash
      _new_or_gone -> Store.hash(content)
    end
  end

  @impl true
  def handle_call(:state_vector, _from, server) do
    {:reply, Yex.encode_state_vector!(server.doc), server, idle_timeout()}
  end

  def handle_call({:diff, state_vector}, _from, server) do
    {:reply, Yex.encode_state_as_update(server.doc, state_vector), server, idle_timeout()}
  end

  def handle_call(:text, _from, server) do
    {:reply, Yex.Text.to_string(server.text), server, idle_timeout()}
  end

  def handle_call({:apply_update, @empty_update, _origin, _author}, _from, server) do
    {:reply, :ok, server, idle_timeout()}
  end

  def handle_call({:apply_update, update, origin, author}, _from, server) do
    case Yex.apply_update(server.doc, update) do
      :ok -> {:reply, :ok, record(server, update, origin, author), idle_timeout()}
      {:error, reason} -> {:reply, {:error, reason}, server, idle_timeout()}
    end
  end

  def handle_call({:rewrite_text, rewrite, origin, author}, _from, server) do
    old_text = Yex.Text.to_string(server.text)

    case rewrite.(old_text) do
      {:ok, ^old_text} ->
        {:reply, {:ok, old_text, old_text}, server, idle_timeout()}

      {:ok, new_text} ->
        before = Yex.encode_state_vector!(server.doc)

        Yex.Doc.transaction(server.doc, fn ->
          old_text |> TextDiff.ops(new_text) |> apply_ops(server.text)
        end)

        {:ok, update} = Yex.encode_state_as_update(server.doc, before)

        {:reply, {:ok, old_text, new_text}, record(server, update, origin, author),
         idle_timeout()}

      {:error, _reason} = refused ->
        {:reply, refused, server, idle_timeout()}
    end
  end

  def handle_call(:flush, _from, server) do
    {:reply, :ok, settle(server), idle_timeout()}
  end

  def handle_call({Yex.Doc, :run, fun}, _from, server) do
    {:reply, fun.(), server, idle_timeout()}
  end

  @impl true
  def handle_info(:settle, server) do
    {:noreply, settle(%{server | settle_timer: nil}), idle_timeout()}
  end

  def handle_info(:timeout, server), do: {:stop, :normal, server}

  def handle_info({:EXIT, _from, reason}, server), do: {:stop, reason, server}

  defp record(server, update, origin, author) do
    id = Store.append(server.entry_id, update)

    Phoenix.PubSub.broadcast(
      BabelSync.PubSub,
      BabelSync.Sync.topic(server.entry_id),
      {:doc_update, server.entry_id, update, origin}
    )

    server = %{server | applied: [id | server.applied], last_author: author}
    server = if length(server.applied) >= compact_after(), do: compact(server), else: server
    schedule_settle(server)
  end

  defp compact(server) do
    :ok = Store.compact(server.entry_id, Yex.encode_state_as_update!(server.doc), server.applied)
    %{server | applied: []}
  end

  defp schedule_settle(server) do
    if server.settle_timer, do: Process.cancel_timer(server.settle_timer)
    now = System.monotonic_time(:millisecond)
    since = server.unsettled_since || now
    wait = min(settle_after(), max(since + settle_within() - now, 0))

    %{
      server
      | unsettled_since: since,
        settle_timer: Process.send_after(self(), :settle, wait)
    }
  end

  defp settle(server) do
    if server.settle_timer, do: Process.cancel_timer(server.settle_timer)
    content = Yex.Text.to_string(server.text)
    hash = Store.hash(content)

    if hash != server.versioned_hash do
      Store.put_version(server.entry_id, content, server.last_author)

      with %Vaults.Entry{} = entry <- Vaults.get_entry(server.entry_id) do
        Vaults.update_entry(entry, %{content_hash: hash, size: byte_size(content)})
      end
    end

    %{server | settle_timer: nil, unsettled_since: nil, versioned_hash: hash}
  end

  defp apply_ops(ops, text) do
    Enum.reduce(ops, 0, fn
      {:retain, count}, at ->
        at + count

      {:delete, count}, at ->
        :ok = Yex.Text.delete(text, at, count)
        at

      {:insert, inserted}, at ->
        :ok = Yex.Text.insert(text, at, inserted)
        at + byte_size(inserted)
    end)
  end

  defp config(key), do: Application.fetch_env!(:babel_sync, BabelSync.Sync)[key]
  defp idle_timeout, do: config(:idle_timeout)
  defp settle_after, do: config(:settle_after)
  defp settle_within, do: config(:settle_within)
  defp compact_after, do: config(:compact_after)
end
