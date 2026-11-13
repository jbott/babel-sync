defmodule BabelSync.Stats do
  @moduledoc """
  How much is going on in this server right now, as counts that name
  no vault, note or person.
  """

  @spec live() :: %{notes_open: non_neg_integer(), memory_bytes: non_neg_integer()}
  def live do
    %{
      notes_open: notes_open(),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp notes_open do
    case Process.whereis(BabelSync.Sync.Supervisor) do
      nil -> 0
      supervisor -> DynamicSupervisor.count_children(supervisor).active
    end
  catch
    :exit, _stopping -> 0
  end

  @spec measure() :: :ok
  def measure, do: :telemetry.execute([:babel_sync, :live], live(), %{})
end
