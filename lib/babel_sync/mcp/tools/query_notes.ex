defmodule BabelSync.MCP.Tools.QueryNotes do
  @moduledoc """
  Queries notes as a table of their properties, like an Obsidian base: one row per note, one column per property. Filters, sorts, counts, and finds notes near a place. Returns tab-separated rows whose first column is the path.

  where is an expression in the Bases language. A bare name is a property (rating, status); file.name, file.path, file.folder, file.ext, file.mtime, file.ctime, file.tags and file.size describe the file. Compare with == != < <= > >=, combine with && || !, and call methods: file.inFolder("Places/Coffee"), file.hasTag("book"), file.hasLink("Paris"), file.hasProperty("rating"), text.contains("x"), text.startsWith("x"), list.contains("x"), value.isEmpty(). Dates: date(created) > date("2024-01-01"), file.mtime > now() - "7d". Also if(a, b, c), number(x), min, max, and distance(coordinates, [48.85, 2.35]) in kilometres. A note without the property never matches a comparison on it.

  near keeps notes that have coordinates, adds a distance_km column and sorts nearest first; with radius_km it keeps only those inside the circle. Coordinates are read from a coordinates or location property holding [latitude, longitude] or "latitude, longitude", or from latitude/longitude properties.

  base runs a .base file: its filters and formulas (formula.name) apply, and its first view, or the one named by view, supplies the columns and order. where, near, sort, select and limit then narrow or override it.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :folder, :string, description: "Only notes inside this folder, for example Places"

    field :where, :string,
      description:
        ~s|Filter expression, for example rating >= 4 && file.inFolder("Places/Coffee")|

    field :near, :string,
      description:
        ~s|A point as "latitude, longitude", or the path of a note whose coordinates to use|

    field :radius_km, {:either, {:float, :integer}},
      description: "With near: keep only notes within this many kilometres."

    field :coordinates, :string,
      description: "With near: the property that holds each note's coordinates, if not the usual."

    field :base, :string,
      description: "Path of a .base file to run, for example Views/Places.base"

    field :view, :string,
      description: "With base: the name of the view to use. Defaults to the first."

    field :sort, :string,
      description:
        "Columns to order by, for example rating desc, file.name. Defaults to nearest first with near, else the view's order, else path."

    field :select, {:list, :string},
      description:
        "Columns to return, each a property or expression, for example rating, address, file.mtime. Defaults to the view's columns, else the most common properties."

    field :group_by, :string,
      description:
        "Count the matching notes by this property or expression instead of listing them, for example file.folder or status."

    field :limit, :integer, description: "Most rows to return. Defaults to 50, at most 500."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options =
        Enum.map(
          ~w(folder where near radius_km coordinates base view sort select group_by limit)a,
          &{&1, params[&1]}
        )

      with {:ok, result} <- Agent.query_notes(scope, params[:vault], options) do
        {:ok, Format.queried(result)}
      end
    end)
  end
end
