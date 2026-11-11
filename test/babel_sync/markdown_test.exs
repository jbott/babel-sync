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
    %Entry{id: "6", path: "Gone.md", kind: :doc, deleted_at: ~U[2026-01-01 00:00:00Z]}
  ]

  defp html(text) do
    Markdown.to_html(text, @entries, %{note: &("/n/" <> &1.path), raw: &("/raw/" <> &1.path)})
  end

  test "renders ordinary markdown" do
    assert html("# Title\n\n- [x] done\n\n~~old~~") =~ "<h1>Title</h1>"
    assert html("- [x] done") =~ ~s(type="checkbox")
    assert html("~~old~~") =~ "<del>old</del>"
  end

  test "drops raw html and script urls" do
    rendered =
      html(
        "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1))"
      )

    refute rendered =~ "<script"
    refute rendered =~ "onerror"
    refute rendered =~ "javascript:"
  end

  test "wikilinks resolve by exact path, then by note name" do
    assert html("[[Projects/Plan]]") =~ ~s(href="/n/Projects/Plan.md")
    assert html("[[Plan]]") =~ ~s(href="/n/Plan.md")
    assert html("[[Unique Note]]") =~ ~s(href="/n/Deep/Folder/Unique%20Note.md")
    assert html("[[Plan|the plan]]") =~ ">the plan</a>"
    assert html("[[Plan#Goals]]") =~ ~s(href="/n/Plan.md#Goals")
  end

  test "embeds become images or links to the attachment" do
    assert html("![[diagram.png]]") =~ ~s(<img src="/raw/Attachments/diagram.png")
    assert html("![[paper.pdf]]") =~ ~s(href="/raw/Attachments/paper.pdf")
    assert html("[[diagram.png]]") =~ ~s(href="/raw/Attachments/diagram.png")
  end

  test "links to missing or deleted notes are not links" do
    refute html("[[Nowhere]]") =~ "<a"
    refute html("[[Gone]]") =~ "<a"
    assert html("[[Nowhere]]") =~ "Nowhere"
  end

  test "wikilinks inside code are left alone and frontmatter is hidden" do
    assert html("`[[Plan]]`") =~ "<code>[[Plan]]</code>"
    refute html("---\ntags: [a]\n---\n# Body") =~ "tags"
    assert html("---\ntags: [a]\n---\n# Body") =~ "<h1>Body</h1>"
  end
end
