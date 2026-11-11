defmodule BabelSync.Markdown do
  @moduledoc """
  Renders a note to HTML for reading in the browser.

  Raw HTML in a note is dropped and unsafe link schemes are removed, since
  a shared vault holds text written by other people. Obsidian wikilinks
  and embeds are resolved against the vault's entries the way Obsidian
  does: an exact path first, then a note with that name anywhere.
  """

  alias BabelSync.Vaults.Entry

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)

  @options [
    extension: [
      wikilinks_title_after_pipe: true,
      tasklist: true,
      table: true,
      strikethrough: true,
      autolink: true,
      footnotes: true
    ]
  ]

  @type link :: (Entry.t() -> String.t())

  @spec to_html(String.t(), [Entry.t()], %{note: link(), raw: link()}) :: String.t()
  def to_html(text, entries, links) do
    index = index(entries)

    text
    |> strip_frontmatter()
    |> MDEx.parse_document!(@options)
    |> MDEx.traverse_and_update(fn
      %MDEx.WikiLink{} = wiki -> resolve(wiki, index, links)
      node -> node
    end)
    |> MDEx.to_html!(@options)
  end

  @spec resolve_target(String.t(), [Entry.t()]) :: Entry.t() | nil
  def resolve_target(target, entries), do: lookup(target, index(entries))

  defp resolve(%MDEx.WikiLink{url: url, embed: embed, nodes: nodes}, index, links) do
    [target | fragment] = String.split(url, "#", parts: 2)

    case lookup(target, index) do
      %Entry{kind: :blob} = entry when embed ->
        if image?(entry),
          do: %MDEx.Image{url: links.raw.(entry), title: "", nodes: nodes},
          else: %MDEx.Link{url: links.raw.(entry), title: "", nodes: nodes}

      %Entry{kind: :blob} = entry ->
        %MDEx.Link{url: links.raw.(entry), title: "", nodes: nodes}

      %Entry{} = entry ->
        %MDEx.Link{url: links.note.(entry) <> anchor(fragment), title: "", nodes: nodes}

      nil ->
        %MDEx.Emph{nodes: nodes}
    end
  end

  defp anchor([fragment]), do: "#" <> URI.encode(fragment)
  defp anchor([]), do: ""

  defp image?(%Entry{path: path}), do: String.downcase(Path.extname(path)) in @image_extensions

  defp index(entries) do
    live = Enum.filter(entries, &(&1.kind != :folder and is_nil(&1.deleted_at)))

    %{
      paths: Map.new(live, &{&1.path, &1}),
      names:
        live
        |> Enum.sort_by(&{String.length(&1.path), &1.path}, :desc)
        |> Enum.flat_map(fn entry ->
          base = Path.basename(entry.path)
          [{base, entry}, {Path.rootname(base), entry}]
        end)
        |> Map.new()
    }
  end

  defp lookup(target, index) do
    target = BabelSync.Vaults.Path.normalize(target)

    index.paths[target] || index.paths[target <> ".md"] || index.names[target] ||
      index.names[Path.basename(target)]
  end

  defp strip_frontmatter("---\n" <> rest = text) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [_frontmatter, body] -> body
      _unterminated -> text
    end
  end

  defp strip_frontmatter(text), do: text
end
