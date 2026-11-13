defmodule BabelSyncWeb.VaultLive.DetailsPanel do
  @moduledoc """
  What surrounds the open note, beside it: its headings, as a way to
  move about in it, and the notes that link to it.
  """

  use BabelSyncWeb, :html

  alias BabelSync.Agent.Text
  alias BabelSync.Bases
  alias BabelSync.Markdown
  alias BabelSync.Markdown.Section
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths

  @type heading :: %{level: 1..6, title: String.t(), line: pos_integer()}
  @type t :: %{headings: [heading()], linked_from: [Entry.t()] | :looking}

  @spec open(String.t()) :: t()
  def open(text), do: %{headings: Text.outline(text).headings, linked_from: :looking}

  @spec linked_from(Entry.t(), [Entry.t()]) :: [Entry.t()]
  def linked_from(%Entry{} = entry, entries) do
    resolve = Markdown.resolver(entries)
    by_path = Map.new(entries, &{&1.path, &1})
    notes = for %Entry{kind: :doc} = other <- entries, other.id != entry.id, do: other

    for note <- Bases.Index.notes(notes),
        Enum.any?(note.links, &match?(%Entry{id: id} when id == entry.id, resolve.(&1))),
        do: by_path[note.path]
  end

  attr :details, :any, required: true
  attr :entry, :any, required: true

  def details(assigns) do
    assigns = assign(assigns, :shallowest, shallowest(assigns.details))

    ~H"""
    <aside
      :if={@details && @entry}
      id="details"
      aria-label="Outline and links"
      phx-keydown={close()}
      phx-key="escape"
      data-close={JS.push("close_details")}
      class="fixed inset-0 z-20 flex flex-col border-line bg-canvas pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:static md:z-auto md:w-72 md:shrink-0 md:border-l"
    >
      <div class="flex h-12 shrink-0 items-center justify-between border-b border-line pl-4 pr-1.5">
        <span class="text-xs font-semibold uppercase tracking-[0.1em] text-muted">Outline</span>
        <.icon_button
          id="close-details"
          phx-click={close()}
          phx-mounted={JS.focus()}
          icon="hero-x-mark"
          label="Close outline"
        />
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto pb-6">
        <p :if={@details.headings == []} id="outline-empty" class="px-4 py-4 text-sm text-muted">
          This note has no headings.
        </p>
        <nav :if={@details.headings != []} id="outline" aria-label="Headings" class="p-2">
          <a
            :for={heading <- @details.headings}
            href={anchor(heading)}
            phx-click={
              JS.push("reveal", value: %{line: heading.line})
              |> JS.dispatch("babelsync:close-on-phone", to: "#details")
            }
            style={"padding-left: #{0.5 + (heading.level - @shallowest) * 0.75}rem"}
            class={[
              "block truncate rounded-md py-1.5 pr-2 text-sm transition-colors duration-100 hover:bg-ink/6 hover:text-ink md:py-1",
              if(heading.level == @shallowest, do: "font-medium text-ink", else: "text-muted")
            ]}
          >
            {heading.title}
          </a>
        </nav>

        <p class="border-t border-line px-4 pb-1 pt-4 text-xs font-semibold uppercase tracking-[0.1em] text-muted">
          Linked from
        </p>
        <p
          :if={@details.linked_from == :looking}
          id="linked-looking"
          class="flex items-center gap-2 px-4 py-2 text-sm text-muted"
        >
          <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Looking…
        </p>
        <p :if={@details.linked_from == []} id="linked-none" class="px-4 py-2 text-sm text-muted">
          No other note links here.
        </p>
        <nav
          :if={is_list(@details.linked_from) and @details.linked_from != []}
          id="linked-from"
          aria-label="Notes that link here"
          class="p-2"
        >
          <.link
            :for={note <- @details.linked_from}
            id={"linked-from-#{note.id}"}
            patch={Paths.entry(note)}
            phx-click={JS.dispatch("babelsync:close-on-phone", to: "#details")}
            class="flex items-center gap-1.5 rounded-md px-2 py-1.5 text-sm text-muted transition-colors duration-100 hover:bg-ink/6 hover:text-ink md:py-1"
          >
            <.icon name="hero-document-text" class="size-4 shrink-0 text-faint" />
            <span class="truncate">{Path.rootname(Path.basename(note.path))}</span>
          </.link>
        </nav>
      </div>
    </aside>
    """
  end

  defp close, do: JS.push("close_details") |> JS.focus(to: "#details-button")

  defp shallowest(%{headings: [_ | _] = headings}),
    do: headings |> Enum.map(& &1.level) |> Enum.min()

  defp shallowest(_none), do: 1

  defp anchor(heading) do
    "#md-h-" <> URI.encode(Section.key(heading.title), &URI.char_unreserved?/1)
  end
end
