defmodule BabelSync.Sync.TextDiffTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sync.TextDiff

  defp patch(old, ops) do
    {out, rest} =
      Enum.reduce(ops, {"", old}, fn
        {:retain, n}, {out, rest} ->
          <<kept::binary-size(^n), rest::binary>> = rest
          {out <> kept, rest}

        {:delete, n}, {out, rest} ->
          <<_gone::binary-size(^n), rest::binary>> = rest
          {out, rest}

        {:insert, text}, {out, rest} ->
          {out <> text, rest}
      end)

    out <> rest
  end

  defp consumed(ops) do
    Enum.sum(for {kind, n} <- ops, kind in [:retain, :delete], do: n)
  end

  test "equal texts produce no edits" do
    assert TextDiff.ops("same", "same") == [{:retain, 4}]
    assert TextDiff.ops("", "") == []
  end

  test "an insertion in the middle keeps both sides" do
    assert TextDiff.ops("hello world", "hello big world") ==
             [{:retain, 6}, {:insert, "big "}, {:retain, 5}]
  end

  test "edits never split a multi-byte character" do
    old = "a😀b"
    new = "a😃b"
    ops = TextDiff.ops(old, new)

    assert patch(old, ops) == new
    assert {:delete, 4} in ops
    assert {:insert, "😃"} in ops
  end

  test "ops cover the whole old text and reproduce the new one" do
    samples = [
      {"", "new"},
      {"old", ""},
      {"line one\nline two\nline three\n", "line one\nline 2\nline three\nline four\n"},
      {"# Title\n\n- [ ] a\n- [ ] b\n", "# Title\n\n- [x] a\n- [ ] b\n- [ ] c\n"},
      {"naïve café", "naive cafe"},
      {"日本語のテキスト", "日本語テキストです"},
      {"aaaa", "aa"},
      {"abcabc", "abc"},
      {String.duplicate("x\n", 5000),
       String.duplicate("x\n", 2500) <> "y\n" <> String.duplicate("x\n", 2500)}
    ]

    for {old, new} <- samples do
      ops = TextDiff.ops(old, new)
      assert patch(old, ops) == new
      assert consumed(ops) == byte_size(old)

      for {:insert, text} <- ops, do: assert(String.valid?(text))
    end
  end

  test "random edits round-trip" do
    alphabet = ["a", "b", "\n", " ", "é", "😀", "日"]
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..300 do
      old = Enum.map_join(1..:rand.uniform(40), fn _ -> Enum.random(alphabet) end)
      new = Enum.map_join(1..:rand.uniform(40), fn _ -> Enum.random(alphabet) end)
      ops = TextDiff.ops(old, new)

      assert patch(old, ops) == new
      assert consumed(ops) == byte_size(old)
    end
  end
end
