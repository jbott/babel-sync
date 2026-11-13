defmodule BabelSyncWeb.VaultLive.BaseView do
  @moduledoc """
  Runs a base and shapes what it found for the page: a table whose
  cells are text, dates and links, or the places of a map view as the
  JSON its hook reads.
  """

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Bases, Markdown}
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths

  @base_rows 500

  @spec run(Scope.t(), Ecto.UUID.t(), Entry.t(), String.t(), String.t() | nil, [Entry.t()]) ::
          {:ok, map()} | {:error, String.t()}
  def run(scope, vault_id, entry, text, wanted, entries) do
    with {:ok, definition} <- Bases.Definition.parse(text),
         names = Enum.map(definition.views, & &1.name),
         view = if(wanted in names, do: wanted, else: List.first(names)),
         map? = Enum.any?(definition.views, &(&1.name == view and &1.type == "map")),
         {:ok, result} <-
           Agent.query_notes(scope, vault_id,
             base: entry.path,
             view: view,
             limit: @base_rows,
             as: if(map?, do: :map, else: :table)
           ) do
      shown =
        case result do
          %{markers: _} -> %{places: placed(result, definition.names, entries), table: nil}
          %{rows: _} -> %{places: nil, table: based(result, definition.names, entries)}
        end

      {:ok, Map.merge(%{entry_id: entry.id, views: names, view: view}, shown)}
    else
      failed -> {:error, problem(failed)}
    end
  end

  defp placed(places, names, entries) do
    paths = Map.new(entries, &{&1.path, &1})
    resolve = Markdown.resolver(entries)
    file_name = Enum.find_index(places.columns, &(&1 == "file.name"))

    Jason.encode!(%{
      columns: Enum.map(places.columns, &display_name(&1, names)),
      center: places.center && Tuple.to_list(places.center),
      zoom: places.zoom,
      minZoom: places.min_zoom,
      maxZoom: places.max_zoom,
      markers:
        for place <- places.markers do
          entry = paths[place.path]

          %{
            latitude: place.latitude,
            longitude: place.longitude,
            color: place.color,
            title: Path.rootname(Path.basename(place.path)),
            href: entry && Paths.entry(entry),
            fields:
              place.fields
              |> Enum.with_index()
              |> Enum.map(fn
                {value, ^file_name} when is_binary(value) ->
                  [%{kind: "text", text: Path.rootname(value)}]

                {value, _at} when value in [nil, ""] ->
                  nil

                {value, _at} ->
                  Enum.map(linked(value, resolve), &piece/1)
              end)
          }
        end
    })
  end

  defp piece({:note, href, label}), do: %{kind: "note", href: href, text: label}
  defp piece({:web, href, label}), do: %{kind: "web", href: href, text: label}
  defp piece({:text, text}), do: %{kind: "text", text: text}

  defp display_name(column, names) do
    column = String.replace_prefix(column, "note.", "")
    Map.get(names, column, column)
  end

  defp based(table, names, entries) do
    paths = Map.new(entries, &{&1.path, &1})
    resolve = Markdown.resolver(entries)

    shown =
      table.columns
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.reject(fn {column, _at} -> column == "file.name" end)

    %{
      columns: Enum.map(shown, fn {column, _at} -> display_name(column, names) end),
      rows:
        table.rows
        |> Enum.zip(table.groups || List.duplicate(nil, length(table.rows)))
        |> Enum.map_reduce(:none, fn {[path | _cells] = row, group}, previous ->
          cells = Enum.map(shown, &linked(Enum.at(row, elem(&1, 1)), resolve))
          heading = if table.groups && group != previous, do: blank(group)

          {%{path: path, entry: paths[path], cells: cells, heading: heading}, group}
        end)
        |> elem(0),
      total: table.total
    }
  end

  @timestamp ~r/^(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z$/
  @cell_link ~r/\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]|\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/[^\s,)]+)/

  defp blank(""), do: "None"
  defp blank(label), do: label

  defp linked(cell, resolve) do
    case Regex.run(@timestamp, cell) do
      [^cell, date] -> [{:text, Calendar.strftime(Date.from_iso8601!(date), "%-d %b %Y")}]
      nil -> links_in(cell, resolve)
    end
  end

  defp links_in(cell, resolve) do
    @cell_link
    |> Regex.split(cell, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(@cell_link, part) do
        [^part, target | rest] when target != "" ->
          note_link(target, Enum.at(rest, 0, ""), resolve)

        [^part, "", "", label, url] ->
          {:web, url, label}

        [^part, "", "", "", "", url] ->
          {:web, url, url}

        _plain ->
          {:text, part}
      end
    end)
  end

  defp note_link(target, shown, resolve) do
    label = if shown == "", do: target, else: shown

    case resolve.(target) do
      %Entry{} = entry -> {:note, Paths.entry(entry), label}
      nil -> {:text, label}
    end
  end

  defp problem({:error, {:invalid_query, message}}), do: message
  defp problem({:error, message}) when is_binary(message), do: message
  defp problem(_other), do: "its views could not be read."
end
