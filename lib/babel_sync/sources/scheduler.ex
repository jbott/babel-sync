defmodule BabelSync.Sources.Scheduler do
  @moduledoc """
  Decides when sources run and which server runs each.

  Everything it decides on is a row in the database, and every decision
  is an update that takes effect only if the row is still as it was
  seen, so any number of servers can run this side by side without
  talking to each other: one of them wins each update and the others
  move on. A source due to run has its next time moved on by whichever
  server gets there first, which then queues the run. A queued run is
  taken by whichever server first marks its source as running, and a
  source is only ever marked once, so it never runs twice at a time.

  The mark carries a time by which the run must be over. A server that
  stops mid-run leaves the mark behind; once its time passes, the run is
  recorded as failed and the source is free again.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias BabelSync.{Repo, Sources}
  alias BabelSync.Sources.{Run, Runner, Script, Source}
  alias BabelSync.Vaults.{Entry, Vault}

  @slack 60_000
  @kept_runs 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec poke() :: :ok
  def poke do
    if pid = Process.whereis(__MODULE__), do: send(pid, :tick)
    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, later(%{timer: nil})}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = DateTime.utc_now()

    try do
      expire(now)
      queue_due(now)

      for {run, source} <- claim(now) do
        Task.Supervisor.start_child(Sources.Tasks, fn -> carry_out(run, source) end)
      end
    rescue
      error -> Logger.error("sources: " <> Exception.format(:error, error, __STACKTRACE__))
    end

    {:noreply, later(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp later(state),
    do: %{state | timer: Process.send_after(self(), :tick, Sources.limits()[:tick])}

  @spec carry_out(Run.t(), Source.t()) :: Run.t()
  def carry_out(%Run{} = run, %Source{} = source) do
    finished = Runner.run(run, source)
    Sources.prune_runs(@kept_runs)
    Sources.announce(source)
    poke()
    finished
  end

  @spec queue_due(DateTime.t()) :: [Run.t()]
  def queue_due(now) do
    due =
      Repo.all(
        from s in Source,
          join: e in Entry,
          on: e.id == s.entry_id,
          join: v in Vault,
          on: v.id == s.vault_id,
          where: s.enabled and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
          where: is_nil(e.deleted_at),
          select: {s, e.path, v.sources_folder}
      )

    for {source, path, folder} <- due,
        Script.file?(path, folder),
        moved_on?(source, now),
        not queued?(source) do
      Sources.enqueue(source, "schedule")
    end
  end

  defp moved_on?(%Source{} = source, now) do
    every = Jason.decode!(source.manifest)["schedule"]
    next = every && DateTime.add(now, every, :second)

    {count, _} =
      Repo.update_all(
        from(s in Source, where: s.id == ^source.id and s.next_run_at == ^source.next_run_at),
        set: [next_run_at: next]
      )

    count == 1
  end

  defp queued?(%Source{id: id}) do
    Repo.exists?(from r in Run, where: r.source_id == ^id and r.status == :queued)
  end

  @spec claim(DateTime.t()) :: [{Run.t(), Source.t()}]
  def claim(now) do
    until = DateTime.add(now, Sources.limits()[:deadline] + @slack, :millisecond)
    queued = Repo.all(from r in Run, where: r.status == :queued, order_by: r.inserted_at)

    for %Run{} = run <- Enum.uniq_by(queued, & &1.source_id),
        source = mark(run.source_id, now, until),
        taken = take(run, now) || release(source) do
      {taken, source}
    end
  end

  defp mark(source_id, now, until) do
    free =
      from s in Source,
        where: s.id == ^source_id and (is_nil(s.running_until) or s.running_until < ^now)

    case Repo.update_all(free, set: [running_until: until]) do
      {1, _} -> Repo.get(Source, source_id)
      {0, _} -> nil
    end
  end

  defp take(%Run{id: id}, now) do
    queued = from r in Run, where: r.id == ^id and r.status == :queued
    claimed = [status: :running, claimed_by: to_string(node()), started_at: now]

    case Repo.update_all(queued, set: claimed) do
      {1, _} -> Repo.get(Run, id)
      {0, _} -> nil
    end
  end

  defp release(%Source{id: id}) do
    Repo.update_all(from(s in Source, where: s.id == ^id), set: [running_until: nil])
    nil
  end

  @spec expire(DateTime.t()) :: :ok
  def expire(now) do
    abandoned =
      from r in Run,
        join: s in Source,
        on: s.id == r.source_id,
        where: r.status == :running and (is_nil(s.running_until) or s.running_until < ^now),
        select: r.id

    case Repo.all(abandoned) do
      [] ->
        :ok

      ids ->
        Repo.update_all(from(r in Run, where: r.id in ^ids and r.status == :running),
          set: [
            status: :failed,
            finished_at: now,
            error: "the server stopped while this was running"
          ]
        )

        :ok
    end
  end
end
