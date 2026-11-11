defmodule BabelSync.Agent.GlobTest do
  use ExUnit.Case, async: true

  alias BabelSync.Agent.Glob

  defp matches?(pattern, path) do
    {:ok, glob} = Glob.compile(pattern)
    Regex.match?(glob, path)
  end

  test "a pattern without a slash matches the file name in any folder" do
    assert matches?("*.md", "top.md")
    assert matches?("*.md", "Deep/er/note.md")
    assert matches?("*.MD", "Deep/note.md")
    refute matches?("*.md", "picture.png")
    refute matches?("note", "Deep/note.md")
  end

  test "a star stays inside one folder and a double star crosses folders" do
    assert matches?("Projects/*.md", "Projects/plan.md")
    refute matches?("Projects/*.md", "Projects/Deep/plan.md")
    assert matches?("Projects/**/*.md", "Projects/plan.md")
    assert matches?("Projects/**/*.md", "Projects/Deep/er/plan.md")
    assert matches?("Projects/**", "Projects/Deep/pic.png")
    refute matches?("Projects/**", "Other/Projects/x.md")
    assert matches?("**", "anything/at/all.md")
  end

  test "question marks, alternatives and literal punctuation" do
    assert matches?("day-?.md", "day-1.md")
    refute matches?("day-?.md", "day-10.md")
    assert matches?("**/{todo,tasks}.md", "Work/tasks.md")
    refute matches?("**/{todo,tasks}.md", "Work/ideas.md")
    assert matches?("a+b (1).md", "a+b (1).md")
    refute matches?("a.md", "abmd")
  end

  test "malformed patterns are refused" do
    assert {:error, :invalid_pattern} = Glob.compile("")
    assert {:error, :invalid_pattern} = Glob.compile("{a,b")
  end
end
