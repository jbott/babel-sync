defmodule BabelSync.Markdown.FrontMatter do
  @moduledoc """
  Changes some of a note's properties and leaves the rest of its front
  matter exactly as it was written: the order, the quoting, comments and
  every property not named.

  A property is the line that names it and the indented or list lines
  under it. One whose value is already what is wanted is not rewritten,
  so a change that changes nothing gives back the same text.

  `merge/3` is for something that sets the same properties again and
  again, such as a source. Told what it set last time, it replaces a
  plain value, but in a list it takes out only the items it put there
  and keeps those a person added.
  """

  @type value :: String.t() | number() | boolean() | nil | [value()] | %{String.t() => value()}

  @opening "---\n"
  @named ~r/^(?:"([^"]+)"|'([^']+)'|([^\s#"'\-][^:]*?))\s*:(?:\s|$)/

  @spec read(String.t()) :: {:ok, %{String.t() => value()}} | {:error, :invalid_front_matter}
  def read(text) do
    case split(text) do
      {nil, _body} -> {:ok, %{}}
      {lines, _body} -> parse(Enum.join(lines, "\n"))
    end
  end

  @spec set(String.t(), [{String.t(), value()}]) ::
          {:ok, String.t()} | {:error, :invalid_front_matter}
  def set(text, changes), do: change(text, changes, fn _key, _current, wanted -> wanted end)

  @spec merge(String.t(), [{String.t(), value()}], %{String.t() => value()}) ::
          {:ok, String.t()} | {:error, :invalid_front_matter}
  def merge(text, changes, written) do
    change(text, changes, fn key, current, wanted ->
      combine(current, wanted, Map.get(written, key))
    end)
  end

  defp change(text, changes, resolve) do
    {lines, body} = split(text)

    with {:ok, current} <- parse(Enum.join(lines || [], "\n")) do
      wanted =
        Enum.flat_map(changes, fn {key, value} ->
          merged = resolve.(key, Map.get(current, key), value)
          if merged == Map.get(current, key), do: [], else: [{key, merged}]
        end)

      case wanted do
        [] -> {:ok, text}
        wanted -> {:ok, join(Enum.reduce(wanted, blocks(lines || []), &put/2), body)}
      end
    end
  end

  defp combine(current, wanted, written) when is_list(wanted) do
    kept = List.wrap(current) -- List.wrap(written)
    Enum.uniq(wanted ++ kept)
  end

  defp combine(_current, wanted, _written), do: wanted

  defp split(@opening <> rest = text) do
    lines = String.split(rest, "\n")

    case Enum.find_index(lines, &(&1 == "---")) do
      nil -> {nil, text}
      at -> {Enum.take(lines, at), lines |> Enum.drop(at + 1) |> Enum.join("\n")}
    end
  end

  defp split(text), do: {nil, text}

  defp parse(""), do: {:ok, %{}}

  defp parse(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, properties} when is_map(properties) ->
        {:ok, Map.new(properties, fn {key, value} -> {to_string(key), value} end)}

      {:ok, nil} ->
        {:ok, %{}}

      _not_properties ->
        {:error, :invalid_front_matter}
    end
  end

  defp blocks(lines) do
    lines
    |> Enum.reduce([], fn line, blocks ->
      case {name(line), blocks} do
        {nil, [{key, held} | rest]} -> [{key, [line | held]} | rest]
        {nil, []} -> [{nil, [line]}]
        {key, blocks} -> [{key, [line]} | blocks]
      end
    end)
    |> Enum.map(fn {key, held} -> {key, Enum.reverse(held)} end)
    |> Enum.reverse()
  end

  defp name(line) do
    case Regex.run(@named, line) do
      nil -> nil
      found -> found |> tl() |> Enum.find(&(&1 != ""))
    end
  end

  defp put({key, nil}, blocks), do: Enum.reject(blocks, fn {name, _lines} -> name == key end)

  defp put({key, value}, blocks) do
    written = {key, render(key, value)}

    if Enum.any?(blocks, fn {name, _lines} -> name == key end),
      do:
        Enum.map(blocks, fn {name, lines} -> if(name == key, do: written, else: {name, lines}) end),
      else: blocks ++ [written]
  end

  defp join(blocks, body) do
    case Enum.flat_map(blocks, fn {_key, lines} -> lines end) do
      [] -> body
      lines -> @opening <> Enum.join(lines, "\n") <> "\n---\n" <> body
    end
  end

  defp render(key, []), do: ["#{label(key)}: []"]

  defp render(key, items) when is_list(items) do
    ["#{label(key)}:" | Enum.map(items, &"  - #{scalar(&1)}")]
  end

  defp render(key, value), do: ["#{label(key)}: #{scalar(value)}"]

  defp label(key),
    do: if(plain?(key) and name("#{key}: x") == key, do: key, else: Jason.encode!(key))

  defp scalar(text) when is_binary(text),
    do: if(plain?(text), do: text, else: Jason.encode!(text))

  defp scalar(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp scalar(nil), do: "null"
  defp scalar(nested), do: Jason.encode!(nested)

  defp plain?(text) do
    String.printable?(text) and not String.contains?(text, ["\n", "\t"]) and
      YamlElixir.read_from_string("- " <> text) == {:ok, [text]}
  end
end
