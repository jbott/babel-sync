defmodule BabelSync.Markdown.Section do
  @moduledoc """
  Finds the part of a note that a link points into, the way Obsidian
  does: `Heading`, `Heading#Subheading` or `^block-id`.

  Headings are compared by a key that ignores punctuation, runs of
  whitespace and case, so `#9 00 AM` finds `## 9:00 AM`. The same key
  names the heading's anchor in rendered HTML, so a link and the heading
  it points to always agree.
  """

  @punctuation ~r/[\p{P}!-\/:-@\[-`{-~]/u
  @heading ~r/^ {0,3}(\#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/
  @fence ~r/^ {0,3}(`{3,}|~{3,})/

  @spec key(String.t()) :: String.t()
  def key(text) do
    text
    |> String.replace(@punctuation, " ")
    |> String.split()
    |> Enum.join("-")
    |> String.downcase()
  end

  @spec block_marker(String.t()) :: Regex.t()
  def block_marker(id), do: ~r/(?:^|[ \t])\^#{Regex.escape(id)}[ \t]*$/m

  @spec extract(String.t(), String.t() | nil) :: String.t()
  def extract(text, nil), do: text
  def extract(text, ""), do: text

  def extract(text, "^" <> id) do
    blocks = String.split(text, ~r/\n[ \t]*\n/)
    marker = block_marker(id)

    case Enum.find_index(blocks, &Regex.match?(marker, &1)) do
      nil ->
        text

      at ->
        named = marker |> Regex.replace(Enum.at(blocks, at), "") |> String.trim_trailing()
        if named == "" and at > 0, do: Enum.at(blocks, at - 1), else: named
    end
  end

  def extract(text, path) do
    lines = String.split(text, "\n")
    headings = headings(lines)
    parts = path |> String.split("#") |> Enum.map(&key/1) |> Enum.reject(&(&1 == ""))

    case find(headings, parts, nil) do
      nil ->
        text

      {at, level, _key} ->
        stop =
          Enum.find_value(headings, fn {line, other, _} ->
            line > at and other <= level and line
          end)

        lines |> Enum.slice(at..((stop || length(lines)) - 1)//1) |> Enum.join("\n")
    end
  end

  defp find(_headings, [], found), do: found

  defp find(headings, [part | rest], within) do
    candidates =
      case within do
        nil ->
          headings

        {at, level, _key} ->
          headings
          |> Enum.drop_while(fn {line, _, _} -> line <= at end)
          |> Enum.take_while(fn {_, other, _} -> other > level end)
      end

    case Enum.find(candidates, fn {_, _, key} -> key == part end) do
      nil -> nil
      found -> find(headings, rest, found)
    end
  end

  defp headings(lines) do
    {found, _fence} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, at}, {found, fence} ->
        case {fence, Regex.run(@fence, line), Regex.run(@heading, line)} do
          {nil, [_, opened], _} ->
            {found, String.first(opened)}

          {nil, nil, [_, hashes, title]} ->
            {[{at, String.length(hashes), key(title)} | found], nil}

          {nil, nil, nil} ->
            {found, nil}

          {mark, [_, closed], _} ->
            if String.first(closed) == mark, do: {found, nil}, else: {found, mark}

          {mark, nil, _} ->
            {found, mark}
        end
      end)

    Enum.reverse(found)
  end
end
