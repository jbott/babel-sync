defmodule BabelSync.Sync.Changes do
  @moduledoc """
  Compares two versions of a note for a person to read: the lines that
  were removed and added, the words that changed inside a line that was
  edited rather than replaced, and a few unchanged lines around each
  change so it can be placed. Long runs of unchanged lines are left out.
  """

  @context 3
  @word_limit 2_000
  @similar 0.4

  @type segment :: {:same | :removed | :added, String.t()}
  @type line :: %{
          kind: :same | :removed | :added,
          old: pos_integer() | nil,
          new: pos_integer() | nil,
          segments: [segment()]
        }
  @type hunk :: %{old_start: pos_integer(), new_start: pos_integer(), lines: [line()]}
  @type t :: %{added: non_neg_integer(), removed: non_neg_integer(), hunks: [hunk()]}

  @spec compare(String.t(), String.t()) :: t()
  def compare(old, new) do
    rows = old |> lines() |> List.myers_difference(lines(new)) |> rows(1, 1, [])

    %{
      added: Enum.count(rows, &(&1.kind == :added)),
      removed: Enum.count(rows, &(&1.kind == :removed)),
      hunks: hunks(rows)
    }
  end

  @spec count(String.t(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  def count(old, new) do
    old
    |> lines()
    |> List.myers_difference(lines(new))
    |> Enum.reduce({0, 0}, fn
      {:ins, added}, {plus, minus} -> {plus + length(added), minus}
      {:del, removed}, {plus, minus} -> {plus, minus + length(removed)}
      {:eq, _same}, counts -> counts
    end)
  end

  @spec to_json(t()) :: map()
  def to_json(changes) do
    %{
      added: changes.added,
      removed: changes.removed,
      hunks:
        for hunk <- changes.hunks do
          %{
            old_start: hunk.old_start,
            new_start: hunk.new_start,
            lines:
              for line <- hunk.lines do
                %{
                  kind: line.kind,
                  old: line.old,
                  new: line.new,
                  segments: for({kind, text} <- line.segments, do: [kind, text])
                }
              end
          }
        end
    }
  end

  defp lines(""), do: []
  defp lines(text), do: text |> String.trim_trailing("\n") |> String.split("\n")

  defp rows([{:del, removed}, {:ins, added} | rest], old, new, acc),
    do: edited(removed, added, rest, old, new, acc)

  defp rows([{:ins, added}, {:del, removed} | rest], old, new, acc),
    do: edited(removed, added, rest, old, new, acc)

  defp rows([{:eq, same} | rest], old, new, acc) do
    shown =
      same
      |> Enum.with_index()
      |> Enum.map(fn {text, at} ->
        %{kind: :same, old: old + at, new: new + at, segments: [{:same, text}]}
      end)

    rows(rest, old + length(same), new + length(same), Enum.reverse(shown, acc))
  end

  defp rows([{:del, removed} | rest], old, new, acc),
    do: edited(removed, [], rest, old, new, acc)

  defp rows([{:ins, added} | rest], old, new, acc),
    do: edited([], added, rest, old, new, acc)

  defp rows([], _old, _new, acc), do: Enum.reverse(acc)

  defp edited(removed, added, rest, old, new, acc) do
    pairs = min(length(removed), length(added))

    {removed_segments, added_segments} =
      removed
      |> Enum.zip(added)
      |> Enum.map(fn {before, now} -> words(before, now) end)
      |> Enum.unzip()

    removed_rows =
      (removed_segments ++ for(text <- Enum.drop(removed, pairs), do: [{:removed, text}]))
      |> Enum.with_index()
      |> Enum.map(fn {segments, at} ->
        %{kind: :removed, old: old + at, new: nil, segments: segments}
      end)

    added_rows =
      (added_segments ++ for(text <- Enum.drop(added, pairs), do: [{:added, text}]))
      |> Enum.with_index()
      |> Enum.map(fn {segments, at} ->
        %{kind: :added, old: nil, new: new + at, segments: segments}
      end)

    rows(
      rest,
      old + length(removed),
      new + length(added),
      Enum.reverse(added_rows, Enum.reverse(removed_rows, acc))
    )
  end

  defp words(before, now) when byte_size(before) + byte_size(now) > @word_limit,
    do: {[{:removed, before}], [{:added, now}]}

  defp words(before, now) do
    diff = List.myers_difference(tokens(before), tokens(now))
    kept = diff |> Enum.filter(&(elem(&1, 0) == :eq)) |> Enum.map(&joined/1) |> Enum.sum()

    if kept < @similar * max(String.length(before), String.length(now)) do
      {[{:removed, before}], [{:added, now}]}
    else
      {segments(diff, :del, :removed), segments(diff, :ins, :added)}
    end
  end

  defp joined({_kind, tokens}), do: tokens |> Enum.join() |> String.length()

  defp segments(diff, side, kind) do
    diff
    |> Enum.flat_map(fn
      {:eq, tokens} -> [{:same, Enum.join(tokens)}]
      {^side, tokens} -> [{kind, Enum.join(tokens)}]
      _other_side -> []
    end)
    |> merge()
  end

  defp merge([{kind, a}, {kind, b} | rest]), do: merge([{kind, a <> b} | rest])
  defp merge([segment | rest]), do: [segment | merge(rest)]
  defp merge([]), do: []

  defp tokens(text),
    do: Regex.scan(~r/[\p{L}\p{N}_]+|\s+|[^\p{L}\p{N}_\s]/u, text) |> List.flatten()

  defp hunks(rows) do
    table = List.to_tuple(rows)
    last = tuple_size(table) - 1

    changed =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _at} -> row.kind != :same end)
      |> Enum.map(&elem(&1, 1))

    changed
    |> Enum.map(&{max(&1 - @context, 0), min(&1 + @context, last)})
    |> Enum.reduce([], fn
      {from, to}, [{start, stop} | rest] when from <= stop + 1 -> [{start, max(stop, to)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(fn {from, to} ->
      shown = for at <- from..to//1, do: elem(table, at)
      %{old_start: start(shown, :old), new_start: start(shown, :new), lines: shown}
    end)
  end

  defp start(shown, side) do
    Enum.find_value(shown, 1, &Map.get(&1, side))
  end
end
