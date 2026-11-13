defmodule BabelSync.Stats do
  @moduledoc """
  How much is going on in this server right now, as counts that name
  no vault, note or person.
  """

  @spec live() :: %{notes_open: non_neg_integer(), memory_bytes: non_neg_integer()}
  def live do
    %{
      notes_open: DynamicSupervisor.count_children(BabelSync.Sync.Supervisor).active,
      memory_bytes: :erlang.memory(:total)
    }
  end

  @spec measure() :: :ok
  def measure, do: :telemetry.execute([:babel_sync, :live], live(), %{})
end
