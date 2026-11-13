defmodule BabelSync.Bases.Definition do
  @moduledoc """
  What a `.base` file says: which notes belong to the base, the formulas
  it defines, and its views with their own filters, columns and order.
  """

  alias BabelSync.Bases.Expression

  defstruct filter: nil, formulas: %{}, views: [], names: %{}

  @type view :: %{
          name: String.t(),
          filter: Expression.t() | nil,
          columns: [String.t()],
          sort: [{String.t(), :asc | :desc}],
          limit: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          filter: Expression.t() | nil,
          formulas: %{optional(String.t()) => Expression.t()},
          views: [view()],
          names: %{optional(String.t()) => String.t()}
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) do
    with {:ok, %{} = yaml} <- read(text),
         {:ok, filter} <- filter(yaml["filters"]),
         {:ok, views} <- views(yaml["views"]) do
      {:ok,
       %__MODULE__{
         filter: filter,
         formulas: formulas(yaml["formulas"]),
         views: views,
         names: display_names(yaml["properties"])
       }}
    else
      {:ok, _not_a_map} -> {:error, "the base file is not a YAML mapping"}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec view(t(), String.t() | nil) :: {:ok, view() | nil} | {:error, String.t()}
  def view(%__MODULE__{views: views}, nil), do: {:ok, List.first(views)}

  def view(%__MODULE__{views: views}, name) do
    case Enum.find(views, &(String.downcase(&1.name) == String.downcase(name))) do
      nil -> {:error, "the base has no view named #{name}; it has #{names(views)}"}
      view -> {:ok, view}
    end
  end

  @spec filter(term()) :: {:ok, Expression.t() | nil} | {:error, String.t()}
  def filter(nil), do: {:ok, nil}
  def filter(source) when is_binary(source), do: Expression.parse(source)
  def filter(%{"and" => parts}) when is_list(parts), do: joined(parts, :and)
  def filter(%{"or" => parts}) when is_list(parts), do: joined(parts, :or)

  def filter(%{"not" => parts}) when is_list(parts) do
    with {:ok, any} <- joined(parts, :or), do: {:ok, any && {:unary, :not, any}}
  end

  def filter(_other), do: {:error, "a filter must be an expression or an and/or/not list"}

  defp read(""), do: {:ok, %{}}

  defp read(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, _reason} -> {:error, "the base file is not valid YAML"}
    end
  end

  defp joined(parts, operator) do
    Enum.reduce_while(parts, {:ok, nil}, fn part, {:ok, joined} ->
      case filter(part) do
        {:ok, nil} -> {:cont, {:ok, joined}}
        {:ok, tree} when joined == nil -> {:cont, {:ok, tree}}
        {:ok, tree} -> {:cont, {:ok, {:binary, operator, joined, tree}}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp formulas(%{} = formulas) do
    for {name, source} <- formulas,
        {:ok, tree} <- [Expression.parse(to_string(source))],
        into: %{},
        do: {to_string(name), tree}
  end

  defp formulas(_none), do: %{}

  defp display_names(%{} = properties) do
    for {property, %{"displayName" => name}} <- properties,
        is_binary(name) and name != "",
        into: %{},
        do: {property |> to_string() |> String.replace_prefix("note.", ""), name}
  end

  defp display_names(_none), do: %{}

  defp views(views) when is_list(views) do
    views
    |> Enum.filter(&is_map/1)
    |> Enum.reduce_while({:ok, []}, fn view, {:ok, parsed} ->
      case filter(view["filters"]) do
        {:ok, filter} -> {:cont, {:ok, parsed ++ [described(view, filter, length(parsed) + 1)]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp views(_none), do: {:ok, []}

  defp described(view, filter, position) do
    %{
      name: to_string(view["name"] || "View #{position}"),
      filter: filter,
      columns: for(column <- List.wrap(view["order"]), is_binary(column), do: column),
      sort:
        for %{"property" => property} = sort <- List.wrap(view["sort"]), is_binary(property) do
          {property, direction(sort["direction"])}
        end,
      limit: if(is_integer(view["limit"]) and view["limit"] > 0, do: view["limit"])
    }
  end

  defp direction(direction) when is_binary(direction),
    do: if(String.downcase(direction) == "desc", do: :desc, else: :asc)

  defp direction(_other), do: :asc

  defp names(views), do: Enum.map_join(views, ", ", & &1.name)
end
