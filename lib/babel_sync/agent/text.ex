defmodule BabelSync.Agent.Text do
  @moduledoc """
  Line-oriented work on the text of a note: revisions, line ranges,
  outlines, exact-passage edits, appending to a section and searching.
  """

  @snippet_context 2
  @snippet_lines 30
  @line_width 300
  @matches_per_file 20

  @type heading :: %{line: pos_integer(), level: 1..6, title: String.t()}

  @spec rev(String.t()) :: String.t()
  def rev(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @spec line_count(String.t()) :: non_neg_integer()
  def line_count(text), do: text |> lines() |> length()

  @spec slice(String.t(), pos_integer(), pos_integer()) :: %{
          text: String.t(),
          first: non_neg_integer(),
          last: non_neg_integer(),
          total: non_neg_integer()
        }
  def slice(text, offset, limit) do
    all = lines(text)
    total = length(all)
    wanted = all |> Enum.drop(offset - 1) |> Enum.take(limit)

    case wanted do
      [] ->
        %{text: "", first: 0, last: 0, total: total}

      ^all ->
        %{text: text, first: 1, last: total, total: total}

      part ->
        %{
          text: Enum.join(part, "\n"),
          first: offset,
          last: offset + length(part) - 1,
          total: total
        }
    end
  end

  @spec number(String.t(), pos_integer()) :: String.t()
  def number(text, first) do
    text
    |> lines()
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {line, number} ->
      String.pad_leading(Integer.to_string(number), 6) <> "\t" <> line
    end)
  end

  @spec outline(String.t()) :: %{properties: [String.t()], headings: [heading()]}
  def outline(text) do
    all = lines(text)
    {properties, body_from} = properties(all)
    %{properties: properties, headings: headings(all, body_from)}
  end

  @spec edit(String.t(), [%{old_text: String.t(), new_text: String.t()}]) ::
          {:ok, String.t()} | {:error, {:no_match | :ambiguous_match, pos_integer()}}
  def edit(text, edits) do
    edits
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, text}, fn {edit, number}, {:ok, text} ->
      case replace(text, edit) do
        {:ok, text} -> {:cont, {:ok, text}}
        {:error, reason} -> {:halt, {:error, {reason, number}}}
      end
    end)
  end

  @spec append(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_heading | :ambiguous_heading}
  def append(text, content, nil) do
    separator = if text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"
    {:ok, text <> separator <> content}
  end

  def append(text, content, heading) do
    wanted = heading |> String.trim_leading("#") |> String.trim() |> String.downcase()
    %{headings: headings} = outline(text)

    case Enum.filter(headings, &(String.downcase(&1.title) == wanted)) do
      [found] -> {:ok, insert_at_section_end(text, content, found, headings)}
      [] -> {:error, :no_heading}
      _several -> {:error, :ambiguous_heading}
    end
  end

  @spec changed(String.t(), String.t()) :: String.t()
  def changed(old, new) do
    old_lines = lines(old)
    new_lines = lines(new)
    same_before = shared(old_lines, new_lines)

    same_after =
      shared(
        old_lines |> Enum.drop(same_before) |> Enum.reverse(),
        new_lines |> Enum.drop(same_before) |> Enum.reverse()
      )

    first = max(same_before + 1 - @snippet_context, 1)
    last = min(length(new_lines) - same_after + @snippet_context, length(new_lines))
    shown = new_lines |> Enum.slice((first - 1)..(last - 1)//1) |> Enum.take(@snippet_lines)
    hidden = last - first + 1 - length(shown)

    numbered = shown |> Enum.join("\n") |> number(first)
    if hidden > 0, do: numbered <> "\n… #{hidden} more changed lines", else: numbered
  end

  @spec search(String.t(), Regex.t(), non_neg_integer()) :: [
          %{line: pos_integer(), text: String.t(), match: boolean()}
        ]
  def search(text, pattern, context) do
    numbered = text |> lines() |> Enum.with_index(1)

    hits =
      numbered
      |> Stream.filter(fn {line, _number} -> Regex.match?(pattern, line) end)
      |> Stream.map(&elem(&1, 1))
      |> Enum.take(@matches_per_file)

    shown = MapSet.new(hits, & &1) |> around(context)

    for {line, number} <- numbered, number in shown do
      %{line: number, text: String.slice(line, 0, @line_width), match: number in hits}
    end
  end

  defp around(hits, 0), do: hits

  defp around(hits, context) do
    for hit <- hits, number <- (hit - context)..(hit + context), into: MapSet.new(), do: number
  end

  defp lines(text) do
    case text |> String.split("\n") |> Enum.reverse() do
      ["" | rest] -> Enum.reverse(rest)
      _unterminated -> String.split(text, "\n")
    end
  end

  defp properties(["---" | rest]) do
    case Enum.split_while(rest, &(String.trim_trailing(&1) != "---")) do
      {_unclosed, []} ->
        {[], 1}

      {block, _closing_and_body} ->
        keys =
          for line <- block,
              [_all, key] <- [Regex.run(~r/^([^\s#:-][^:]*):(?:\s|$)/u, line)],
              do: key

        {keys, length(block) + 3}
    end
  end

  defp properties(_lines), do: {[], 1}

  defp headings(all, body_from) do
    all
    |> Enum.with_index(1)
    |> Enum.drop(body_from - 1)
    |> Enum.reduce({[], nil}, fn {line, number}, {found, fence} ->
      marker = fence_marker(line)

      cond do
        fence && marker == fence -> {found, nil}
        fence -> {found, fence}
        marker -> {found, marker}
        heading = heading(line) -> {[Map.put(heading, :line, number) | found], nil}
        true -> {found, nil}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp fence_marker(line) do
    case Regex.run(~r/^\s{0,3}(```|~~~)/, line) do
      [_all, marker] -> marker
      nil -> nil
    end
  end

  defp heading(line) do
    case Regex.run(~r/^(\#{1,6})\s+(.*?)(?:\s+#+)?\s*$/u, line) do
      [_all, marks, title] -> %{level: String.length(marks), title: title}
      nil -> nil
    end
  end

  defp insert_at_section_end(text, content, heading, headings) do
    raw = String.split(text, "\n")

    section_end =
      case Enum.find(headings, &(&1.line > heading.line and &1.level <= heading.level)) do
        nil -> length(raw)
        next -> next.line - 1
      end

    last_written =
      Enum.find(section_end..heading.line//-1, heading.line, fn number ->
        raw |> Enum.at(number - 1) |> String.trim() != ""
      end)

    {before, rest} = Enum.split(raw, last_written)
    added = content |> String.trim_trailing("\n") |> String.split("\n")
    rest = if rest == [], do: [], else: rest
    Enum.join(before ++ added ++ rest, "\n")
  end

  defp replace(_text, %{old_text: ""}), do: {:error, :ambiguous_match}

  defp replace(text, %{old_text: old_text, new_text: new_text} = edit) do
    case String.split(text, old_text) do
      [_untouched] ->
        {:error, :no_match}

      [before, rest] ->
        {:ok, before <> new_text <> rest}

      parts ->
        if edit[:replace_all],
          do: {:ok, Enum.join(parts, new_text)},
          else: {:error, :ambiguous_match}
    end
  end

  defp shared(left, right) do
    left |> Enum.zip(right) |> Enum.take_while(fn {a, b} -> a == b end) |> length()
  end
end
