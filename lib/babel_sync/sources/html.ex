defmodule BabelSync.Sources.HTML do
  @moduledoc false

  @type element :: %{text: String.t(), html: String.t(), attributes: map()}

  @spec select(String.t(), String.t(), pos_integer()) :: {:ok, [element()]} | {:error, String.t()}
  def select(markup, selector, limit)
      when byte_size(markup) <= limit and byte_size(selector) in 1..1_000 do
    markup
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.reduce_while({:ok, [], 2}, fn node, {:ok, elements, size} ->
      element = %{
        text: LazyHTML.text(node),
        html: LazyHTML.to_html(node),
        attributes: node |> LazyHTML.attributes() |> List.first([]) |> Map.new()
      }

      size = size + byte_size(Jason.encode!(element)) + 1

      if size <= limit,
        do: {:cont, {:ok, [element | elements], size}},
        else: {:halt, {:error, "the selected HTML exceeds the response limit"}}
    end)
    |> case do
      {:ok, elements, _size} -> {:ok, Enum.reverse(elements)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, "HTML or CSS selector could not be read"}
  end

  def select(_markup, _selector, _limit),
    do: {:error, "HTML or CSS selector exceeds the input limit"}
end
