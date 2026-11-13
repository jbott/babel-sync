defmodule BabelSync.TextPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BabelSync.Sync.{Changes, TextDiff}

  defp text do
    gen all(lines <- list_of(line(), max_length: 12), ending <- member_of(["", "\n"])) do
      Enum.join(lines, "\n") <> ending
    end
  end

  defp line do
    one_of([
      member_of(["", "same line", "# Heading", "- [ ] task", "café ☕", "😀 emoji", "  indented"]),
      string(:printable, max_length: 20),
      string([?a, ?b, ?\s, ?é, ?😀], max_length: 12)
    ])
  end

  defp edited do
    gen(all(old <- text(), new <- one_of([text(), mutation(old)]), do: {old, new}))
  end

  defp mutation(text) do
    lines = String.split(text, "\n")

    gen all(at <- integer(0..length(lines)), extra <- line(), drop <- boolean()) do
      lines
      |> List.insert_at(at, extra)
      |> then(
        &if(drop and length(&1) > 1, do: List.delete_at(&1, rem(at + 1, length(&1))), else: &1)
      )
      |> Enum.join("\n")
    end
  end

  defp patch(old, ops) do
    {out, rest} =
      Enum.reduce(ops, {[], old}, fn
        {:retain, n}, {out, rest} ->
          <<kept::binary-size(^n), rest::binary>> = rest
          {[out, kept], rest}

        {:delete, n}, {out, rest} ->
          <<_gone::binary-size(^n), rest::binary>> = rest
          {out, rest}

        {:insert, text}, {out, rest} ->
          {[out, text], rest}
      end)

    IO.iodata_to_binary([out, rest])
  end

  defp lines(""), do: []
  defp lines(text), do: text |> String.trim_trailing("\n") |> String.split("\n")

  property "applying the edits to the old text always gives the new text" do
    check all({old, new} <- edited()) do
      ops = TextDiff.ops(old, new)
      assert patch(old, ops) == new
    end
  end

  property "edits never cut a character in half" do
    check all({old, new} <- edited()) do
      Enum.reduce(TextDiff.ops(old, new), old, fn
        {:retain, n}, rest ->
          <<kept::binary-size(^n), rest::binary>> = rest
          assert String.valid?(kept)
          rest

        {:delete, n}, rest ->
          <<gone::binary-size(^n), rest::binary>> = rest
          assert String.valid?(gone)
          rest

        {:insert, text}, rest ->
          assert String.valid?(text)
          rest
      end)
    end
  end

  property "every line shown in a comparison is the line it claims to be" do
    check all({old, new} <- edited()) do
      old_lines = lines(old)
      new_lines = lines(new)
      changes = Changes.compare(old, new)

      for hunk <- changes.hunks, line <- hunk.lines do
        joined = Enum.map_join(line.segments, &elem(&1, 1))
        if line.old, do: assert(Enum.at(old_lines, line.old - 1) == joined)
        if line.new, do: assert(Enum.at(new_lines, line.new - 1) == joined)
        assert line.kind != :same or (line.old && line.new)
      end
    end
  end

  property "the counts agree with the lines shown and with count/2" do
    check all({old, new} <- edited()) do
      changes = Changes.compare(old, new)
      shown = Enum.flat_map(changes.hunks, & &1.lines)

      assert Enum.count(shown, &(&1.kind == :added)) == changes.added
      assert Enum.count(shown, &(&1.kind == :removed)) == changes.removed
      assert Changes.count(old, new) == {changes.added, changes.removed}
      assert length(lines(new)) == length(lines(old)) + changes.added - changes.removed
    end
  end

  property "a text compared with itself has no changes" do
    check all(text <- text()) do
      assert %{added: 0, removed: 0, hunks: []} = Changes.compare(text, text)
    end
  end
end
