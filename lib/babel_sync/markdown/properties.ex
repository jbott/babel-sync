defmodule BabelSync.Markdown.Properties do
  @moduledoc """
  Shows a note's front matter as a list of properties above the note,
  like Obsidian's properties view. Lists become chips, true and false
  become ticked or empty boxes, `tags` show as tags, and `[[links]]` and
  web addresses become links. Front matter that is not valid YAML is
  left out rather than shown half read.
  """

  @type link :: (String.t() -> String.t() | nil)

  @spec to_html(String.t() | nil, link()) :: String.t()
  def to_html(nil, _link), do: ""

  def to_html(yaml, link) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, properties} when is_map(properties) and map_size(properties) > 0 ->
        rows =
          properties
          |> Enum.sort_by(fn {key, _} -> to_string(key) end)
          |> Enum.map(fn {key, value} ->
            key = to_string(key)

            ~s(<div class="property"><dt>#{escape(key)}</dt><dd>#{value(key, value, link)}</dd></div>)
          end)

        ~s(<dl class="properties">#{rows}</dl>)

      _not_properties ->
        ""
    end
  end

  defp value(key, values, link) when is_list(values) do
    Enum.map_join(values, " ", &~s(<span class="property-item">#{item(key, &1, link)}</span>))
  end

  defp value(_key, true, _link), do: ~s(<input type="checkbox" checked disabled>)
  defp value(_key, false, _link), do: ~s(<input type="checkbox" disabled>)
  defp value(_key, nil, _link), do: ""
  defp value(_key, map, _link) when is_map(map), do: escape(Jason.encode!(map))
  defp value(key, value, link), do: item(key, value, link)

  defp item(key, value, _link) when key in ["tags", "tag"] and is_binary(value) do
    ~s(<span class="tag">##{escape(String.trim_leading(value, "#"))}</span>)
  end

  defp item(_key, value, link) when is_binary(value) do
    cond do
      match = Regex.run(~r/^\[\[([^\]|]+)(?:\|([^\]]+))?\]\]$/, value) ->
        [_, target | shown] = match
        linked(link.(target), List.first(shown) || target)

      Regex.match?(~r/^https?:\/\/\S+$/, value) ->
        ~s(<a href="#{escape(value)}">#{escape(value)}</a>)

      true ->
        escape(value)
    end
  end

  defp item(_key, value, _link) when is_map(value) or is_list(value),
    do: escape(Jason.encode!(value))

  defp item(_key, value, _link), do: escape(to_string(value))

  defp linked(nil, shown), do: escape(shown)
  defp linked(url, shown), do: ~s(<a href="#{escape(url)}">#{escape(shown)}</a>)

  defp escape(text), do: Plug.HTML.html_escape(text)
end
