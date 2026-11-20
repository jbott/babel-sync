defmodule BabelSync.Sources.HTMLTest do
  use ExUnit.Case, async: true

  alias BabelSync.Sources.HTML

  test "selects decoded text, markup and attributes for a vault script" do
    markup = ~s|<div class="items"><a href="/item?id=1&amp;view=detail">Fruit &amp; veg</a></div>|

    assert {:ok, [%{text: "Fruit & veg", html: selected, attributes: attributes}]} =
             HTML.select(markup, ".items > a", 5_000)

    assert attributes == %{"href" => "/item?id=1&view=detail"}
    assert selected =~ "Fruit &amp; veg"
    assert {:ok, []} = HTML.select(markup, ".missing", 5_000)
    assert {:ok, [%{text: "Fruit & veg"}]} = HTML.select(selected, "a", 5_000)
  end

  test "bounds inputs and expanded results and reports malformed selectors" do
    assert {:error, _} = HTML.select("<p>hello</p>", "p", 5)
    assert {:error, _} = HTML.select("<p>hello</p>", "[", 5_000)
    assert {:error, _} = HTML.select("<p>hello</p>", "p", 25)
  end
end
