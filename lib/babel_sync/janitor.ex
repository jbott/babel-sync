defmodule BabelSync.Janitor do
  @moduledoc """
  Periodic cleanup.

  History and the trash are kept for `BABELSYNC_RETENTION_DAYS`; the
  newest version of every note and attachment is always kept. Attachment
  bytes go once nothing refers to them, whether a live entry, a trashed
  one or a kept version. A note keeps at most
  `BABELSYNC_VERSIONS_PER_NOTE` versions however recent they are, so one
  that is written to all day cannot fill the database. Uploads that were never finished and expired
  sign-in artifacts go regardless of the retention setting. Attachments
  that have since been recognised as text become notes.

  Servers in a cluster take turns: one that finds another in the middle
  of a cleanup skips its own and tries again at its next hour.

  Each kind of cleanup runs on its own, so one that fails is logged and
  tried again next time without holding up the rest.
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
    alone(fn -> clean(now) end)
  end

  defp alone(clean) do
    :global.trans({__MODULE__, self()}, clean, [node() | Node.list()], 0)
    :ok
  end

  defp clean(now) do
    recent = DateTime.add(now, -@grace, :second)
    signed_in = DateTime.add(now, -BabelSync.Auth.session_lifetime(), :second)

    Enum.each(
      expiry(now) ++
        crowding() ++
        [
          text_files: &Vaults.TextFiles.promote/0,
          attachments: fn -> Blobs.collect_garbage(recent) end,
          uploads: fn -> Blobs.abandon_stale_uploads(recent) end,
          grants: fn -> OAuth.prune(now) end,
          sessions: fn -> BabelSync.Accounts.Sessions.prune(signed_in) end,
          sign_in_links: fn -> MagicLink.prune(now) end,
          transfers: fn -> BabelSync.Transfers.prune(now) end,
          agent_sessions: fn -> BabelSync.MCP.SessionStore.cleanup_expired([]) end
        ],
      &attempt/1
    )
  end

  defp expiry(now) do
    case config(:retention_days) do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(now, -days * @day, :second)

        [
          note_versions: fn -> Sync.Store.prune_versions(cutoff) end,
          attachment_versions: fn -> Vaults.prune_blob_versions(cutoff) end,
          trash: fn -> Vaults.purge_trash(cutoff) end
        ]

      _keep_forever ->
        []
    end
  end

  defp crowding do
    case config(:versions_per_note) do
      most when is_integer(most) and most > 0 ->
        [crowded_notes: fn -> Sync.Store.cap_versions(most) end]

      _keep_all ->
        []
    end
  end

  defp attempt({step, clean}) do
    clean.()
  rescue
    error ->
      Logger.error(
        "cleanup of #{step} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  end

  @impl true
  def init(_opts) do
    schedule(:timer.minutes(1))
    {:ok, nil}
  end

  @impl true
  def handle_info(:run, state) do
    run()
    schedule(config(:interval))
    {:noreply, state}
  end

  defp schedule(delay), do: Process.send_after(self(), :run, delay)

  defp config(key), do: Application.fetch_env!(:babel_sync, __MODULE__)[key]
end
