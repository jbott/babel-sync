defmodule BabelSyncWeb.VaultLive.HistoryPanel do
  @moduledoc """
  The saved versions of the open file, beside it: for a note, each
  version with what it changed and a way back to it; for an attachment,
  each file it has been.
  """

  use BabelSyncWeb, :html

  import BabelSyncWeb.VaultLive.Reader, only: [mode_class: 1, size: 1]

  attr :versions, :any, required: true
  attr :version, :any, required: true
  attr :against, :atom, required: true
  attr :writable, :boolean, required: true

  def note_history(assigns) do
    ~H"""
    <aside
      :if={@versions}
      id="history"
      class={[
        "fixed inset-0 z-20 flex flex-col border-line bg-canvas pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:static md:z-auto md:shrink-0 md:border-l",
        if(@version, do: "md:w-[30rem] lg:w-[36rem]", else: "md:w-96")
      ]}
    >
      <.history_heading />
      <div :if={@versions == []} class="px-6 py-12 text-center">
        <.icon name="hero-clock" class="size-7 text-faint" />
        <p class="mt-2 text-sm text-muted">No saved versions yet.</p>
      </div>
      <ul class={[
        "shrink-0 overflow-y-auto p-2",
        if(@version, do: "max-h-48", else: "min-h-0 flex-1")
      ]}>
        <li :for={version <- @versions}>
          <button
            id={"version-#{version.id}"}
            phx-click="show_version"
            phx-value-id={version.id}
            aria-current={to_string(chosen?(@version, version))}
            class={[
              "group flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition duration-150",
              if(chosen?(@version, version),
                do: "bg-accent/14 text-ink",
                else: "text-muted hover:bg-ink/6 hover:text-ink"
              )
            ]}
          >
            <span class={[
              "size-2 shrink-0 rounded-full border-[1.5px] transition",
              if(chosen?(@version, version),
                do: "border-accent bg-accent",
                else: "border-line-strong group-hover:border-faint"
              )
            ]}></span>
            <span class="min-w-0 flex-1">
              <span class="block tabular-nums">
                <span class="font-medium text-ink">
                  {Calendar.strftime(version.saved_at, "%d %b %Y")}
                </span>
                {Calendar.strftime(version.saved_at, "%H:%M:%S UTC")}
              </span>
              <span :if={version.author} class="block truncate text-xs text-faint">
                {version.author}
              </span>
            </span>
            <span class="shrink-0 text-xs tabular-nums">
              <span :if={version.added && version.added > 0} class="text-added">
                +{version.added}
              </span>
              <span :if={version.removed && version.removed > 0} class="text-danger">
                −{version.removed}
              </span>
              <span
                :if={version.added == 0 and version.removed == 0}
                class="text-faint"
              >
                {size(version.bytes)}
              </span>
            </span>
          </button>
        </li>
      </ul>
      <p
        :if={@versions != [] and is_nil(@version)}
        class="border-t border-line px-4 py-3 text-xs text-faint"
      >
        Choose a version to see what it changed.
      </p>
      <div :if={@version} class="flex min-h-0 flex-1 flex-col border-t border-line bg-surface">
        <div class="flex items-center gap-2 border-b border-line px-3 py-2">
          <div
            id="compare-modes"
            role="tablist"
            class="inline-flex rounded-lg bg-sunken p-0.5"
          >
            <button
              :for={
                {against, label} <- [
                  previous: "Changes",
                  now: "Since then",
                  text: "Text"
                ]
              }
              id={"compare-#{against}"}
              role="tab"
              aria-selected={to_string(@against == against)}
              phx-click="compare"
              phx-value-against={against}
              class={mode_class(@against == against)}
            >
              {label}
            </button>
          </div>
          <span :if={@against != :text} class="ml-auto text-xs tabular-nums">
            <span class="text-added">+{@version.changes.added}</span>
            <span class="text-danger">−{@version.changes.removed}</span>
          </span>
        </div>
        <p :if={@against != :text} class="px-4 pt-3 text-xs text-faint">
          {compare_caption(@against, @version.version, @versions)}
        </p>
        <pre
          :if={@against == :text}
          id="version-content"
          class="flex-1 overflow-auto whitespace-pre-wrap break-words p-4 font-mono text-xs leading-relaxed text-ink"
        >{@version.text}</pre>
        <div
          :if={@against != :text}
          id="version-changes"
          class="min-h-0 flex-1 overflow-auto py-2 font-mono text-xs leading-relaxed"
        >
          <p :if={@version.changes.hunks == []} class="px-4 py-6 text-center text-muted">
            No differences.
          </p>
          <div
            :for={hunk <- @version.changes.hunks}
            class="mb-2 border-y border-line first:border-t-0"
          >
            <div class="bg-sunken px-3 py-0.5 font-sans text-2xs text-faint">
              Line {hunk.new_start}
            </div>
            <div
              :for={line <- hunk.lines}
              class={[
                "flex",
                line.kind == :added && "bg-added/10",
                line.kind == :removed && "bg-danger/10"
              ]}
            >
              <span class="w-9 shrink-0 select-none pr-2 text-right tabular-nums text-faint">
                {line.new || line.old}
              </span>
              <span class={[
                "w-4 shrink-0 select-none",
                line.kind == :added && "text-added",
                line.kind == :removed && "text-danger"
              ]}>
                {marker(line.kind)}
              </span>
              <span class={[
                "min-w-0 flex-1 whitespace-pre-wrap break-words pr-3",
                if(line.kind == :same, do: "text-muted", else: "text-ink")
              ]}><span
                :for={{kind, text} <- line.segments}
                class={[
                  kind == :added && line.segments != [{:added, text}] &&
                    "rounded-sm bg-added/25",
                  kind == :removed && line.segments != [{:removed, text}] &&
                    "rounded-sm bg-danger/25 line-through decoration-danger/50"
                ]}
              >{text}</span><span :if={
                line.segments in [[], [{:same, ""}], [{:added, ""}], [{:removed, ""}]]
              }>&nbsp;</span></span>
            </div>
          </div>
        </div>
        <div :if={@writable} class="border-t border-line p-3">
          <.button
            id="restore-button"
            phx-click="restore"
            phx-value-id={@version.version.id}
            variant="primary"
            class="w-full"
          >
            <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Restore this version
          </.button>
        </div>
      </div>
    </aside>
    """
  end

  attr :blob_versions, :any, required: true
  attr :entry, :any, required: true
  attr :writable, :boolean, required: true

  def attachment_history(assigns) do
    ~H"""
    <aside
      :if={@blob_versions}
      id="blob-history"
      class="fixed inset-0 z-20 flex flex-col border-line bg-canvas pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:static md:z-auto md:w-96 md:shrink-0 md:border-l"
    >
      <.history_heading />
      <ul class="divide-y divide-line overflow-y-auto">
        <li
          :for={version <- @blob_versions}
          id={"blob-version-#{version.id}"}
          class="flex items-center gap-3 px-4 py-3 text-sm"
        >
          <div class="flex-1 tabular-nums">
            <div class="text-muted">
              <span class="font-medium text-ink">
                {Calendar.strftime(version.inserted_at, "%d %b %Y")}
              </span>
              {Calendar.strftime(version.inserted_at, "%H:%M:%S UTC")}
            </div>
            <div class="text-xs text-faint">{size(version.size)}</div>
          </div>
          <.badge :if={version.blob_hash == @entry.blob_hash}>current</.badge>
          <.button
            :if={@writable and version.blob_hash != @entry.blob_hash}
            phx-click="restore_blob"
            phx-value-id={version.id}
            size="sm"
          >
            Restore
          </.button>
        </li>
      </ul>
    </aside>
    """
  end

  defp chosen?(nil, _summary), do: false
  defp chosen?(%{version: version}, summary), do: version.id == summary.id

  defp marker(:added), do: "+"
  defp marker(:removed), do: "−"
  defp marker(:same), do: ""

  defp compare_caption(:now, _version, _versions),
    do: "From this version to the note as it is now."

  defp compare_caption(:previous, version, versions) do
    if Enum.find(versions, &(&1.id == version.id))[:earliest],
      do: "The earliest kept version, compared with an empty note.",
      else: "What this version changed from the one before it."
  end

  defp history_heading(assigns) do
    ~H"""
    <div class="flex h-12 shrink-0 items-center justify-between border-b border-line pl-4 pr-1.5">
      <span class="text-xs font-semibold uppercase tracking-[0.1em] text-muted">History</span>
      <.icon_button phx-click="close_history" icon="hero-x-mark" label="Close history" />
    </div>
    """
  end
end
