defmodule BabelSync.Bases do
  @moduledoc """
  Queries over notes by their properties, the way Obsidian Bases treat a
  vault as a table: one row per note, one column per property.

  A query may start from a `.base` file's own filters and views, narrow
  further with an expression, keep only notes within a distance of a
  point, and choose the columns, the order and how many rows come back.
  """

  alias BabelSync.Bases.{Definition, Evaluation, Expression, Geo, Note}

  @default_limit 50
  @most 500
  @default_columns 12
  @cell_width 160
  @examples 3

  @type table :: %{
          columns: [String.t()],
          rows: [[String.t()]],
          groups: [String.t()] | nil,
          total: non_neg_integer()
        }

  @type groups :: %{
          group: String.t(),
          counts: [{String.t(), pos_integer()}],
          total: non_neg_integer()
        }

  @type option ::
          {:definition, Definition.t()}
          | {:view, String.t()}
          | {:folder, String.t()}
          | {:where, String.t()}
          | {:near, Geo.point()}
          | {:radius_km, number()}
          | {:coordinates, String.t()}
          | {:sort, String.t()}
          | {:select, [String.t()]}
          | {:group_by, String.t()}
          | {:limit, pos_integer()}
          | {:now, DateTime.t()}

  @spec query([Note.t()], [option()]) :: {:ok, table() | groups()} | {:error, String.t()}
  def query(notes, opts \\ []) do
    definition = opts[:definition] || %Definition{}

    with {:ok, view} <- view(definition, opts),
         {:ok, where} <- Definition.filter(opts[:where]),
         {:ok, sort} <- sort(opts[:sort], view, opts[:near]),
         {:ok, group} <- optional(opts[:group_by]),
         {:ok, sections} <- sections(view, group) do
      context = %{formulas: definition.formulas, now: opts[:now] || DateTime.utc_now()}
      filters = Enum.reject([definition.filter, view && view.filter, where], &is_nil/1)

      try do
        rows =
          notes
          |> Enum.filter(&Note.in_folder?(&1, opts[:folder] || ""))
          |> Enum.map(&%{note: &1, distance: distance(&1, opts)})
          |> Enum.filter(&(within?(&1, opts) and matches?(&1, filters, context)))

        if group,
          do: {:ok, grouped(rows, group, opts[:group_by], context)},
          else:
            {:ok, table(sorted(rows, sections ++ sort, context), view, opts, context, sections)}
      catch
        {:invalid, message} -> {:error, message}
      end
    end
  end

  @spec survey([Note.t()]) :: [
          %{name: String.t(), notes: pos_integer(), kinds: [String.t()], examples: [String.t()]}
        ]
  def survey(notes) do
    for(note <- notes, {name, value} <- note.properties, do: {name, value})
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, values} ->
      present = Enum.reject(values, &(&1 in [nil, "", []]))

      %{
        name: name,
        notes: length(values),
        kinds: present |> Enum.map(&kind/1) |> Enum.uniq() |> Enum.sort(),
        examples: present |> Enum.uniq() |> Enum.take(@examples) |> Enum.map(&cell/1)
      }
    end)
    |> Enum.sort_by(&{-&1.notes, &1.name})
  end

  defp view(definition, opts) do
    if opts[:definition], do: Definition.view(definition, opts[:view]), else: {:ok, nil}
  end

  defp sections(%{group_by: {property, direction}}, nil) do
    with {:ok, tree} <- column(property), do: {:ok, [{tree, direction}]}
  end

  defp sections(_view, _group), do: {:ok, []}

  defp optional(nil), do: {:ok, nil}
  defp optional(source), do: Expression.parse(source)

  defp sort(nil, _view, near) when near != nil, do: {:ok, [{:distance, :asc}]}
  defp sort(nil, %{sort: [_first | _rest] = sort}, _near), do: keys(sort)
  defp sort(nil, _view, _near), do: {:ok, []}

  defp sort(source, _view, _near) do
    source
    |> String.split(",", trim: true)
    |> Enum.map(fn key ->
      case Regex.run(~r/^(.*?)\s+(asc|desc)$/i, String.trim(key)) do
        [_all, property, direction] ->
          {property, String.to_existing_atom(String.downcase(direction))}

        nil ->
          {String.trim(key), :asc}
      end
    end)
    |> keys()
  end

  defp keys(sort) do
    Enum.reduce_while(sort, {:ok, []}, fn {property, direction}, {:ok, keys} ->
      case column(property) do
        {:ok, tree} -> {:cont, {:ok, keys ++ [{tree, direction}]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp column("distance_km"), do: {:ok, :distance}
  defp column(property), do: Expression.parse(property)

  defp distance(note, opts) do
    with {_latitude, _longitude} = centre <- opts[:near],
         {_latitude, _longitude} = here <- Geo.of(note.properties, opts[:coordinates]) do
      Geo.distance_km(centre, here)
    else
      _nowhere -> nil
    end
  end

  defp within?(%{distance: distance}, opts) do
    cond do
      opts[:near] == nil -> true
      distance == nil -> false
      is_number(opts[:radius_km]) -> distance <= opts[:radius_km]
      true -> true
    end
  end

  defp matches?(row, filters, context),
    do: Enum.all?(filters, &Evaluation.truthy?(evaluated(&1, row, context)))

  defp evaluated(:distance, row, _context), do: row.distance && Float.round(row.distance, 2)

  defp evaluated(tree, row, context) do
    case Evaluation.run(tree, Map.put(context, :note, row.note)) do
      {:ok, value} -> value
      {:error, message} -> throw({:invalid, message})
    end
  end

  defp sorted(rows, [], _context), do: Enum.sort_by(rows, & &1.note.path)

  defp sorted(rows, keys, context) do
    rows
    |> Enum.map(&{Enum.map(keys, fn {tree, _direction} -> evaluated(tree, &1, context) end), &1})
    |> Enum.sort(fn {left, one}, {right, other} ->
      before?(left, right, Enum.map(keys, &elem(&1, 1)), one.note.path <= other.note.path)
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp before?([], [], [], tie), do: tie

  defp before?([left | lefts], [right | rights], [direction | directions], tie) do
    {first, second} =
      if direction == :desc and nil not in [left, right], do: {right, left}, else: {left, right}

    cond do
      Evaluation.sorts_before?(first, second) -> true
      Evaluation.sorts_before?(second, first) -> false
      true -> before?(lefts, rights, directions, tie)
    end
  end

  defp grouped(rows, group, label, context) do
    counts =
      rows
      |> Enum.flat_map(fn row ->
        case evaluated(group, row, context) do
          values when is_list(values) and values != [] -> Enum.map(values, &cell/1)
          value -> [cell(value)]
        end
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {value, count} -> {-count, value} end)

    %{group: label, counts: counts, total: length(rows)}
  end

  defp table(rows, view, opts, context, sections) do
    limit = (opts[:limit] || (view && view.limit) || @default_limit) |> max(1) |> min(@most)
    shown = Enum.take(rows, limit)
    wanted = opts[:select] || (view && view.columns != [] && view.columns) || common(shown)
    distance = if opts[:near], do: ["distance_km"], else: []
    columns = Enum.uniq(["file.path"] ++ distance ++ wanted)

    trees =
      for name <- columns do
        case column(name) do
          {:ok, tree} -> tree
          {:error, message} -> throw({:invalid, message})
        end
      end

    %{
      columns: columns,
      rows: for(row <- shown, do: Enum.map(trees, &cell(evaluated(&1, row, context)))),
      groups: labels(sections, shown, context),
      total: length(rows)
    }
  end

  defp labels([{tree, _direction}], rows, context),
    do: for(row <- rows, do: cell(evaluated(tree, row, context)))

  defp labels([], _rows, _context), do: nil

  defp common(rows) do
    rows
    |> Enum.flat_map(&Map.keys(&1.note.properties))
    |> Enum.filter(&(&1 =~ ~r/^[\p{L}_][\p{L}\p{N}_]*$/u))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> Enum.take(@default_columns)
    |> Enum.map(&elem(&1, 0))
  end

  defp cell(value) do
    text = value |> Evaluation.shown() |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > @cell_width,
      do: String.slice(text, 0, @cell_width - 1) <> "…",
      else: text
  end

  defp kind(value) when is_boolean(value), do: "true/false"
  defp kind(value) when is_number(value), do: "number"
  defp kind(value) when is_list(value), do: "list"
  defp kind(%{}), do: "mapping"

  defp kind(value) when is_binary(value),
    do: if(value =~ ~r/^\d{4}-\d{2}-\d{2}/ and Evaluation.moment(value), do: "date", else: "text")

  defp kind(_other), do: "other"
end
