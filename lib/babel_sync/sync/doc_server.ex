defmodule BabelSync.Sync.DocServer do
  @moduledoc """
  Owns the live Yjs document of one note.

  Every update is written to the store before it is acknowledged or
  broadcast, so the process can stop at any time and be rebuilt from the
  database. It stops by itself after a period without activity.

  In a cluster every node that needs a note runs its own process for
  it, and the processes are replicas of one document rather than one
  owner and its callers. An update accepted on one node reaches the
  others as the same broadcast its clients receive, and merges there as
  any Yjs update does. A broadcast can be missed, when nodes lose sight
  of each other or one has just joined, so a replica also reads what the
  store holds that it has not applied: before it saves a version, before
  it compacts, when a node appears, and every few seconds for as long as
  the server is one of several. The last of these is what bounds how
  stale a note can be on a node cut off from the others, since nothing
  tells a node that an announcement never reached it. Nothing is ever
  asked of a
  process on another node, so nodes running different versions of the
  code can share a note.
  """

  use GenServer, restart: :temporary

  alias BabelSync.Sync.{Store, TextDiff}
  alias BabelSync.Vaults

  @text_name "content"
  @empty_update <<0, 0>>
  @membership_settles_ms 5_000
  @used_at {__MODULE__, :used_at}

  defstruct [
    :entry_id,
    :doc,
    :text,
    :settle_timer,
    :unsettled_since,
    :state_at,
    applied: [],
    taken_in: 0,
    settled: 0,
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
    :ok = BabelSync.Sync.subscribe(entry_id)
    :ok = :net_kernel.monitor_nodes(true)
    if BabelSync.Cluster.enabled?(), do: keep_up_later()
    doc = Yex.Doc.new()
    text = Yex.Doc.get_text(doc, @text_name)
    server = take_in(%__MODULE__{entry_id: entry_id, doc: doc, text: text})

    {:ok, %{server | versioned_hash: settled_hash(entry_id, Yex.Text.to_string(text))},
     {:continue, :settle}}
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

  def handle_info({:doc_update, _entry_id, update, _origin}, server) do
    Yex.apply_update(server.doc, update)
    {:noreply, server, rest_of_idle()}
  end

  def handle_info({:nodeup, _node}, server) do
    Process.send_after(self(), :catch_up, @membership_settles_ms)
    {:noreply, catch_up(server), rest_of_idle()}
  end

  def handle_info(:catch_up, server), do: {:noreply, catch_up(server), rest_of_idle()}

  def handle_info(:keep_up, server) do
    if BabelSync.Cluster.enabled?(), do: keep_up_later()
    {:noreply, catch_up(server), rest_of_idle()}
  end

  def handle_info({:EXIT, _from, reason}, server), do: {:stop, reason, server}
  def handle_info(_elsewhere, server), do: {:noreply, server, rest_of_idle()}

  defp keep_up_later, do: Process.send_after(self(), :keep_up, config(:keep_up_every))

  defp take_in(server) do
    {state, state_at, updates} = Store.news(server.entry_id, server.state_at, server.applied)

    Enum.each(
      List.wrap(state) ++ Enum.map(updates, &elem(&1, 1)),
      &(:ok = Yex.apply_update(server.doc, &1))
    )

    ids = Enum.map(updates, &elem(&1, 0))

    %{
      server
      | state_at: state_at,
        applied: ids ++ server.applied,
        taken_in: Enum.max([server.taken_in | ids])
    }
  end

  defp catch_up(server) do
    before = Yex.encode_state_vector!(server.doc)
    server = take_in(server)

    with {:ok, missed} when missed != @empty_update <-
           Yex.encode_state_as_update(server.doc, before) do
      Phoenix.PubSub.local_broadcast_from(
        BabelSync.PubSub,
        self(),
        BabelSync.Sync.topic(server.entry_id),
        {:doc_update, server.entry_id, missed, self()}
      )
    end

    server
  end

  defp record(server, update, origin, author) do
    id = Store.append(server.entry_id, update)

    Phoenix.PubSub.broadcast_from(
      BabelSync.PubSub,
      self(),
      BabelSync.Sync.topic(server.entry_id),
      {:doc_update, server.entry_id, update, origin}
    )

    server = %{
      server
      | applied: [id | server.applied],
        taken_in: max(server.taken_in, id),
        last_author: author
    }

    server = if length(server.applied) >= compact_after(), do: compact(server), else: server
    schedule_settle(server)
  end

  defp compact(server) do
    server = catch_up(server)
    full_state = Yex.encode_state_as_update!(server.doc)

    case Store.compact(server.entry_id, full_state, server.state_at, server.applied) do
      {:ok, state_at} -> %{server | applied: [], state_at: state_at}
      {:error, :stale} -> server
    end
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
    server = catch_up(server)
    content = Yex.Text.to_string(server.text)
    hash = Store.hash(content)

    with true <- hash != server.versioned_hash,
         %Vaults.Entry{} = entry when entry.content_hash != hash <-
           Vaults.get_entry(server.entry_id) do
      Store.put_version(server.entry_id, content, server.last_author)
      Vaults.update_entry(entry, %{content_hash: hash, size: byte_size(content)})
    end

    if server.taken_in > server.settled, do: Store.settle(server.entry_id, server.taken_in)

    %{
      server
      | settle_timer: nil,
        unsettled_since: nil,
        versioned_hash: hash,
        settled: server.taken_in
    }
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

  defp idle_timeout do
    Process.put(@used_at, System.monotonic_time(:millisecond))
    config(:idle_timeout)
  end

  defp rest_of_idle do
    used_at = Process.get(@used_at) || System.monotonic_time(:millisecond)
    max(used_at + config(:idle_timeout) - System.monotonic_time(:millisecond), 0)
  end

  defp settle_after, do: config(:settle_after)
  defp settle_within, do: config(:settle_within)
  defp compact_after, do: config(:compact_after)
end
