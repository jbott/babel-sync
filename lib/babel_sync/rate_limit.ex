defmodule BabelSync.RateLimit do
  @moduledoc """
  Counts how often something has happened in the current window of time,
  for the few endpoints that anyone on the internet may call and that
  store something. Counts live in memory and start again with the server.
  """

  use GenServer

  @table __MODULE__
  @sweep :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, pos_integer()}
  def hit(key, limit, window_seconds) do
    now = System.system_time(:second)
    window = div(now, window_seconds)
    count = :ets.update_counter(@table, {key, window}, 1, {{key, window}, 0, window_seconds})

    if count <= limit,
      do: :ok,
      else: {:error, (window + 1) * window_seconds - now}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_, :"$2"}, [{:<, {:*, {:+, :"$1", 1}, :"$2"}, now}], [true]}
    ])

    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
