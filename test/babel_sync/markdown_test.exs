defmodule BabelSync.MarkdownTest do
  use ExUnit.Case, async: true

  alias BabelSync.Markdown
  alias BabelSync.Vaults.Entry

  @entries [
    %Entry{id: "1", path: "Projects/Plan.md", kind: :doc},
    %Entry{id: "2", path: "Plan.md", kind: :doc},
    %Entry{id: "3", path: "Attachments/diagram.png", kind: :blob},
    %Entry{id: "4", path: "Attachments/paper.pdf", kind: :blob},
    %Entry{id: "5", path: "Deep/Folder/Unique Note.md", kind: :doc},
    %Entry{id: "6", path: "Gone.md", kind: :doc, deleted_at: ~U[2026-01-01 00:00:00Z]},
    %Entry{id: "7", path: "song.mp3", kind: :blob},
    %Entry{id: "8", path: "Loop.md", kind: :doc}
  ]

  @texts %{
    "2" => "# Goals\n\nShip it ^ship\n\n## Later\n\nmore\n\n# Other\n\nelsewhere",
    "8" => "Loop ![[Loop]]"
  }

  defp html(text) do
    Markdown.to_html(text, @entries, %{
      note: &("/n/" <> &1.path),
      raw: &("/raw/" <> &1.path),
      text: &Map.fetch!(@texts, &1.id)
    })
  end

  defp find(text, selector),
    do: text |> html() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attribute(text, selector, name) do
    text |> find(selector) |> LazyHTML.attribute(name)
  end

  defp texts(text, selector),
    do: text |> find(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))

  test "renders ordinary markdown" do
    assert html("# Title\n\n- [x] done\n\n~~old~~") =~ "Title</h1>"
    assert attribute("- [x] done", "input", "type") == ["checkbox"]
    assert html("~~old~~") =~ "<del>old</del>"
  end

  test "keeps harmless html and removes scripts, handlers, styles and the page's classes" do
    rendered =
      html("""
      <script>alert(1)</script>

      <img src=x onerror=alert(1)>

      [x](javascript:alert(1))

      <u>kept</u> <span style="position:fixed" class="fixed inset-0">**bold**</span>
      """)

    refute rendered =~ "<script"
    refute rendered =~ "onerror"
    refute rendered =~ "javascript:"
    refute rendered =~ "position:fixed"
    refute rendered =~ "inset-0"
    assert rendered =~ "<u>kept</u>"
    assert rendered =~ "<strong>bold</strong>"
  end

  test "single line breaks stay line breaks" do
    assert html("line one\nline two") =~ "line one<br>"
  end

  test "highlights, comments and math" do
    assert texts("a ==marked== b", "mark") == ["marked"]
    refute html("visible %%hidden%% text") =~ "hidden"
    assert attribute("$x^2$", "span[data-math-style]", "data-math-style") == ["inline"]

    assert attribute("$$\nE = mc^2\n$$", "span[data-math-style]", "data-math-style") == [
             "display"
           ]
  end

  test "tags follow Obsidian's rules" do
    assert texts("#meeting #inbox/to-read #y1984 #日本語", ".tag") ==
             ["#meeting", "#inbox/to-read", "#y1984", "#日本語"]

    assert texts("#1984 abc#def", ".tag") == []
    assert texts("Ends at punctuation: #tag. And #bob's.", ".tag") == ["#tag", "#bob"]
    assert texts("#Bob#Alice is two.", ".tag") == ["#Bob", "#Alice"]
    assert texts("`#code` and [#linked](https://example.com)", ".tag") == []
  end

  test "callouts carry their type, title and fold state" do
    assert attribute("> [!info] Here's a title\n> Body.", "div.callout", "data-callout") == [
             "info"
           ]

    assert texts("> [!info] Here's a title\n> Body.", ".callout-title") == ["Here's a title"]
    assert texts("> [!WARNING]\n> Careful.", ".callout-title") == ["Warning"]
    assert find("> [!tip] Title only", ".callout-content") |> Enum.count() == 0

    assert find("> [!faq]- Folded?\n> Yes!", "details.callout:not([open]) > summary")
           |> Enum.count() == 1

    assert find("> [!faq]+ Open?\n> Yes!", "details.callout[open]") |> Enum.count() == 1
  end

  test "wikilinks resolve by exact path, then by note name" do
    assert attribute("[[Projects/Plan]]", "a", "href") == ["/n/Projects/Plan.md"]
    assert attribute("[[Plan]]", "a", "href") == ["/n/Plan.md"]
    assert attribute("[[Unique Note]]", "a", "href") == ["/n/Deep/Folder/Unique%20Note.md"]
    assert texts("[[Plan|the plan]]", "a") == ["the plan"]
  end

  test "links into a heading or block land on it" do
    assert attribute("[[Plan#Goals]]", "a", "href") == ["/n/Plan.md#md-h-goals"]
    assert attribute("[[Plan#^ship]]", "a", "href") == ["/n/Plan.md#md-block-ship"]
    assert attribute("[[#9 00 AM]]", "a", "href") == ["#md-h-9-00-am"]
    assert attribute("## 9:00 AM", "h2 span", "id") == ["md-h-9-00-am"]
    assert texts("[[Plan#Goals]] [[#Later]]", "a") == ["Plan › Goals", "Later"]
  end

  test "block identifiers become anchors and leave the text" do
    assert texts("The quick gem. ^37066d", "p") == ["The quick gem."]
    assert attribute("The quick gem. ^37066d", "p span", "id") == ["md-block-37066d"]
    assert attribute("Some text\n^abc", "p span", "id") == ["md-block-abc"]
    assert attribute("- one\n- two\n\n^list", "span", "id") == ["md-block-list"]
    assert find("not-a-marker^abc", "span[id]") |> Enum.count() == 0
  end

  test "embeds show images at a size, players, and notes in place" do
    assert attribute("![[diagram.png]]", "img", "src") == ["/raw/Attachments/diagram.png"]
    assert attribute("![[diagram.png|100x145]]", "img", "width") == ["100"]
    assert attribute("![[diagram.png|100x145]]", "img", "height") == ["145"]
    assert attribute("![[diagram.png|A chart]]", "img", "alt") == ["A chart"]
    assert attribute("![[song.mp3]]", "audio", "src") == ["/raw/song.mp3"]

    assert attribute("![[paper.pdf]]", "iframe.embed-pdf", "src") == [
             "/raw/Attachments/paper.pdf"
           ]

    assert attribute("[[paper.pdf]]", "a", "href") == ["/raw/Attachments/paper.pdf"]
    assert attribute("[[diagram.png]]", "a", "href") == ["/raw/Attachments/diagram.png"]

    assert texts("![[Plan#Goals]]", ".embed-content h2") == ["Later"]
    refute html("![[Plan#Goals]]") =~ "elsewhere"
    assert texts("![[Plan#^ship]]", ".embed-content p") == ["Ship it"]
  end

  test "embedded PDFs open at a page and height" do
    pdf = "![[paper.pdf#page=3&height=400]]"
    assert attribute(pdf, "iframe", "src") == ["/raw/Attachments/paper.pdf#page=3"]
    assert attribute(pdf, "iframe", "height") == ["400"]
    assert attribute("![[paper.pdf#page=x]]", "iframe", "src") == ["/raw/Attachments/paper.pdf"]
  end

  test "frames written into a note lose their scripts" do
    rendered =
      html(~s|<iframe src="https://example.com" srcdoc="<script>" onload="x()"></iframe>|)

    refute rendered =~ "srcdoc"
    refute rendered =~ "onload"
  end

  test "notes that embed themselves stop" do
    assert find("![[Loop]]", ".embed") |> Enum.count() == 1
  end

  test "markdown links and images reach files in the vault" do
    assert attribute("[Unique](Unique%20Note.md)", "a", "href") == [
             "/n/Deep/Folder/Unique%20Note.md"
           ]

    assert attribute("[Later](Plan.md#Later)", "a", "href") == ["/n/Plan.md#md-h-later"]
    assert attribute("![chart|250](Attachments/diagram.png)", "img", "width") == ["250"]
    assert attribute("![chart|250](Attachments/diagram.png)", "img", "alt") == ["chart"]

    assert attribute("[out](https://example.com/a.md)", "a", "href") == [
             "https://example.com/a.md"
           ]
  end

  test "links to missing or deleted notes are not links" do
    assert find("[[Nowhere]]", "a") |> Enum.count() == 0
    assert find("[[Gone]]", "a") |> Enum.count() == 0
    assert texts("[[Nowhere]]", ".unresolved") == ["Nowhere"]
  end

  test "properties show above the note and are not part of it" do
    text = "---\ntags: [a, b/c]\nstatus: draft\nrelated: \"[[Plan]]\"\ndone: true\n---\n# Body"

    assert texts(text, ".property dt") == ["done", "related", "status", "tags"]
    assert texts(text, ".property .tag") == ["#a", "#b/c"]
    assert attribute(text, ".property a", "href") == ["/n/Plan.md"]
    assert attribute(text, ".property input", "checked") == [""]
    assert texts(text, "h1") == ["Body"]
    assert find("---\n: not yaml [\n---\nbody", ".properties") |> Enum.count() == 0
  end

  test "code is left alone and mermaid diagrams are marked for drawing" do
    assert html("`[[Plan]]`") =~ "<code>[[Plan]]</code>"
    assert texts("```mermaid\ngraph TD; A-->B\n```", "pre.mermaid") == ["graph TD; A-->B"]
  end

  test "code blocks are highlighted with token classes the stylesheet colours" do
    code = "```elixir\ndef hi, do: \"hello\" # greet\n```"

    assert find(code, "pre.syntax-highlighting code") |> Enum.count() == 1
    assert texts(code, "span.keyword") |> Enum.member?("def")
    assert texts(code, "span.string") |> Enum.any?(&(&1 =~ "hello"))
    assert texts(code, "span.comment") |> Enum.any?(&(&1 =~ "greet"))
    assert html("```\nplain text\n```") =~ "plain text"
  end

  test "classes of the page's own layout never reach a note's code" do
    rendered =
      html(~s(<code class="fixed inset-0 language-x">x</code> <pre class="fixed">y</pre>))

    refute rendered =~ "fixed"
    refute rendered =~ "inset-0"
  end

  test "footnotes link within the page" do
    rendered = html("Note[^1].\n\n[^1]: The note.")
    assert rendered =~ ~s(href="#md-fn-1")
    assert rendered =~ ~s(id="md-fn-1")
  end
end
