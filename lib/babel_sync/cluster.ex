defmodule BabelSync.Cluster do
  @moduledoc """
  Finds the other servers that share this one's database and connects
  to them, so that several can serve the same vaults at once: behind a
  load balancer, or for the minutes in which a new version is started
  beside the old one.

  Every server that runs as a named Erlang node writes its name to the
  database every few seconds and connects to the names the others
  wrote. The database is the one thing all of them can already reach,
  so nothing else has to be set up for them to find each other.

  Once connected, what one node announces reaches the sockets of all of
  them. Nothing else is shared between nodes in memory: a note's
  process, an agent's session and the cleanup each say in their own
  documentation how they behave when there are several.
  """

  use GenServer

  import Ecto.Query

  alias BabelSync.Cluster.Member
  alias BabelSync.Repo

  @beat :timer.seconds(5)
  @present_for 30
  @remembered_for 86_400

  @spec enabled?() :: boolean()
  def enabled?, do: Node.alive?() and BabelSync.storage() == :remote

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec members(DateTime.t()) :: [String.t()]
  def members(now \\ DateTime.utc_now()) do
    present = DateTime.add(now, -@present_for, :second)
    Repo.all(from m in Member, where: m.seen_at > ^present, select: m.name, order_by: m.name)
  end

  @spec announce(String.t(), DateTime.t()) :: :ok
  def announce(name, now \\ DateTime.utc_now()) do
    Repo.insert!(%Member{name: name, seen_at: now},
      on_conflict: {:replace, [:seen_at]},
      conflict_target: :name
    )

    forgotten = DateTime.add(now, -@remembered_for, :second)
    Repo.delete_all(from m in Member, where: m.seen_at < ^forgotten)
    :ok
  end

  @spec withdraw(String.t()) :: :ok
  def withdraw(name) do
    Repo.delete_all(from m in Member, where: m.name == ^name)
    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, nil, {:continue, :beat}}
  end

  @impl true
  def handle_continue(:beat, state), do: beat(state)

  @impl true
  def handle_info(:beat, state), do: beat(state)
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: withdraw(own_name())

  defp beat(state) do
    announce(own_name())
    for name <- members(), name != own_name(), do: Node.connect(String.to_atom(name))
    Process.send_after(self(), :beat, @beat)
    {:noreply, state}
  rescue
    DBConnection.ConnectionError ->
      Process.send_after(self(), :beat, @beat)
      {:noreply, state}
  end

  defp own_name, do: Atom.to_string(node())
end
