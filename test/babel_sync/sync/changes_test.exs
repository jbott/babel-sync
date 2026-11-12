defmodule BabelSync.Sync.ChangesTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sync.Changes

  test "identical texts have no changes" do
    assert %{added: 0, removed: 0, hunks: []} = Changes.compare("a\nb\n", "a\nb\n")
  end

  test "a new note is all added lines" do
    assert %{added: 2, removed: 0, hunks: [hunk]} = Changes.compare("", "one\ntwo\n")
    assert Enum.map(hunk.lines, &{&1.kind, &1.new}) == [added: 1, added: 2]
  end

  test "an edited line shows the words that changed" do
    %{hunks: [hunk]} = Changes.compare("the quick fox\n", "the slow fox\n")

    assert [removed, added] = hunk.lines
    assert removed.segments == [same: "the ", removed: "quick", same: " fox"]
    assert added.segments == [same: "the ", added: "slow", same: " fox"]
  end

  test "a rewritten line is shown whole rather than word by word" do
    %{hunks: [hunk]} = Changes.compare("alpha beta\n", "gamma delta\n")

    assert Enum.map(hunk.lines, & &1.segments) == [
             [removed: "alpha beta"],
             [added: "gamma delta"]
           ]
  end

  test "far apart changes become separate hunks with context around each" do
    old = Enum.map_join(1..30, "\n", &"line #{&1}")
    new = old |> String.replace("line 2\n", "line two\n") |> String.replace("line 28", "line 28!")

    assert %{added: 2, removed: 2, hunks: [first, second]} = Changes.compare(old, new)
    assert first.old_start == 1
    assert Enum.map(first.lines, &(&1.old || &1.new)) == [1, 2, 2, 3, 4, 5]
    assert second.old_start == 25
    assert List.last(second.lines).old == 30
  end

  test "counting agrees with comparing" do
    assert Changes.count("a\nb\nc\n", "a\nc\nd\n") == {1, 1}
  end

  test "the json shape keeps segments as pairs" do
    json = "x\n" |> Changes.compare("y\n") |> Changes.to_json()
    assert [%{lines: [%{kind: :removed, segments: [[:removed, "x"]]}, _added]}] = json.hunks
  end
end
