defmodule BabelSync.Janitor do
  @moduledoc """
  Periodic cleanup.

  History and the trash are kept for `BABELSYNC_RETENTION_DAYS`; the
  newest version of every note and attachment is always kept. Attachment
  bytes go once nothing refers to them, whether a live entry, a trashed
  one or a kept version. Uploads that were never finished and expired
  sign-in artifacts go regardless of the retention setting. Attachments
  that have since been recognised as text become notes.
  """

  use GenServer

  require Logger

  alias BabelSync.Auth.MagicLink
  alias BabelSync.{Blobs, OAuth, Sync, Vaults}

  @day 86_400
  @grace @day

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec run(DateTime.t()) :: :ok
  def run(now \\ DateTime.utc_now()) do
    case config(:retention_days) do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(now, -days * @day, :second)
        _pruned = Sync.Store.prune_versions(cutoff)
        :ok = Vaults.prune_blob_versions(cutoff)
        :ok = Vaults.purge_trash(cutoff)

      _keep_forever ->
        :ok
    end

    _promoted = Vaults.TextFiles.promote()

    recent = DateTime.add(now, -@grace, :second)
    _collected = Blobs.collect_garbage(recent)
    _abandoned = Blobs.abandon_stale_uploads(recent)
    :ok = OAuth.prune(now)

    :ok =
      BabelSync.Accounts.Sessions.prune(
        DateTime.add(now, -BabelSync.Auth.session_lifetime(), :second)
      )

    :ok = MagicLink.prune(now)
    :ok = BabelSync.Transfers.prune(now)
  end

  @impl true
  def init(_opts) do
    schedule(:timer.minutes(1))
    {:ok, nil}
  end

  @impl true
  def handle_info(:run, state) do
    try do
      run()
    rescue
      error -> Logger.error("cleanup failed: " <> Exception.format(:error, error, __STACKTRACE__))
    end

    schedule(config(:interval))
    {:noreply, state}
  end

  defp schedule(delay), do: Process.send_after(self(), :run, delay)

  defp config(key), do: Application.fetch_env!(:babel_sync, __MODULE__)[key]
end
