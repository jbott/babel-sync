defmodule BabelSync.Canvas do
  @moduledoc """
  Draws an Obsidian canvas (a `.canvas` file in the JSON Canvas format)
  as HTML: each node a card at its place on the board, and each edge an
  SVG curve between the sides it names, with its arrowheads and label.

  Text cards and embedded notes go through `BabelSync.Markdown`, so they
  read like notes and are sanitized the same way. Files show as their
  note, picture or PDF; links show as links. Groups sit behind the cards
  they hold. Everything that comes from the file is escaped, positions
  and sizes must be numbers, and colours must be one of Obsidian's six
  presets or a hex colour, so nothing in a canvas can style or script
  the page around it.
  """

  alias BabelSync.Markdown
  alias BabelSync.Markdown.Section
  alias BabelSync.Vaults.Entry

  @padding 48
  @arrow 11
  @image_extensions ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  @hex ~r/^#[0-9a-fA-F]{3,8}$/
  @sides ~w(top right bottom left)

  @type point :: {number(), number()}
  @type box :: %{x: number(), y: number(), width: number(), height: number()}

  @spec to_html(String.t(), [Entry.t()], Markdown.links()) :: {:ok, String.t()} | :error
  def to_html(text, entries, links) do
    case decode(text) do
      {:ok, %{} = canvas} -> {:ok, board(canvas, entries, links)}
      _not_a_canvas -> :error
    end
  end

  defp decode(""), do: {:ok, %{}}
  defp decode(text), do: Jason.decode(text)

  defp board(canvas, entries, links) do
    nodes = canvas |> Map.get("nodes") |> List.wrap() |> Enum.flat_map(&placed/1)

    case nodes do
      [] ->
        ~s(<p class="canvas-empty">This canvas is empty.</p>)

      nodes ->
        left = nodes |> Enum.map(& &1.x) |> Enum.min()
        top = nodes |> Enum.map(& &1.y) |> Enum.min()
        nodes = Enum.map(nodes, &%{&1 | x: &1.x - left + @padding, y: &1.y - top + @padding})
        width = nodes |> Enum.map(&(&1.x + &1.width)) |> Enum.max() |> Kernel.+(@padding)
        height = nodes |> Enum.map(&(&1.y + &1.height)) |> Enum.max() |> Kernel.+(@padding)
        by_id = Map.new(nodes, &{&1.id, &1})
        edges = canvas |> Map.get("edges") |> List.wrap() |> Enum.flat_map(&joined(&1, by_id))
        {groups, cards} = Enum.split_with(nodes, &(&1.type == "group"))

        ~s(<div class="canvas-board" style="width:#{px(width)};height:#{px(height)}">) <>
          Enum.map_join(groups, &group/1) <>
          ~s(<svg class="canvas-edges" width="#{round(width)}" height="#{round(height)}" aria-hidden="true">) <>
          Enum.map_join(edges, &edge/1) <>
          "</svg>" <>
          Enum.map_join(edges, &edge_label/1) <>
          Enum.map_join(cards, &card(&1, entries, links)) <>
          "</div>"
    end
  end

  defp placed(%{"id" => id, "type" => type} = node)
       when is_binary(id) and type in ~w(text file link group) do
    with [x, y, width, height] <- Enum.map(~w(x y width height), &node[&1]),
         true <- Enum.all?([x, y, width, height], &is_number/1) and width > 0 and height > 0 do
      [
        %{
          id: id,
          type: type,
          x: x,
          y: y,
          width: width,
          height: height,
          color: color(node["color"]),
          node: node
        }
      ]
    else
      _misplaced -> []
    end
  end

  defp placed(_other), do: []

  defp joined(%{"fromNode" => from, "toNode" => to} = edge, nodes) do
    case {nodes[from], nodes[to]} do
      {%{} = source, %{} = target} ->
        {from_side, to_side} = sides(source, target, edge["fromSide"], edge["toSide"])

        [
          %{
            from: anchor(source, from_side),
            from_side: from_side,
            to: anchor(target, to_side),
            to_side: to_side,
            from_end: edge["fromEnd"] == "arrow",
            to_end: edge["toEnd"] != "none",
            color: color(edge["color"]),
            label: if(is_binary(edge["label"]), do: edge["label"])
          }
        ]

      _missing ->
        []
    end
  end

  defp joined(_other, _nodes), do: []

  defp sides(source, target, from, to) do
    {facing_target, facing_source} = facing(source, target)

    {if(from in @sides, do: from, else: facing_target),
     if(to in @sides, do: to, else: facing_source)}
  end

  defp facing(source, target) do
    {sx, sy} = centre(source)
    {tx, ty} = centre(target)

    cond do
      abs(tx - sx) >= abs(ty - sy) and tx >= sx -> {"right", "left"}
      abs(tx - sx) >= abs(ty - sy) -> {"left", "right"}
      ty >= sy -> {"bottom", "top"}
      true -> {"top", "bottom"}
    end
  end

  defp centre(box), do: {box.x + box.width / 2, box.y + box.height / 2}

  defp anchor(box, "top"), do: {box.x + box.width / 2, box.y}
  defp anchor(box, "bottom"), do: {box.x + box.width / 2, box.y + box.height}
  defp anchor(box, "left"), do: {box.x, box.y + box.height / 2}
  defp anchor(box, "right"), do: {box.x + box.width, box.y + box.height / 2}

  defp normal("top"), do: {0, -1}
  defp normal("bottom"), do: {0, 1}
  defp normal("left"), do: {-1, 0}
  defp normal("right"), do: {1, 0}

  defp curve(edge) do
    {x1, y1} = edge.from
    {x2, y2} = edge.to
    reach = (:math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2) * 0.4) |> max(30) |> min(220)
    {ax, ay} = normal(edge.from_side)
    {bx, by} = normal(edge.to_side)
    {edge.from, {x1 + ax * reach, y1 + ay * reach}, {x2 + bx * reach, y2 + by * reach}, edge.to}
  end

  defp edge(edge) do
    {{x1, y1}, {c1x, c1y}, {c2x, c2y}, {x2, y2}} = curve(edge)

    ~s(<g class="canvas-edge"#{style(edge.color)}>) <>
      ~s(<path d="M#{n(x1)} #{n(y1)} C#{n(c1x)} #{n(c1y)} #{n(c2x)} #{n(c2y)} #{n(x2)} #{n(y2)}"/>) <>
      if(edge.to_end, do: arrowhead(edge.to, edge.to_side), else: "") <>
      if(edge.from_end, do: arrowhead(edge.from, edge.from_side), else: "") <>
      "</g>"
  end

  defp arrowhead({x, y}, side) do
    {nx, ny} = normal(side)
    {bx, by} = {x + nx * @arrow, y + ny * @arrow}
    {px, py} = {-ny * @arrow * 0.5, nx * @arrow * 0.5}

    ~s(<path class="canvas-arrow" d="M#{n(x)} #{n(y)} L#{n(bx + px)} #{n(by + py)} L#{n(bx - px)} #{n(by - py)} Z"/>)
  end

  defp edge_label(%{label: nil}), do: ""
  defp edge_label(%{label: ""}), do: ""

  defp edge_label(edge) do
    {{x1, y1}, {c1x, c1y}, {c2x, c2y}, {x2, y2}} = curve(edge)
    x = (x1 + 3 * c1x + 3 * c2x + x2) / 8
    y = (y1 + 3 * c1y + 3 * c2y + y2) / 8

    ~s(<div class="canvas-edge-label" style="left:#{px(x)};top:#{px(y)}">#{escape(edge.label)}</div>)
  end

  defp group(node) do
    label = node.node["label"]

    ~s(<div class="canvas-group"#{style(node.color, node)}>) <>
      if(is_binary(label) and label != "",
        do: ~s(<div class="canvas-group-label">#{escape(label)}</div>),
        else: ""
      ) <> "</div>"
  end

  defp card(node, entries, links) do
    ~s(<div class="canvas-node canvas-#{node.type}"#{style(node.color, node)}>) <>
      ~s(<div class="canvas-node-content">#{content(node, entries, links)}</div></div>)
  end

  defp content(%{type: "text", node: node}, entries, links) do
    if is_binary(node["text"]), do: Markdown.to_html(node["text"], entries, links), else: ""
  end

  defp content(%{type: "link", node: %{"url" => "http" <> _ = url}}, _entries, _links) do
    if url =~ ~r/^https?:\/\/\S+$/,
      do: ~s(<a class="canvas-link" href="#{escape(url)}">#{escape(url)}</a>),
      else: escape(url)
  end

  defp content(%{type: "link", node: node}, _entries, _links),
    do: if(is_binary(node["url"]), do: escape(node["url"]), else: "")

  defp content(%{type: "file", node: %{"file" => path} = node}, entries, links)
       when is_binary(path) do
    subpath = if is_binary(node["subpath"]), do: String.trim_leading(node["subpath"], "#")

    case Enum.find(entries, &(&1.path == path and is_nil(&1.deleted_at))) ||
           Markdown.resolve_target(path, entries) do
      %Entry{kind: :doc} = entry -> note(entry, subpath, entries, links)
      %Entry{kind: :blob} = entry -> attachment(entry, links)
      _missing -> ~s(<span class="unresolved">#{escape(path)}</span>)
    end
  end

  defp content(_node, _entries, _links), do: ""

  defp note(entry, subpath, entries, links) do
    title = Path.rootname(Path.basename(entry.path))

    body =
      if Map.has_key?(links, :text) and markdown?(entry.path) do
        entry
        |> links.text.()
        |> Section.extract(subpath)
        |> Markdown.to_html(entries, links)
      else
        ""
      end

    ~s(<a class="canvas-file-title" href="#{escape(links.note.(entry))}">#{escape(title)}</a>) <>
      body
  end

  defp attachment(entry, links) do
    source = escape(links.raw.(entry))
    name = escape(Path.basename(entry.path))

    case String.downcase(Path.extname(entry.path)) do
      extension when extension in @image_extensions ->
        ~s(<img src="#{source}" alt="#{name}">)

      ".pdf" ->
        ~s(<iframe class="embed-pdf" loading="lazy" title="#{name}" src="#{source}"></iframe>)

      _other ->
        ~s(<a class="embed-file" href="#{source}">#{name}</a>)
    end
  end

  defp markdown?(path), do: String.downcase(Path.extname(path)) == ".md"

  defp color(preset) when preset in ~w(1 2 3 4 5 6), do: "var(--canvas-#{preset})"

  defp color(hex) when is_binary(hex),
    do: if(Regex.match?(@hex, hex), do: String.downcase(hex), else: nil)

  defp color(_none), do: nil

  defp style(color), do: if(color, do: ~s( style="--canvas-color:#{color}"), else: "")

  defp style(color, box) do
    place = "left:#{px(box.x)};top:#{px(box.y)};width:#{px(box.width)};height:#{px(box.height)}"
    ~s( style="#{place}#{if color, do: ";--canvas-color:#{color}"}")
  end

  defp px(number), do: "#{n(number)}px"

  defp n(number),
    do: number |> Kernel.*(1.0) |> Float.round(1) |> :erlang.float_to_binary([:short])

  defp escape(text), do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
end
