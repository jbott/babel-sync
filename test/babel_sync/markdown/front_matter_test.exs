defmodule BabelSync.Markdown.FrontMatterTest do
  use ExUnit.Case, async: true

  alias BabelSync.Markdown.FrontMatter

  @note """
  ---
  tags:
    - type/github-star
    - mine
  # how many
  stars: 10
  description: "An engine: fast"
  url: https://github.com/a/b
  ---
  # b

  Body.
  """

  test "replaces one property and leaves every other line alone" do
    assert {:ok, text} = FrontMatter.set(@note, [{"stars", 11}])
    assert text == String.replace(@note, "stars: 10", "stars: 11")
  end

  test "gives back the same text when nothing would change" do
    same = [
      {"stars", 10},
      {"description", "An engine: fast"},
      {"tags", ["type/github-star", "mine"]}
    ]

    assert {:ok, @note} = FrontMatter.set(@note, same)
  end

  test "adds a property that is not there after the others" do
    assert {:ok, text} = FrontMatter.set(@note, [{"language", "C++"}])
    assert text =~ "url: https://github.com/a/b\nlanguage: C++\n---\n# b"
  end

  test "removes a property set to nothing" do
    assert {:ok, text} = FrontMatter.set(@note, [{"description", nil}])
    refute text =~ "description"
    assert text =~ "stars: 10\nurl:"
  end

  test "leaves alone a property set to nothing that was never there" do
    assert {:ok, @note} = FrontMatter.set(@note, [{"language", nil}])
  end

  test "gives a note without front matter one" do
    assert {:ok, "---\nstars: 3\n---\n# b\n"} = FrontMatter.set("# b\n", [{"stars", 3}])
  end

  test "quotes text that YAML would read as something else" do
    values = [
      "true",
      "12",
      "a: b",
      "- x",
      "#tag",
      "",
      " padded ",
      "say \"hi\"",
      "two\nlines",
      "[[link]]"
    ]

    for value <- values do
      assert {:ok, text} = FrontMatter.set("", [{"key", value}])
      assert {:ok, %{"key" => ^value}} = FrontMatter.read(text)
    end
  end

  test "writes dates and web addresses unquoted" do
    assert {:ok, text} =
             FrontMatter.set("", [{"created", "2026-06-23"}, {"url", "https://example.com/a?b=c"}])

    assert text == "---\ncreated: 2026-06-23\nurl: https://example.com/a?b=c\n---\n"
  end

  test "a list keeps what a person added and drops only what was written before" do
    written = %{"tags" => ["type/github-star", "github/topic/old"]}

    note = """
    ---
    tags:
      - type/github-star
      - github/topic/old
      - mine
    ---
    """

    assert {:ok, text} =
             FrontMatter.merge(
               note,
               [{"tags", ["type/github-star", "github/topic/new"]}],
               written
             )

    assert {:ok, %{"tags" => ["type/github-star", "github/topic/new", "mine"]}} =
             FrontMatter.read(text)
  end

  test "a plain value replaces what a person wrote over it" do
    assert {:ok, text} = FrontMatter.merge(@note, [{"stars", 12}], %{"stars" => 9})
    assert text =~ "stars: 12"
  end

  test "set replaces a value outright, whatever was there" do
    assert {:ok, text} = FrontMatter.set("---\nkind: note\n---\n", [{"kind", ["a", "b"]}])
    assert FrontMatter.read(text) == {:ok, %{"kind" => ["a", "b"]}}

    assert {:ok, text} = FrontMatter.set(text, [{"kind", ["c"]}])
    assert FrontMatter.read(text) == {:ok, %{"kind" => ["c"]}}
  end

  test "refuses front matter it cannot read" do
    assert {:error, :invalid_front_matter} =
             FrontMatter.set("---\nkey: [unclosed\n---\nbody", [{"stars", 1}])
  end

  test "front matter that never closes is body" do
    assert {:ok, "---\nstars: 1\n---\n---\nnot closed"} =
             FrontMatter.set("---\nnot closed", [{"stars", 1}])
  end
end
