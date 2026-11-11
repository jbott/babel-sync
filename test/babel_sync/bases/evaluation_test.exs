defmodule BabelSync.Bases.EvaluationTest do
  use ExUnit.Case, async: true

  alias BabelSync.Bases.{Evaluation, Expression, Note}

  @now ~U[2026-11-11 12:00:00Z]
  @note Note.new(
          path: "Places/Coffee/Blue Bottle.md",
          size: 120,
          created: ~U[2026-01-05 09:00:00Z],
          modified: ~U[2026-11-10 09:00:00Z],
          text: """
          ---
          rating: 4.5
          visits: 3
          address: "1 Ferry Building, San Francisco"
          coordinates:
            - 37.7955
            - -122.3937
          tags: [coffee, sf/embarcadero]
          created_at: "2021-05-29T21:39:13.031123000Z"
          closed: false
          notes:
          ---
          Next to [[Ferry Building]] and good for #pastry too.
          """
        )

  defp value(source, formulas \\ %{}) do
    {:ok, tree} = Expression.parse(source)

    formulas =
      Map.new(formulas, fn {name, formula} -> {name, elem(Expression.parse(formula), 1)} end)

    {:ok, value} = Evaluation.run(tree, %{note: @note, formulas: formulas, now: @now})
    value
  end

  test "properties are read by bare name, through note., and by index" do
    assert value("rating") == 4.5
    assert value("note.visits") == 3
    assert value(~s|note["address"]|) =~ "Ferry"
    assert value("coordinates[0]") == 37.7955
    assert value("missing") == nil
  end

  test "the file's own fields" do
    assert value("file.name") == "Blue Bottle.md"
    assert value("file.basename") == "Blue Bottle"
    assert value("file.folder") == "Places/Coffee"
    assert value("file.ext") == "md"
    assert value("file.size") == 120
    assert value("file.tags") == ["coffee", "sf/embarcadero", "pastry"]
    assert value("file.links") == ["Ferry Building"]
  end

  test "comparison, arithmetic and logic follow the usual precedence" do
    assert value("rating >= 4 && visits < 5")
    assert value("rating > 4.5 || visits == 3")
    refute value("!(rating > 4)")
    assert value("1 + 2 * 3 == 7")
    assert value("(1 + 2) * 3 == 9")
    assert value("-visits + 10") == 7
    assert value("visits % 2") == 1
    assert value(~s|"a" + 1|) == "a1"
  end

  test "a comparison on a property the note lacks is simply false" do
    refute value("missing > 3")
    refute value("missing == 3")
    assert value("missing != 3")
    refute value(~s|missing.contains("x")|)
    assert value("missing.isEmpty()")
    assert value("notes.isEmpty()")
  end

  test "file methods" do
    assert value(~s|file.inFolder("Places")|)
    assert value(~s|file.inFolder("places/coffee/")|)
    refute value(~s|file.inFolder("Place")|)
    assert value(~s|file.hasTag("sf")|)
    assert value(~s|file.hasTag("#pastry", "nothing")|)
    refute value(~s|file.hasTag("embarcadero")|)
    assert value(~s|file.hasLink("Ferry Building")|)
    assert value(~s|file.hasLink("[[Ferry Building]]")|)
    assert value(~s|file.hasProperty("notes")|)
    refute value(~s|file.hasProperty("missing")|)
  end

  test "text and list methods" do
    assert value(~s|address.contains("san francisco")|)
    assert value(~s|address.startsWith("1 Ferry")|)
    assert value(~s|address.lower().endsWith("francisco")|)
    assert value(~s|tags.contains("Coffee")|)
    assert value(~s|tags.containsAny("tea", "coffee")|)
    refute value(~s|tags.containsAll("tea", "coffee")|)
    assert value("tags.length") == 2
    assert value(~s|tags.join(" + ")|) == "coffee + sf/embarcadero"
    assert value(~s|address.split(", ")[1]|) == "San Francisco"
    assert value("rating.round()") == 5
    assert value("rating.toFixed(2)") == "4.50"
  end

  test "dates compare with each other and with text, and move by durations" do
    assert value(~s|date(created_at) > date("2021-01-01")|)
    assert value(~s|date(created_at) < "2022-01-01"|)
    assert value("date(created_at).year") == 2021
    assert value(~s|file.mtime > now() - "7d"|)
    refute value(~s|file.ctime > now() - "2 months"|)
    assert value(~s|today() == date("2026-11-11")|)
    assert value(~s|date("2026-11-11 08:30") < now()|)
  end

  test "functions" do
    assert value(~s|if(rating > 4, "great", "fine")|) == "great"
    assert value(~s|if(closed, "shut")|) == nil
    assert value(~s|number("12")|) == 12
    assert value("max(rating, visits, 2)") == 4.5
    assert value(~s|link("https://example.com", "Site")|) == "[Site](https://example.com)"
    assert value(~s|link(file.path)|) == "[[Places/Coffee/Blue Bottle.md]]"
    assert_in_delta value("distance(coordinates, [37.8044, -122.2712])"), 10.8, 0.2
  end

  test "formulas can use properties and each other" do
    formulas = %{
      "score" => "rating * visits",
      "label" => ~s|if(formula.score > 10, "regular", "new")|
    }

    assert value("formula.score", formulas) == 13.5
    assert value("formula.label", formulas) == "regular"
  end

  test "what cannot be worked out is reported, not guessed" do
    {:ok, unknown} = Expression.parse("frobnicate(rating)")

    assert {:error, "there is no function frobnicate()" <> _} =
             Evaluation.run(unknown, %{note: @note})

    {:ok, method} = Expression.parse("rating.frobnicate()")
    assert {:error, "there is no method frobnicate()"} = Evaluation.run(method, %{note: @note})

    {:ok, formula} = Expression.parse("formula.nothing")
    assert {:error, "there is no formula named nothing"} = Evaluation.run(formula, %{note: @note})

    {:ok, loop} = Expression.parse("formula.a")

    assert {:error, "formula a refers to itself"} =
             Evaluation.run(loop, %{note: @note, formulas: %{"a" => loop}})

    assert {:error, _} = Expression.parse("rating >")
    assert {:error, _} = Expression.parse(~s|file.inFolder("Places"|)
    assert {:error, _} = Expression.parse(~s|name == "open|)
    assert {:error, _} = Expression.parse("rating ? 1")
  end
end
