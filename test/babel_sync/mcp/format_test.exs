defmodule BabelSync.MCP.FormatTest do
  use ExUnit.Case, async: true

  alias BabelSync.MCP.Format

  test "a listing longer than its limit says how much was left out and what to do" do
    paths = for n <- 1..5, do: "note #{n}.md"

    assert Format.capped(paths, 5, &Format.paths/1, "Narrow it.") == Enum.join(paths, "\n")

    assert Format.capped(paths, 3, &Format.paths/1, "Narrow it.") ==
             "note 1.md\nnote 2.md\nnote 3.md\n2 more not shown. Narrow it."

    assert Format.capped([], 3, &Format.paths/1, "Narrow it.") == "No file matches."
  end

  test "a history says when older versions exist" do
    assert Format.history(%{versions: [], older: 0}) == "[]"
    assert Format.history(%{versions: [%{version: 9}], older: 4}) =~ "4 older versions not shown"
  end
end
