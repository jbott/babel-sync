defmodule BabelSync.Agent.TextTest do
  use ExUnit.Case, async: true

  alias BabelSync.Agent.Text

  @note """
  ---
  title: Trip
  tags: [travel]
  ---
  # Trip

  intro

  ## Tasks
  - book flights

  ```
  # not a heading
  ```

  ### Later
  - pack

  ## Notes ##
  none yet
  """

  test "a rev names the exact text" do
    assert Text.rev("a") == Text.rev("a")
    assert Text.rev("a") != Text.rev("a\n")
    assert Text.rev("a") =~ ~r/^[0-9a-f]{8}$/
  end

  test "lines are counted with or without a final line break" do
    assert Text.line_count("") == 0
    assert Text.line_count("a") == 1
    assert Text.line_count("a\n") == 1
    assert Text.line_count("a\n\n") == 2
  end

  test "a slice of the whole note is the note, byte for byte" do
    assert %{text: "a\nb\n", first: 1, last: 2, total: 2} = Text.slice("a\nb\n", 1, 2000)
    assert %{text: "b\nc", first: 2, last: 3, total: 4} = Text.slice("a\nb\nc\nd\n", 2, 2)
    assert %{text: "", first: 0, last: 0, total: 2} = Text.slice("a\nb\n", 9, 5)
    assert %{text: "", first: 0, total: 0} = Text.slice("", 1, 5)
  end

  test "lines can be numbered from any start" do
    assert Text.number("x\ny", 9) == "     9\tx\n    10\ty"
  end

  test "an outline lists properties and headings but not fenced code" do
    assert %{properties: ["title", "tags"], headings: headings} = Text.outline(@note)

    assert headings == [
             %{line: 5, level: 1, title: "Trip"},
             %{line: 9, level: 2, title: "Tasks"},
             %{line: 16, level: 3, title: "Later"},
             %{line: 19, level: 2, title: "Notes"}
           ]

    assert %{properties: [], headings: [%{line: 1, title: "Only"}]} = Text.outline("# Only")
    assert %{properties: [], headings: []} = Text.outline("---\nunclosed: yes\n")
  end

  test "edits apply in order and all or nothing" do
    assert {:ok, "A b C"} =
             Text.edit("a b c", [%{old_text: "a", new_text: "A"}, %{old_text: "c", new_text: "C"}])

    assert {:error, {:no_match, 2}} =
             Text.edit("a b c", [%{old_text: "a", new_text: "A"}, %{old_text: "z", new_text: "Z"}])

    assert {:error, {:ambiguous_match, 1}} = Text.edit("x x", [%{old_text: "x", new_text: "y"}])
    assert {:error, {:ambiguous_match, 1}} = Text.edit("x x", [%{old_text: "", new_text: "y"}])

    assert {:ok, "y y"} =
             Text.edit("x x", [%{old_text: "x", new_text: "y", replace_all: true}])
  end

  test "appending adds a line break only when one is missing" do
    assert {:ok, "x"} = Text.append("", "x", nil)
    assert {:ok, "a\nx"} = Text.append("a", "x", nil)
    assert {:ok, "a\nx\n"} = Text.append("a\n", "x\n", nil)
  end

  test "appending under a heading lands at the end of its section" do
    assert {:ok, text} = Text.append(@note, "- rent a car\n", "tasks")
    assert text =~ "### Later\n- pack\n- rent a car\n\n## Notes ##\n"

    assert {:ok, text} = Text.append(@note, "- visas", "## Later")
    assert text =~ "- pack\n- visas\n\n## Notes"

    assert {:ok, text} = Text.append(@note, "more", "Notes")
    assert String.ends_with?(text, "none yet\nmore\n")

    assert {:ok, "# A\nx"} = Text.append("# A", "x", "A")
    assert {:ok, "# A\nx\n\n# B\n"} = Text.append("# A\n\n# B\n", "x", "A")
    assert {:error, :no_heading} = Text.append(@note, "x", "Missing")
    assert {:error, :ambiguous_heading} = Text.append("# A\n# A\n", "x", "A")
  end

  test "the changed lines are shown with a little context" do
    old = Enum.map_join(1..20, "\n", &"line #{&1}")
    new = String.replace(old, "line 10", "line ten")

    assert Text.changed(old, new) ==
             "     8\tline 8\n     9\tline 9\n    10\tline ten\n    11\tline 11\n    12\tline 12"

    assert Text.changed("a\nb\nc", "a\nc") == "     1\ta\n     2\tc"
    assert Text.changed("", "x\n") == "     1\tx"

    long = Text.changed("", Enum.map_join(1..50, "\n", &"l#{&1}"))
    assert long =~ "    30\tl30\n… 20 more changed lines"
  end

  test "search returns matching lines, with context when asked" do
    text = "alpha\nbeta\ngamma\ndelta\nBETA again"

    assert [%{line: 2, text: "beta", match: true}, %{line: 5, match: true}] =
             Text.search(text, ~r/beta/i, 0)

    assert [%{line: 2}] = Text.search(text, ~r/beta/, 0)

    assert [
             %{line: 1, match: false},
             %{line: 2, match: true},
             %{line: 3, match: false},
             %{line: 4, match: false},
             %{line: 5, match: true}
           ] = Text.search(text, ~r/beta/i, 1)

    assert [] = Text.search(text, ~r/omega/, 2)
    assert [%{text: cut}] = Text.search(String.duplicate("x", 500), ~r/x/, 0)
    assert String.length(cut) == 300
  end
end
