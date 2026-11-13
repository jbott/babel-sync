defmodule BabelSync.BasesTest do
  use ExUnit.Case, async: true

  alias BabelSync.Bases
  alias BabelSync.Bases.{Definition, Geo, Note}

  @eiffel {48.8584, 2.2945}

  defp place(path, properties) do
    yaml =
      Enum.map_join(properties, "\n", fn {key, value} -> "#{key}: #{Jason.encode!(value)}" end)

    Note.new(
      path: path,
      created: ~U[2026-01-01 00:00:00Z],
      modified: ~U[2026-01-01 00:00:00Z],
      text: "---\n#{yaml}\n---\n"
    )
  end

  defp notes do
    [
      place("Places/Coffee/Café Kitsuné.md",
        coordinates: [48.8651, 2.3378],
        rating: 4,
        city: "Paris"
      ),
      place("Places/Coffee/Ten Belles.md",
        coordinates: "48.8722, 2.3636",
        rating: 5,
        city: "Paris"
      ),
      place("Places/Restaurants/Septime.md",
        latitude: 48.8536,
        longitude: 2.3808,
        rating: 5,
        city: "Paris"
      ),
      place("Places/Restaurants/Noma.md",
        coordinates: [55.6828, 12.6105],
        rating: 5,
        city: "Copenhagen"
      ),
      place("Places/Restaurants/Unplaced.md", rating: 2, city: "Paris"),
      %Note{path: "Places/map.png"},
      place("Journal/2026-01-01.md", mood: "good")
    ]
  end

  defp paths(%{rows: rows}), do: Enum.map(rows, &hd/1)

  @base """
  filters:
    and:
      - file.inFolder("Places")
      - file.ext == "md"
  formulas:
    kind: if(file.inFolder("Places/Coffee"), "Coffee", "Restaurant")
    stars: 'if(rating >= 5, "top", "ok")'
  views:
    - type: table
      name: All places
      order:
        - file.name
        - formula.kind
        - rating
      sort:
        - property: rating
          direction: DESC
        - property: file.name
          direction: ASC
    - type: table
      name: Coffee
      filters:
        and:
          - file.inFolder("Places/Coffee")
      order:
        - file.name
      limit: 1
  """

  test "a filter expression chooses the notes, in path order" do
    assert {:ok, found} = Bases.query(notes(), where: ~s|rating >= 5 && city == "Paris"|)
    assert paths(found) == ["Places/Coffee/Ten Belles.md", "Places/Restaurants/Septime.md"]
    assert found.total == 2
  end

  test "the folder, the columns, the order and the number of rows can each be set" do
    assert {:ok, found} =
             Bases.query(notes(),
               folder: "Places",
               where: "rating > 0",
               sort: "rating desc, file.name",
               select: ["rating", "file.basename"],
               limit: 3
             )

    assert found.columns == ["file.path", "rating", "file.basename"]
    assert found.total == 5

    assert found.rows == [
             ["Places/Restaurants/Noma.md", "5", "Noma"],
             ["Places/Restaurants/Septime.md", "5", "Septime"],
             ["Places/Coffee/Ten Belles.md", "5", "Ten Belles"]
           ]
  end

  test "without chosen columns the most common properties are shown" do
    assert {:ok, %{columns: columns}} = Bases.query(notes(), folder: "Places/Coffee")
    assert columns == ["file.path", "city", "coordinates", "rating"]
  end

  test "near keeps the notes that have coordinates, nearest first, with their distance" do
    assert {:ok, found} = Bases.query(notes(), near: @eiffel, select: ["city"])

    assert paths(found) == [
             "Places/Coffee/Café Kitsuné.md",
             "Places/Coffee/Ten Belles.md",
             "Places/Restaurants/Septime.md",
             "Places/Restaurants/Noma.md"
           ]

    assert found.columns == ["file.path", "distance_km", "city"]
    [[_path, nearest, "Paris"] | _rest] = found.rows
    assert_in_delta String.to_float(nearest), 3.25, 0.1
  end

  test "a radius leaves out what lies beyond it, and combines with a filter" do
    assert {:ok, found} = Bases.query(notes(), near: @eiffel, radius_km: 5.5)
    assert paths(found) == ["Places/Coffee/Café Kitsuné.md", "Places/Coffee/Ten Belles.md"]

    assert {:ok, top} = Bases.query(notes(), near: @eiffel, radius_km: 20, where: "rating == 5")
    assert paths(top) == ["Places/Coffee/Ten Belles.md", "Places/Restaurants/Septime.md"]
  end

  test "coordinates can live in a property of another name" do
    notes = [place("a.md", spot: [48.86, 2.33]), place("b.md", coordinates: [48.86, 2.33])]
    assert {:ok, found} = Bases.query(notes, near: @eiffel, coordinates: "spot")
    assert paths(found) == ["a.md"]
  end

  test "distances are great-circle kilometres" do
    assert_in_delta Geo.distance_km({48.8566, 2.3522}, {51.5074, -0.1278}), 343.5, 1.0
    assert Geo.distance_km(@eiffel, @eiffel) == 0.0
    assert Geo.point("91, 0") == nil
    assert Geo.point(%{"lat" => "48.1", "lng" => 2}) == {48.1, 2.0}
  end

  test "notes are counted by a property or an expression" do
    assert {:ok, counted} = Bases.query(notes(), folder: "Places", group_by: "city")
    assert counted.counts == [{"Paris", 4}, {"", 1}, {"Copenhagen", 1}]
    assert counted.total == 6

    assert {:ok, by_folder} =
             Bases.query(notes(), where: "file.hasProperty(\"rating\")", group_by: "file.folder")

    assert by_folder.counts == [{"Places/Restaurants", 3}, {"Places/Coffee", 2}]
  end

  test "a base file supplies its filters, formulas and first view" do
    {:ok, definition} = Definition.parse(@base)
    assert {:ok, found} = Bases.query(notes(), definition: definition)

    assert found.columns == ["file.path", "file.name", "formula.kind", "rating"]

    assert Enum.map(found.rows, &Enum.drop(&1, 1)) == [
             ["Noma.md", "Restaurant", "5"],
             ["Septime.md", "Restaurant", "5"],
             ["Ten Belles.md", "Coffee", "5"],
             ["Café Kitsuné.md", "Coffee", "4"],
             ["Unplaced.md", "Restaurant", "2"]
           ]
  end

  test "a named view adds its own filter and limit, and the query can narrow further" do
    {:ok, definition} = Definition.parse(@base)

    assert {:ok, coffee} = Bases.query(notes(), definition: definition, view: "coffee")
    assert paths(coffee) == ["Places/Coffee/Café Kitsuné.md"]
    assert coffee.total == 2

    assert {:ok, top} =
             Bases.query(notes(),
               definition: definition,
               where: ~s|formula.stars == "top"|,
               near: @eiffel,
               limit: 1
             )

    assert paths(top) == ["Places/Coffee/Ten Belles.md"]
    assert top.total == 3
  end

  test "mistakes in a query or a base are explained" do
    {:ok, definition} = Definition.parse(@base)

    assert {:error, "the base has no view named Bars; it has All places, Coffee"} =
             Bases.query(notes(), definition: definition, view: "Bars")

    assert {:error, "there is no function nearby()" <> _} =
             Bases.query(notes(), where: "nearby(1)")

    assert {:error, "there is no formula named kind"} =
             Bases.query(notes(), where: "formula.kind")

    assert {:error, _} = Bases.query(notes(), sort: "rating >")
    assert {:error, _} = Definition.parse("filters:\n  and:\n    - 'rating >'\n")
    assert {:error, "the base file is not valid YAML"} = Definition.parse("filters: [")
  end

  test "a survey tells which properties exist, how often, and what they hold" do
    assert [%{name: "city", notes: 5, kinds: ["text"], examples: ["Paris", "Copenhagen"]} | rest] =
             Bases.survey(notes())

    assert %{notes: 5, kinds: ["number"]} = Enum.find(rest, &(&1.name == "rating"))
    assert %{kinds: ["list", "text"]} = Enum.find(rest, &(&1.name == "coordinates"))
  end

  test "front matter is read once and read again only when it changes" do
    calls = :counters.new(1, [])
    block = "rating: 4\nseen: #{System.unique_integer()}\n"
    parse = fn text -> :counters.add(calls, 1, 1) && %{"text" => text} end

    assert BabelSync.Bases.PropertyCache.fetch(block, parse) == %{"text" => block}
    assert BabelSync.Bases.PropertyCache.fetch(block, parse) == %{"text" => block}
    assert :counters.get(calls, 1) == 1

    assert %{"rating" => 5} = Note.properties("---\nrating: 5\n---\nbody")
  end

  test "a base's display names label its columns" do
    {:ok, definition} =
      Definition.parse("""
      properties:
        note.rating:
          displayName: Stars
        formula.kind:
          displayName: Kind
        file.name: {}
      """)

    assert definition.names == %{"rating" => "Stars", "formula.kind" => "Kind"}
  end
end
