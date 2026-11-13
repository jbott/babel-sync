defmodule BabelSync.Sync do
  @moduledoc """
  Concurrent editing of note text.

  Each note is one Yjs document whose text lives under the key
  `"content"`. Clients exchange state vectors and updates with the server;
  whole-text changes from non-editor sources go through `replace_text/3`
  and `rewrite_text/3`, which turn them into minimal edits so they merge
  with concurrent typing. `rewrite_text/3` computes the new text from the
  current one inside the document's process, so nothing typed in between
  is lost, and returns the text before and after.

  Reading a note nobody has open takes its text from the last saved
  version, so that reading, searching or exporting does not bring every
  note it touches to life. A note with an edit stored after its last
  version, as a server that stopped without warning leaves behind, is
  opened instead, which saves that version.
  """

  alias BabelSync.Sync.{DocServer, Store}

  @type origin :: term()

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(entry_id), do: "doc:" <> entry_id

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(entry_id), do: Phoenix.PubSub.subscribe(BabelSync.PubSub, topic(entry_id))

  @spec state_vector(Ecto.UUID.t()) :: binary()
  def state_vector(entry_id), do: call(entry_id, :state_vector)

  @spec diff(Ecto.UUID.t(), binary() | nil) :: {:ok, binary()} | {:error, term()}
  def diff(entry_id, state_vector \\ nil), do: call(entry_id, {:diff, state_vector})

  @spec apply_update(Ecto.UUID.t(), binary(), keyword()) :: :ok | {:error, term()}
  def apply_update(entry_id, update, opts \\ []) do
    call(entry_id, {:apply_update, update, opts[:origin], author(opts)})
  end

  @spec text(Ecto.UUID.t()) :: String.t()
  def text(entry_id), do: texts([entry_id])[entry_id]

  @spec replace_text(Ecto.UUID.t(), String.t(), keyword()) :: :ok
  def replace_text(entry_id, text, opts \\ []) do
    text = normalize(text)
    {:ok, _before, _after} = rewrite_text(entry_id, fn _current -> {:ok, text} end, opts)
    :ok
  end

  @spec rewrite_text(
          Ecto.UUID.t(),
          (String.t() -> {:ok, String.t()} | {:error, reason}),
          keyword()
        ) :: {:ok, String.t(), String.t()} | {:error, reason}
        when reason: term()
  def rewrite_text(entry_id, rewrite, opts \\ []) do
    call(entry_id, {:rewrite_text, rewrite, opts[:origin], author(opts)})
  end

  @spec flush(Ecto.UUID.t()) :: :ok
  def flush(entry_id), do: call(entry_id, :flush)

  @spec live?(Ecto.UUID.t()) :: boolean()
  def live?(entry_id) do
    case Registry.lookup(BabelSync.Sync.Registry, entry_id) do
      [{server, _value}] -> Process.alive?(server)
      [] -> false
    end
  end

  @spec texts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def texts(entry_ids) do
    {live, idle} = Enum.split_with(entry_ids, &live?/1)
    saved = Store.latest_contents(idle -- Store.unsettled(idle))

    Map.new(live ++ (idle -- Map.keys(saved)), &{&1, call(&1, :text)}) |> Map.merge(saved)
  end

  defdelegate list_versions(entry_id), to: Store
  defdelegate get_version(entry_id, version_id), to: Store

  @spec restore_version(Ecto.UUID.t(), integer(), keyword()) :: :ok | {:error, :not_found}
  def restore_version(entry_id, version_id, opts \\ []) do
    case Store.get_version(entry_id, version_id) do
      nil -> {:error, :not_found}
      version -> replace_text(entry_id, version.content, opts)
    end
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(text), do: String.replace(text, "\r\n", "\n")

  defp author(opts), do: {opts[:author_id], opts[:author_app]}

  @attempts 4
  @patience :timer.seconds(30)

  defp call(entry_id, message, attempts \\ @attempts) do
    GenServer.call(server(entry_id), message, @patience)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal] and attempts > 1 ->
      call(entry_id, message, attempts - 1)
  end

  defp server(entry_id) do
    GenServer.whereis(DocServer.via(entry_id)) || started(entry_id)
  end

  defp started(entry_id) do
    case DynamicSupervisor.start_child(BabelSync.Sync.Supervisor, {DocServer, entry_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end
end
