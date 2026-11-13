defmodule BabelSync.CanvasTest do
  use ExUnit.Case, async: true

  alias BabelSync.Canvas
  alias BabelSync.Vaults.Entry

  @entries [
    %Entry{id: "1", path: "Notes/Plan.md", kind: :doc},
    %Entry{id: "2", path: "Pictures/map.png", kind: :blob},
    %Entry{id: "3", path: "paper.pdf", kind: :blob}
  ]

  defp links do
    %{
      note: &("/n/" <> &1.path),
      raw: &("/raw/" <> &1.path),
      text: fn %Entry{id: "1"} -> "# Goals\n\nShip it\n\n# Later\n\nmore" end
    }
  end

  defp draw(canvas) do
    {:ok, html} = canvas |> Jason.encode!() |> Canvas.to_html(@entries, links())
    LazyHTML.from_fragment(html)
  end

  defp node(id, type, x, y, extra \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "type" => type, "x" => x, "y" => y, "width" => 200, "height" => 100},
        extra
      )

  defp style(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute("style")

  test "cards sit where the canvas puts them, shifted so the board starts at its padding" do
    document =
      draw(%{
        "nodes" => [
          node("a", "text", -300, -50, %{"text" => "**one**"}),
          node("b", "text", 100, 250)
        ]
      })

    assert style(document, ".canvas-board") == ["width:696.0px;height:496.0px"]

    assert style(document, ".canvas-node") == [
             "left:48.0px;top:48.0px;width:200.0px;height:100.0px",
             "left:448.0px;top:348.0px;width:200.0px;height:100.0px"
           ]

    assert document |> LazyHTML.query(".canvas-node strong") |> LazyHTML.text() == "one"
  end

  test "edges join the sides they name, or the sides facing each other, with arrowheads" do
    document =
      draw(%{
        "nodes" => [node("a", "text", 0, 0), node("b", "text", 400, 0)],
        "edges" => [
          %{"id" => "e1", "fromNode" => "a", "toNode" => "b", "label" => "next <step>"},
          %{
            "id" => "e2",
            "fromNode" => "a",
            "fromSide" => "bottom",
            "toNode" => "b",
            "toSide" => "bottom",
            "fromEnd" => "arrow",
            "toEnd" => "none"
          },
          %{"id" => "e3", "fromNode" => "a", "toNode" => "missing"}
        ]
      })

    [first, second] = document |> LazyHTML.query(".canvas-edge") |> Enum.to_list()
    assert [path, _arrow] = first |> LazyHTML.query("path") |> LazyHTML.attribute("d")
    assert path =~ ~r/^M248.0 98.0 C/
    assert path =~ ~r/448.0 98.0$/
    assert second |> LazyHTML.query("path.canvas-arrow") |> Enum.count() == 1

    assert second |> LazyHTML.query("path") |> LazyHTML.attribute("d") |> hd() =~
             ~r/^M148.0 148.0/

    assert document |> LazyHTML.query(".canvas-edge-label") |> LazyHTML.text() == "next <step>"
  end

  test "files show as their note, section, picture or PDF, and groups carry labels" do
    document =
      draw(%{
        "nodes" => [
          node("n", "file", 0, 0, %{"file" => "Notes/Plan.md", "subpath" => "#Later"}),
          node("p", "file", 0, 200, %{"file" => "Pictures/map.png"}),
          node("d", "file", 0, 400, %{"file" => "paper.pdf"}),
          node("x", "file", 0, 600, %{"file" => "Nowhere.md"}),
          node("l", "link", 300, 0, %{"url" => "https://example.com"}),
          node("j", "link", 300, 200, %{"url" => "javascript:alert(1)"}),
          node("g", "group", -20, -20, %{"label" => "Ideas", "color" => "4"})
        ]
      })

    assert document |> LazyHTML.query(".canvas-file-title") |> LazyHTML.attribute("href") == [
             "/n/Notes/Plan.md"
           ]

    assert document |> LazyHTML.query(".canvas-file h1") |> LazyHTML.text() == "Later"

    assert document |> LazyHTML.query(".canvas-file img") |> LazyHTML.attribute("src") == [
             "/raw/Pictures/map.png"
           ]

    assert document |> LazyHTML.query("iframe.embed-pdf") |> LazyHTML.attribute("src") == [
             "/raw/paper.pdf"
           ]

    assert document |> LazyHTML.query(".unresolved") |> LazyHTML.text() == "Nowhere.md"

    assert document |> LazyHTML.query(".canvas-link") |> LazyHTML.attribute("href") == [
             "https://example.com"
           ]

    refute document |> LazyHTML.to_html() =~ "href=\"javascript"
    assert document |> LazyHTML.query(".canvas-group-label") |> LazyHTML.text() == "Ideas"
    assert style(document, ".canvas-group") |> hd() =~ "--canvas-color:var(--canvas-4)"
  end

  test "nothing in the file can style or script the page" do
    document =
      draw(%{
        "nodes" => [
          node("a", "text", 0, 0, %{
            "text" => "<script>x()</script>",
            "color" => "red;position:fixed"
          }),
          node("b", "group", 0, 0, %{"label" => "<img src=x onerror=y>", "color" => "#FF0000"}),
          %{
            "id" => "c",
            "type" => "text",
            "x" => "0;position:fixed",
            "y" => 0,
            "width" => 1,
            "height" => 1
          }
        ]
      })

    html = LazyHTML.to_html(document)
    refute html =~ "<script"
    refute html =~ "position:fixed"
    refute html =~ "<img"
    assert style(document, ".canvas-group") |> hd() =~ "--canvas-color:#ff0000"
    assert document |> LazyHTML.query(".canvas-node") |> Enum.count() == 1
  end

  test "an empty canvas says so and one that is not JSON is refused" do
    assert {:ok, html} = Canvas.to_html("", @entries, links())
    assert html =~ "empty"
    assert {:ok, html} = Canvas.to_html(~s({"nodes":[]}), @entries, links())
    assert html =~ "empty"
    assert Canvas.to_html("{nope", @entries, links()) == :error
  end
end
