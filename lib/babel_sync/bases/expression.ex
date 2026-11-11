defmodule BabelSync.Bases.Expression do
  @moduledoc """
  Parses the expression language Obsidian Bases use for filters and
  formulas, such as `rating >= 4 && file.inFolder("Places/Coffee")`, into
  a tree that `BabelSync.Bases.Evaluation` can work out against a note.
  """

  @type t ::
          {:literal, term()}
          | {:name, String.t()}
          | {:member, t(), String.t()}
          | {:index, t(), t()}
          | {:call, t(), [t()]}
          | {:list, [t()]}
          | {:unary, :not | :negate, t()}
          | {:binary, atom(), t(), t()}

  @operators [
    {"==", :==},
    {"!=", :!=},
    {"<=", :<=},
    {">=", :>=},
    {"&&", :and},
    {"||", :or},
    {"<", :<},
    {">", :>},
    {"+", :+},
    {"-", :-},
    {"*", :*},
    {"/", :/},
    {"%", :%},
    {"!", :!},
    {"(", :"("},
    {")", :")"},
    {"[", :"["},
    {"]", :"]"},
    {",", :","},
    {".", :.}
  ]

  @levels [[:or], [:and], [:==, :!=, :<, :<=, :>, :>=], [:+, :-], [:*, :/, :%]]

  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- tokens(source, []) do
      case expression(tokens, @levels) do
        {:ok, tree, []} -> {:ok, tree}
        {:ok, _tree, [token | _rest]} -> {:error, "unexpected #{shown(token)} in #{source}"}
        {:error, message} -> {:error, "#{message} in #{source}"}
      end
    end
  end

  defp tokens("", found), do: {:ok, Enum.reverse(found)}

  defp tokens(<<space, rest::binary>>, found) when space in ~c" \t\r\n",
    do: tokens(rest, found)

  defp tokens(<<quote, rest::binary>>, found) when quote in ~c("') do
    with {:ok, text, rest} <- quoted(rest, quote, []) do
      tokens(rest, [{:string, text} | found])
    end
  end

  defp tokens(<<digit, _rest::binary>> = source, found) when digit in ?0..?9 do
    [digits] = Regex.run(~r/^\d+(?:\.\d+)?/, source)
    rest = binary_part(source, byte_size(digits), byte_size(source) - byte_size(digits))

    number =
      if String.contains?(digits, "."),
        do: String.to_float(digits),
        else: String.to_integer(digits)

    tokens(rest, [{:number, number} | found])
  end

  defp tokens(source, found) do
    case Regex.run(~r/^[\p{L}_][\p{L}\p{N}_]*/u, source) do
      [word] ->
        rest = binary_part(source, byte_size(word), byte_size(source) - byte_size(word))
        tokens(rest, [{:word, word} | found])

      nil ->
        case Enum.find(@operators, fn {text, _name} -> String.starts_with?(source, text) end) do
          {text, name} ->
            rest = binary_part(source, byte_size(text), byte_size(source) - byte_size(text))
            tokens(rest, [name | found])

          nil ->
            {:error, "unexpected #{String.first(source)} in #{source}"}
        end
    end
  end

  defp quoted("", _quote, _text), do: {:error, "a quoted text is never closed"}

  defp quoted(<<?\\, escaped::utf8, rest::binary>>, quote, text) do
    quoted(rest, quote, [unescaped(escaped) | text])
  end

  defp quoted(<<quote, rest::binary>>, quote, text),
    do: {:ok, text |> Enum.reverse() |> List.to_string(), rest}

  defp quoted(<<char::utf8, rest::binary>>, quote, text), do: quoted(rest, quote, [char | text])

  defp unescaped(?n), do: ?\n
  defp unescaped(?t), do: ?\t
  defp unescaped(char), do: char

  defp expression(tokens, []), do: unary(tokens)

  defp expression(tokens, [operators | tighter]) do
    with {:ok, left, rest} <- expression(tokens, tighter) do
      continued(left, rest, operators, tighter)
    end
  end

  defp continued(left, [operator | rest] = tokens, operators, tighter) do
    if operator in operators do
      with {:ok, right, rest} <- expression(rest, tighter) do
        continued({:binary, operator, left, right}, rest, operators, tighter)
      end
    else
      {:ok, left, tokens}
    end
  end

  defp continued(left, [], _operators, _tighter), do: {:ok, left, []}

  defp unary([:! | rest]) do
    with {:ok, operand, rest} <- unary(rest), do: {:ok, {:unary, :not, operand}, rest}
  end

  defp unary([:- | rest]) do
    with {:ok, operand, rest} <- unary(rest), do: {:ok, {:unary, :negate, operand}, rest}
  end

  defp unary(tokens) do
    with {:ok, primary, rest} <- primary(tokens), do: postfix(primary, rest)
  end

  defp postfix(target, [:., {:word, name} | rest]),
    do: postfix({:member, target, name}, rest)

  defp postfix(target, [:"(" | rest]) do
    with {:ok, arguments, rest} <- items(rest, :")", []) do
      postfix({:call, target, arguments}, rest)
    end
  end

  defp postfix(target, [:"[" | rest]) do
    with {:ok, key, rest} <- expression(rest, @levels) do
      case rest do
        [:"]" | rest] -> postfix({:index, target, key}, rest)
        _open -> {:error, "a [ is never closed"}
      end
    end
  end

  defp postfix(target, rest), do: {:ok, target, rest}

  defp primary([{:number, number} | rest]), do: {:ok, {:literal, number}, rest}
  defp primary([{:string, text} | rest]), do: {:ok, {:literal, text}, rest}
  defp primary([{:word, "true"} | rest]), do: {:ok, {:literal, true}, rest}
  defp primary([{:word, "false"} | rest]), do: {:ok, {:literal, false}, rest}
  defp primary([{:word, "null"} | rest]), do: {:ok, {:literal, nil}, rest}
  defp primary([{:word, name} | rest]), do: {:ok, {:name, name}, rest}

  defp primary([:"(" | rest]) do
    with {:ok, inner, rest} <- expression(rest, @levels) do
      case rest do
        [:")" | rest] -> {:ok, inner, rest}
        _open -> {:error, "a ( is never closed"}
      end
    end
  end

  defp primary([:"[" | rest]) do
    with {:ok, items, rest} <- items(rest, :"]", []), do: {:ok, {:list, items}, rest}
  end

  defp primary([token | _rest]), do: {:error, "unexpected #{shown(token)}"}
  defp primary([]), do: {:error, "the expression ends too soon"}

  defp items([closing | rest], closing, []), do: {:ok, [], rest}

  defp items(tokens, closing, found) do
    with {:ok, item, rest} <- expression(tokens, @levels) do
      case rest do
        [:"," | rest] -> items(rest, closing, [item | found])
        [^closing | rest] -> {:ok, Enum.reverse([item | found]), rest}
        _open -> {:error, "a list or call is never closed"}
      end
    end
  end

  defp shown({:string, text}), do: inspect(text)
  defp shown({_kind, value}), do: to_string(value)
  defp shown(:and), do: "&&"
  defp shown(:or), do: "||"
  defp shown(operator), do: Atom.to_string(operator)
end
