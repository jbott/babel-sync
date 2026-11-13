defmodule BabelSync.Markdown do
  @moduledoc """
  Renders a note to HTML the way Obsidian shows it in reading view.

  On top of CommonMark and GitHub's tables, task lists, strikethrough,
  autolinks and footnotes, it handles Obsidian's own syntax: properties,
  callouts (foldable ones become `details`), `==highlights==`,
  `%%comments%%`, `$math$`, `#tags`, block identifiers, single line
  breaks kept as breaks, and Mermaid diagrams. Wikilinks, embeds and
  Markdown links to files in the vault are resolved against the vault's
  entries the way Obsidian does: an exact path first, then a note with
  that name anywhere. Links into a heading or block land on it. An
  embedded note, or one of its sections or blocks, is shown in place, two
  levels deep at most. Images take a size, as in `![[photo.png|300]]`,
  and embedded PDFs open in place, at a page and height when given, as in
  `![[paper.pdf#page=3&height=400]]`.

  A shared vault holds text written by other people, so raw HTML in a
  note is kept only after sanitizing: no scripts, event handlers or
  inline styles, and only the renderer's own classes. Every id gets an
  `md-` prefix so nothing in a note can collide with the page around it.
  """

  alias BabelSync.Markdown.{Properties, Section}
  alias BabelSync.Vaults.Entry

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  @audio_extensions ~w(.mp3 .wav .ogg .m4a .flac .3gp)
  @video_extensions ~w(.mp4 .webm .mov .mkv .ogv)
  @embed_depth 2
  @scheme ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/
  @tag ~r/#((?:[\p{L}\p{M}\p{N}_\/-]|[^\x00-\x7F\s\p{P}])+)/u
  @size ~r/^(?:(.*)\|)?(\d+)(?:x(\d+))?$/s

  @extension [
    wikilinks_title_after_pipe: true,
    tasklist: true,
    table: true,
    strikethrough: true,
    autolink: true,
    footnotes: true,
    inline_footnotes: true,
    ofm_callouts: true,
    ofm_comments: true,
    highlight: true,
    math_dollars: true
  ]

  @classes ~w(callout callout-title callout-content tag embed embed-title embed-content embed-file
              mermaid properties property property-item unresolved)

  @tokens ~w(comment string regexp constant numeric character language other keyword operator storage
             type entity name function class tag attribute-name support variable parameter markup
             heading bold italic inserted deleted changed invalid punctuation definition section
             embedded interpolation escape)

  @highlight [engine: :syntect, opts: []]

  @sanitize [
    add_tags: ~w(audio video input section iframe),
    tag_attributes: %{
      "a" => ~w(href hreflang title id),
      "img" => ~w(alt height src width title),
      "audio" => ~w(src controls),
      "video" => ~w(src controls),
      "iframe" => ~w(src title height loading),
      "input" => ~w(type checked disabled),
      "details" => ~w(open data-callout data-callout-metadata),
      "div" => ~w(id data-callout data-callout-metadata),
      "span" => ~w(id data-math-style),
      "ol" => ~w(start),
      "li" => ~w(id),
      "sup" => ~w(id),
      "section" => [],
      "td" => ~w(align colspan rowspan),
      "th" => ~w(align colspan rowspan scope),
      "del" => ~w(cite datetime),
      "ins" => ~w(cite datetime),
      "q" => ~w(cite),
      "blockquote" => ~w(cite)
    },
    allowed_classes: %{
      "div" => @classes,
      "span" => @classes ++ @tokens,
      "details" => @classes,
      "summary" => @classes,
      "dl" => @classes,
      "a" => ~w(footnote-backref embed-file),
      "sup" => ["footnote-ref"],
      "iframe" => ["embed-pdf"],
      "pre" => ~w(mermaid syntax-highlighting),
      "section" => ["footnotes"]
    },
    id_prefix: "md-"
  ]

  @type link :: (Entry.t() -> String.t())
  @type links :: %{
          required(:note) => link(),
          required(:raw) => link(),
          optional(:text) => (Entry.t() -> String.t())
        }

  @spec to_html(String.t(), [Entry.t()], links()) :: String.t()
  def to_html(text, entries, links) do
    context = %{index: index(entries), links: links, depth: 0, seen: [], in_link: false}

    text
    |> render(context, true)
    |> MDEx.to_html!(
      extension: @extension,
      render: [hardbreaks: true, unsafe: true],
      syntax_highlight: @highlight,
      sanitize: @sanitize
    )
    |> local_anchors()
  end

  @spec resolve_target(String.t(), [Entry.t()]) :: Entry.t() | nil
  def resolve_target(target, entries), do: lookup(target, index(entries))

  @spec resolver([Entry.t()]) :: (String.t() -> Entry.t() | nil)
  def resolver(entries) do
    index = index(entries)
    &lookup(&1, index)
  end

  defp render(text, context, properties?) do
    {frontmatter, body} = split_frontmatter(text)
    document = MDEx.parse_document!(body, extension: @extension)

    shown =
      if properties?,
        do: Properties.to_html(frontmatter, &property_link(&1, context)),
        else: ""

    nodes = walk_list(document.nodes, context)
    %{document | nodes: if(shown == "", do: nodes, else: [raw(shown) | nodes])}
  end

  defp walk_list(nodes, context), do: nodes |> merge_text() |> Enum.flat_map(&walk(&1, context))

  defp walk(%MDEx.Paragraph{nodes: nodes} = paragraph, context) do
    if embeds_only?(nodes) do
      for %MDEx.WikiLink{} = embed <- nodes, do: block_embed(embed, context)
    else
      case block_id(nodes) do
        {nil, nodes} -> [%{paragraph | nodes: walk_list(nodes, context)}]
        {id, []} -> [raw(~s(<span id="block-#{escape(id)}"></span>))]
        {id, nodes} -> [%{paragraph | nodes: [block_anchor(id) | walk_list(nodes, context)]}]
      end
    end
  end

  defp walk(%MDEx.Heading{nodes: nodes} = heading, context) do
    anchor = raw(~s(<span id="h-#{escape(Section.key(plain(nodes)))}"></span>))
    [%{heading | nodes: [anchor | walk_list(nodes, context)]}]
  end

  defp walk(%MDEx.Callout{} = callout, context), do: callout(callout, context)

  defp walk(%MDEx.CodeBlock{info: "mermaid" <> _, literal: source}, _context),
    do: [raw(~s(<pre class="mermaid">#{escape(source)}</pre>))]

  defp walk(%MDEx.WikiLink{} = link, context), do: [inline_link(link, context)]

  defp walk(%MDEx.Link{url: url, nodes: nodes} = link, context) do
    [
      %{
        link
        | url: vault_url(url, context, :note),
          nodes: walk_list(nodes, %{context | in_link: true})
      }
    ]
  end

  defp walk(%MDEx.Image{} = image, context), do: [image(image, context)]

  defp walk(%MDEx.Text{literal: literal} = text, %{in_link: false}) do
    if Regex.match?(@tag, literal), do: [raw(tagged(literal))], else: [text]
  end

  defp walk(%{nodes: nodes} = node, context), do: [%{node | nodes: walk_list(nodes, context)}]
  defp walk(node, _context), do: [node]

  defp merge_text([%MDEx.Text{literal: a}, %MDEx.Text{literal: b} | rest]),
    do: merge_text([%MDEx.Text{literal: a <> b} | rest])

  defp merge_text([node | rest]), do: [node | merge_text(rest)]
  defp merge_text([]), do: []

  defp callout(
         %MDEx.Callout{nodes: nodes, callout_type: type, metadata: metadata, fold: fold},
         context
       ) do
    {title, body} =
      case nodes do
        [%MDEx.CalloutTitle{nodes: title} | body] -> {walk_list(title, context), body}
        body -> {[%MDEx.Paragraph{nodes: [%MDEx.Text{literal: default_title(type)}]}], body}
      end

    attributes =
      ~s(class="callout" data-callout="#{escape(type)}") <>
        if(metadata in [nil, ""], do: "", else: ~s( data-callout-metadata="#{escape(metadata)}"))

    {open, title_open, title_close, close} =
      case fold do
        :none ->
          {"<div #{attributes}>", ~s(<div class="callout-title">), "</div>", "</div>"}

        :expanded ->
          {"<details #{attributes} open>", ~s(<summary class="callout-title">), "</summary>",
           "</details>"}

        :collapsed ->
          {"<details #{attributes}>", ~s(<summary class="callout-title">), "</summary>",
           "</details>"}
      end

    content =
      case walk_list(body, context) do
        [] -> []
        walked -> [raw(~s(<div class="callout-content">))] ++ walked ++ [raw("</div>")]
      end

    [raw(open <> title_open)] ++ title ++ [raw(title_close)] ++ content ++ [raw(close)]
  end

  defp default_title(type) do
    {first, rest} = type |> String.replace("-", " ") |> String.split_at(1)
    String.upcase(first) <> rest
  end

  defp embeds_only?(nodes) do
    Enum.any?(nodes, &match?(%MDEx.WikiLink{embed: true}, &1)) and
      Enum.all?(nodes, fn
        %MDEx.WikiLink{embed: true} -> true
        %MDEx.SoftBreak{} -> true
        %MDEx.LineBreak{} -> true
        %MDEx.Text{literal: literal} -> String.trim(literal) == ""
        _other -> false
      end)
  end

  defp block_id(nodes) do
    with %MDEx.Text{literal: literal} <- List.last(nodes),
         [whole, lead, id] <- Regex.run(~r/(^|[ \t])\^([A-Za-z0-9-]+)[ \t]*$/, literal),
         true <- lead != "" or starts_line?(nodes) do
      kept = binary_part(literal, 0, byte_size(literal) - byte_size(whole))
      before = Enum.drop(nodes, -1)
      {id, if(kept == "", do: drop_breaks(before), else: before ++ [%MDEx.Text{literal: kept}])}
    else
      _no_marker -> {nil, nodes}
    end
  end

  defp starts_line?(nodes) do
    case nodes |> Enum.drop(-1) |> List.last() do
      nil -> true
      %MDEx.SoftBreak{} -> true
      %MDEx.LineBreak{} -> true
      _inline -> false
    end
  end

  defp drop_breaks(nodes) do
    nodes
    |> Enum.reverse()
    |> Enum.drop_while(&(match?(%MDEx.SoftBreak{}, &1) or match?(%MDEx.LineBreak{}, &1)))
    |> Enum.reverse()
  end

  defp block_anchor(id), do: raw(~s(<span id="block-#{escape(id)}"></span>))

  defp block_embed(%MDEx.WikiLink{url: url} = link, context) do
    {target, fragment} = split_target(url)

    case lookup(target, context.index) do
      %Entry{kind: :doc} = entry ->
        if Map.has_key?(context.links, :text) and context.depth < @embed_depth and
             entry.id not in context.seen,
           do: transclude(entry, fragment, context),
           else: inline_link(link, context)

      _other ->
        inline_link(link, context)
    end
  end

  defp transclude(entry, fragment, context) do
    inner =
      entry
      |> context.links.text.()
      |> then(&elem(split_frontmatter(&1), 1))
      |> Section.extract(fragment)
      |> render(
        %{context | depth: context.depth + 1, seen: [entry.id | context.seen]},
        false
      )
      |> MDEx.to_html!(
        extension: @extension,
        render: [hardbreaks: true, unsafe: true],
        syntax_highlight: @highlight
      )

    title =
      Path.rootname(Path.basename(entry.path)) <> if(fragment, do: " › " <> fragment, else: "")

    raw(
      ~s(<div class="embed"><div class="embed-title"><a href="#{escape(context.links.note.(entry) <> anchor(fragment))}">) <>
        escape(title) <> ~s(</a></div><div class="embed-content">) <> inner <> "</div></div>"
    )
  end

  defp inline_link(%MDEx.WikiLink{url: url, embed: embed, nodes: nodes}, context) do
    {target, fragment} = split_target(url)

    nodes =
      if plain(nodes) == url, do: [%MDEx.Text{literal: link_text(target, fragment)}], else: nodes

    shown = plain(nodes)

    case {target, lookup(target, context.index)} do
      {"", nil} ->
        %MDEx.Link{url: anchor(fragment), title: "", nodes: nodes}

      {_target, %Entry{kind: :blob} = entry} when embed ->
        media(entry, shown, url, fragment, context)

      {_target, %Entry{kind: :blob} = entry} ->
        %MDEx.Link{url: context.links.raw.(entry), title: "", nodes: nodes}

      {_target, %Entry{} = entry} ->
        %MDEx.Link{url: context.links.note.(entry) <> anchor(fragment), title: "", nodes: nodes}

      {_target, nil} ->
        raw(~s(<span class="unresolved">#{escape(shown)}</span>))
    end
  end

  defp link_text(target, nil), do: target
  defp link_text("", fragment), do: String.trim_leading(fragment, "^")
  defp link_text(target, fragment), do: target <> " › " <> String.trim_leading(fragment, "^")

  defp media(entry, shown, url, fragment, context) do
    source = escape(context.links.raw.(entry))
    extension = String.downcase(Path.extname(entry.path))

    cond do
      extension in @image_extensions ->
        {alt, size} = image_size(if shown == url, do: "", else: shown)

        raw(
          ~s(<img src="#{source}" alt="#{escape(if alt == "", do: Path.basename(entry.path), else: alt)}"#{size}>)
        )

      extension in @audio_extensions ->
        raw(~s(<audio controls src="#{source}"></audio>))

      extension in @video_extensions ->
        raw(~s(<video controls src="#{source}"></video>))

      extension == ".pdf" ->
        pdf(source, entry, fragment)

      true ->
        raw(~s(<a class="embed-file" href="#{source}">#{escape(Path.basename(entry.path))}</a>))
    end
  end

  defp pdf(source, entry, fragment) do
    options = URI.decode_query(fragment || "")
    page = if number = number(options["page"]), do: "#page=" <> to_string(number), else: ""
    height = if pixels = number(options["height"]), do: ~s( height="#{pixels}"), else: ""

    raw(
      ~s(<iframe class="embed-pdf" loading="lazy" title="#{escape(Path.basename(entry.path))}") <>
        ~s( src="#{source}#{page}"#{height}></iframe>)
    )
  end

  defp number(nil), do: nil

  defp number(text) do
    case Integer.parse(text) do
      {number, ""} when number > 0 -> number
      _not_a_number -> nil
    end
  end

  defp image(%MDEx.Image{url: url, nodes: nodes, title: title} = image, context) do
    source = vault_url(url, context, :raw)

    case image_size(plain(nodes)) do
      {_alt, ""} ->
        %{image | url: source}

      {alt, size} ->
        titled = if title in [nil, ""], do: "", else: ~s( title="#{escape(title)}")
        raw(~s(<img src="#{escape(source)}" alt="#{escape(alt)}"#{size}#{titled}>))
    end
  end

  defp image_size(text) do
    case Regex.run(@size, text) do
      [_, alt, width] -> {alt, ~s( width="#{width}")}
      [_, alt, width, height] -> {alt, ~s( width="#{width}" height="#{height}")}
      nil -> {text, ""}
    end
  end

  defp vault_url(url, context, kind) do
    if url == "" or String.starts_with?(url, ["#", "/"]) or Regex.match?(@scheme, url) do
      url
    else
      {target, fragment} = url |> URI.decode() |> split_target()

      case lookup(target, context.index) do
        %Entry{kind: :blob} = entry -> context.links.raw.(entry)
        %Entry{} = entry when kind == :note -> context.links.note.(entry) <> anchor(fragment)
        _missing -> url
      end
    end
  end

  defp property_link(target, context) do
    {target, fragment} = split_target(target)

    case lookup(target, context.index) do
      %Entry{kind: :blob} = entry -> context.links.raw.(entry)
      %Entry{} = entry -> context.links.note.(entry) <> anchor(fragment)
      nil -> nil
    end
  end

  defp tagged(literal) do
    {pieces, rest, _ended} =
      @tag
      |> Regex.scan(literal, return: :index)
      |> Enum.reduce({[], 0, -1}, fn [{at, length}, {name_at, name_length}],
                                     {pieces, from, ended} ->
        name = binary_part(literal, name_at, name_length)
        before = if at == 0, do: "", else: binary_part(literal, at - 1, 1)

        if (at == 0 or at == ended or String.trim(before) == "") and
             not Regex.match?(~r/^\d+$/, name) do
          {[
             pieces,
             escape(binary_part(literal, from, at - from)),
             ~s(<span class="tag">##{escape(name)}</span>)
           ], at + length, at + length}
        else
          {pieces, from, ended}
        end
      end)

    IO.iodata_to_binary([pieces, escape(binary_part(literal, rest, byte_size(literal) - rest))])
  end

  defp anchor(nil), do: ""
  defp anchor(""), do: ""
  defp anchor("^" <> id), do: "#md-block-" <> URI.encode(id, &URI.char_unreserved?/1)

  defp anchor(heading) do
    last = heading |> String.split("#") |> Enum.reject(&(&1 == "")) |> List.last("")
    "#md-h-" <> URI.encode(Section.key(last), &URI.char_unreserved?/1)
  end

  defp split_target(url) do
    case String.split(url, "#", parts: 2) do
      [target, fragment] -> {target, fragment}
      [target] -> {target, nil}
    end
  end

  defp plain(nodes) do
    Enum.map_join(nodes, fn
      %MDEx.Text{literal: literal} -> literal
      %MDEx.Code{literal: literal} -> literal
      %MDEx.SoftBreak{} -> " "
      %{nodes: nodes} -> plain(nodes)
      _other -> ""
    end)
  end

  defp raw(html), do: %MDEx.Raw{literal: html}

  defp escape(text), do: Plug.HTML.html_escape(text)

  defp local_anchors(html), do: Regex.replace(~r/href="#(?!md-|")/, html, ~s(href="#md-))

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

  defp lookup("", _index), do: nil

  defp lookup(target, index) do
    target = BabelSync.Vaults.Path.normalize(target)

    index.paths[target] || index.paths[target <> ".md"] || index.names[target] ||
      index.names[Path.basename(target)]
  end

  defp split_frontmatter("---\n" <> rest = text) do
    case String.split(rest, ~r/^---[ \t]*$/m, parts: 2) do
      [frontmatter, body] -> {frontmatter, String.trim_leading(body, "\n")}
      _unterminated -> {nil, text}
    end
  end

  defp split_frontmatter(text), do: {nil, text}
end
