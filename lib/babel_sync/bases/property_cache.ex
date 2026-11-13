defmodule BabelSync.Bases.PropertyCache do
  @moduledoc """
  Remembers the properties read from each block of front matter, keyed
  by the block's text, so a base over thousands of notes does not parse
  the YAML of every note each time it is shown. Parsing is most of the
  cost of a base, and front matter changes far less often than bases are
  looked at.

  Keying by the text means a changed block is simply a new key, so there
  is nothing to invalidate. The table is emptied once it holds more than
  `@most` blocks, which bounds its memory; it fills again as bases run.
  """

  use GenServer

  @table __MODULE__
  @most 50_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec fetch(String.t(), (String.t() -> map())) :: map()
  def fetch(block, parse) do
    case lookup(block) do
      {:ok, properties} ->
        properties

      :missing ->
        properties = parse.(block)
        remember(block, properties)
        properties
    end
  end

  defp lookup(block) do
    case :ets.whereis(@table) do
      :undefined ->
        :missing

      table ->
        case :ets.lookup(table, block) do
          [{^block, properties}] -> {:ok, properties}
          [] -> :missing
        end
    end
  end

  defp remember(block, properties) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      table ->
        if :ets.info(table, :size) >= @most, do: :ets.delete_all_objects(table)
        :ets.insert(table, {block, properties})
        :ok
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end
end
