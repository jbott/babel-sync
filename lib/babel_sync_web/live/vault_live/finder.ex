defmodule BabelSyncWeb.VaultLive.Finder do
  @moduledoc """
  Finding a file in a vault: a panel over the page that lists files whose
  names match what is typed, best match first, and notes whose text
  contains it.
  """

  use BabelSyncWeb, :html

  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths

  @named 8
  @recent 8
  @containing 20

  @type hit :: %{entry: Entry.t(), line: pos_integer(), text: String.t()}
  @type t :: %{query: String.t(), files: [Entry.t()], hits: [hit()] | :searching}

  @spec open([Entry.t()]) :: t()
  def open(entries), do: %{query: "", files: files(entries, ""), hits: []}

  @spec typed(t(), [Entry.t()], String.t()) :: t()
  def typed(finder, entries, query) do
    hits = if searchable?(query), do: :searching, else: []
    %{finder | query: query, files: files(entries, query), hits: hits}
  end

  @spec searchable?(String.t()) :: boolean()
  def searchable?(query), do: String.length(String.trim(query)) >= 2

  @spec files([Entry.t()], String.t()) :: [Entry.t()]
  def files(entries, query) do
    files = Enum.reject(entries, &(&1.kind == :folder))

    case String.downcase(String.trim(query)) do
      "" ->
        files |> Enum.sort_by(& &1.updated_at, {:desc, DateTime}) |> Enum.take(@recent)

      wanted ->
        for(entry <- files, rank = rank(entry.path, wanted), do: {rank, entry})
        |> Enum.sort_by(fn {rank, entry} -> {rank, String.length(entry.path), entry.path} end)
        |> Enum.take(@named)
        |> Enum.map(&elem(&1, 1))
    end
  end

  defp rank(path, wanted) do
    path = String.downcase(path)
    name = Path.basename(path)

    cond do
      name == wanted or Path.rootname(name) == wanted -> 0
      String.starts_with?(name, wanted) -> 1
      String.contains?(name, wanted) -> 2
      String.contains?(path, wanted) -> 3
      in_order?(String.graphemes(name), String.graphemes(wanted)) -> 4
      true -> nil
    end
  end

  defp in_order?(_name, []), do: true
  defp in_order?([], _wanted), do: false
  defp in_order?([letter | name], [letter | wanted]), do: in_order?(name, wanted)
  defp in_order?([_other | name], wanted), do: in_order?(name, wanted)

  @spec hits([%{path: String.t(), matches: [map()]}], [Entry.t()]) :: [hit()]
  def hits(found, entries) do
    by_path = Map.new(entries, &{&1.path, &1})

    for %{path: path, matches: matches} <- Enum.take(found, @containing),
        entry = by_path[path],
        %{line: line, text: text} <- Enum.take(Enum.filter(matches, & &1.match), 1) do
      %{entry: entry, line: line, text: String.trim(text)}
    end
  end

  attr :finder, :any, required: true

  def finder(assigns) do
    ~H"""
    <div id="finder" phx-hook="Finder">
      <div
        :if={@finder}
        id="finder-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="Find a file"
        class="fixed inset-0 z-40 flex items-start justify-center px-3 pt-[max(4rem,env(safe-area-inset-top))] md:pt-[12vh]"
      >
        <div
          id="finder-backdrop"
          phx-click="close_finder"
          class="absolute inset-0 bg-ink/25 backdrop-blur-[2px]"
        >
        </div>
        <div class="relative flex max-h-[min(34rem,80dvh)] w-full max-w-xl animate-rise flex-col overflow-hidden rounded-xl border border-line bg-surface shadow-float">
          <form
            id="finder-form"
            phx-change="find"
            phx-submit="find"
            phx-auto-recover="ignore"
            class="flex items-center gap-2 border-b border-line px-3.5"
          >
            <.icon name="hero-magnifying-glass-mini" class="size-[1.125rem] shrink-0 text-faint" />
            <input
              id="finder-input"
              type="text"
              name="q"
              value={@finder.query}
              placeholder="Find a file, or search in notes"
              aria-label="Find a file, or search in notes"
              aria-controls="finder-results"
              autocapitalize="off"
              autocomplete="off"
              spellcheck="false"
              phx-debounce="120"
              class="h-12 min-w-0 flex-1 bg-transparent text-base text-ink outline-none placeholder:text-faint md:text-sm"
            />
            <kbd class="hidden rounded border border-line px-1.5 py-0.5 text-2xs text-faint md:block">
              esc
            </kbd>
          </form>
          <div id="finder-results" role="listbox" class="min-h-0 flex-1 overflow-y-auto p-1.5">
            <p
              :if={@finder.files != []}
              class="px-2.5 pb-1 pt-1.5 text-2xs font-semibold uppercase tracking-[0.1em] text-faint"
            >
              {if(@finder.query == "", do: "Recently changed", else: "Files")}
            </p>
            <.link
              :for={entry <- @finder.files}
              id={"finder-file-#{entry.id}"}
              patch={Paths.entry(entry)}
              role="option"
              data-finder-item
              class="finder-item flex items-center gap-2 rounded-lg px-2.5 py-2 text-sm text-ink md:py-1.5"
            >
              <.icon
                name={if entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip"}
                class="size-4 shrink-0 text-faint"
              />
              <span class="truncate font-medium">{Path.basename(entry.path)}</span>
              <span class="path-tail ml-auto min-w-0 max-w-[45%] truncate pl-3 text-xs text-faint">
                <bdi>{folder(entry.path)}</bdi>
              </span>
            </.link>

            <p
              :if={@finder.hits != []}
              class="px-2.5 pb-1 pt-3 text-2xs font-semibold uppercase tracking-[0.1em] text-faint"
            >
              In notes
            </p>
            <p
              :if={@finder.hits == :searching}
              id="finder-searching"
              class="flex items-center gap-2 px-2.5 py-2 text-sm text-muted"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Searching…
            </p>
            <.link
              :for={hit <- if(is_list(@finder.hits), do: @finder.hits, else: [])}
              id={"finder-hit-#{hit.entry.id}"}
              patch={Paths.entry(hit.entry)}
              role="option"
              data-finder-item
              class="finder-item block rounded-lg px-2.5 py-2 text-sm md:py-1.5"
            >
              <span class="flex items-baseline gap-2">
                <span class="truncate font-medium text-ink">{Path.basename(hit.entry.path)}</span>
                <span class="shrink-0 text-xs tabular-nums text-faint">line {hit.line}</span>
              </span>
              <span class="block truncate text-xs text-muted">{hit.text}</span>
            </.link>

            <p
              :if={@finder.files == [] and @finder.hits == []}
              id="finder-nothing"
              class="px-2.5 py-8 text-center text-sm text-muted"
            >
              Nothing matches.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp folder(path) do
    case Path.dirname(path) do
      "." -> ""
      folder -> folder
    end
  end
end
