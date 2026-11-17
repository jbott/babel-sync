defmodule BabelSync.Bases.Evaluation do
  @moduledoc """
  Works out a parsed Bases expression against one note.

  Covers what filters and formulas commonly use: note properties, the
  `file.*` fields and methods, `formula.*`, comparison and arithmetic,
  text and list methods, dates with durations such as `now() - "7d"`,
  and the functions `if`, `date`, `now`, `today`, `number`, `list`,
  `link`, `min` and `max`. `distance(a, b)`, in kilometres between two
  coordinates, is an addition of ours.

  A property a note lacks is null, and a method called on null gives
  null or false, so a filter simply does not match that note. A function
  or method this module does not know is an error, so the caller hears
  of it.
  """

  alias BabelSync.Bases.{Expression, Geo, Note}

  @type context :: %{
          required(:note) => Note.t(),
          optional(:formulas) => %{optional(String.t()) => Expression.t()},
          optional(:now) => DateTime.t(),
          optional(:depth) => non_neg_integer(),
          optional(:remembered) => :ets.tid()
        }

  @formula_depth 20
  @methods ~w(inFolder hasTag hasLink hasProperty asLink contains containsAll containsAny
              startsWith endsWith isEmpty lower upper trim title replace split slice reverse
              toString abs ceil floor round toFixed join sort unique flat date time format
              isTruthy)
  @units %{
    "y" => :year,
    "year" => :year,
    "years" => :year,
    "M" => :month,
    "month" => :month,
    "months" => :month,
    "w" => :week,
    "week" => :week,
    "weeks" => :week,
    "d" => :day,
    "day" => :day,
    "days" => :day,
    "h" => :hour,
    "hour" => :hour,
    "hours" => :hour,
    "m" => :minute,
    "minute" => :minute,
    "minutes" => :minute,
    "s" => :second,
    "second" => :second,
    "seconds" => :second
  }

  @spec run(Expression.t(), context()) :: {:ok, term()} | {:error, String.t()}
  def run(tree, context) do
    {:ok, value(tree, context)}
  catch
    {:invalid, message} -> {:error, message}
  end

  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value not in [nil, false, "", 0, []] and value != 0.0

  @spec order(term(), term()) :: :lt | :eq | :gt | nil
  def order(left, right) when is_number(left) and is_number(right), do: sign(left, right)
  def order(left, right) when is_binary(left) and is_binary(right), do: sign(left, right)
  def order(left, right) when is_boolean(left) and is_boolean(right), do: sign(left, right)
  def order(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right)

  def order(%DateTime{} = left, right) when is_binary(right),
    do: with(%DateTime{} = right <- moment(right), do: order(left, right))

  def order(left, %DateTime{} = right) when is_binary(left),
    do: with(%DateTime{} = left <- moment(left), do: order(left, right))

  def order(_left, _right), do: nil

  @spec sorts_before?(term(), term()) :: boolean()
  def sorts_before?(left, right) do
    case {order(left, right), rank(left), rank(right)} do
      {:lt, _left, _right} -> true
      {nil, left, right} -> left < right
      _other -> false
    end
  end

  @spec shown(term()) :: String.t()
  def shown(nil), do: ""
  def shown(value) when is_binary(value), do: value
  def shown(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  def shown(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def shown(%DateTime{} = value), do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def shown(value) when is_list(value), do: Enum.map_join(value, ", ", &shown/1)
  def shown(%{} = value), do: Jason.encode!(value)
  def shown(value), do: inspect(value)

  @spec moment(term()) :: DateTime.t() | nil
  def moment(%DateTime{} = moment), do: moment
  def moment(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00])
  def moment(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  def moment(text) when is_binary(text) do
    text = text |> String.trim() |> String.replace(~r/^(\d{4}-\d{2}-\d{2}) /, "\\1T")

    with {:error, _reason} <- DateTime.from_iso8601(text),
         {:error, _reason} <- NaiveDateTime.from_iso8601(text),
         {:error, _reason} <- NaiveDateTime.from_iso8601(text <> ":00"),
         {:error, _reason} <- Date.from_iso8601(text) do
      nil
    else
      {:ok, %DateTime{} = moment, _offset} -> moment
      {:ok, other} -> moment(other)
    end
  end

  def moment(_other), do: nil

  defp value({:literal, literal}, _context), do: literal
  defp value({:list, items}, context), do: Enum.map(items, &value(&1, context))

  defp value({:name, name}, _context) when name in ~w(file note formula),
    do: {:scope, name}

  defp value({:name, "this"}, _context), do: nil
  defp value({:name, name}, %{note: note}), do: note.properties[name]

  defp value({:member, target, name}, context),
    do: member(value(target, context), name, context)

  defp value({:index, target, key}, context) do
    case {value(target, context), value(key, context)} do
      {list, index} when is_list(list) and is_integer(index) -> Enum.at(list, index)
      {target, key} when is_binary(key) -> member(target, key, context)
      _other -> nil
    end
  end

  defp value({:unary, :not, operand}, context), do: not truthy?(value(operand, context))

  defp value({:unary, :negate, operand}, context) do
    case value(operand, context) do
      number when is_number(number) -> -number
      _other -> nil
    end
  end

  defp value({:binary, :and, left, right}, context),
    do: truthy?(value(left, context)) and truthy?(value(right, context))

  defp value({:binary, :or, left, right}, context),
    do: truthy?(value(left, context)) or truthy?(value(right, context))

  defp value({:binary, operator, left, right}, context),
    do: combined(operator, value(left, context), value(right, context))

  defp value({:call, {:name, "if"}, [condition, yes | no]}, context) do
    cond do
      truthy?(value(condition, context)) -> value(yes, context)
      no == [] -> nil
      true -> value(hd(no), context)
    end
  end

  defp value({:call, {:name, name}, arguments}, context),
    do: function(name, Enum.map(arguments, &value(&1, context)), context)

  defp value({:call, {:member, target, name}, arguments}, context) do
    if name not in @methods, do: throw({:invalid, "there is no method #{name}()"})
    method(value(target, context), name, Enum.map(arguments, &value(&1, context)), context)
  end

  defp value({:call, _other, _arguments}, _context),
    do: throw({:invalid, "only a named function or a method can be called"})

  defp remembered(%{remembered: table, note: note}, name, work) do
    key = {note.path, name}

    case :ets.lookup(table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = work.()
        :ets.insert(table, {key, value})
        value
    end
  end

  defp remembered(_context, _name, work), do: work.()

  defp member({:scope, "note"}, name, %{note: note}), do: note.properties[name]

  defp member({:scope, "formula"}, name, context) do
    depth = Map.get(context, :depth, 0)

    case Map.get(context, :formulas, %{}) do
      %{^name => _tree} when depth >= @formula_depth ->
        throw({:invalid, "formula #{name} refers to itself"})

      %{^name => tree} ->
        remembered(context, name, fn -> value(tree, Map.put(context, :depth, depth + 1)) end)

      _formulas ->
        throw({:invalid, "there is no formula named #{name}"})
    end
  end

  defp member({:scope, "file"}, name, %{note: note}) do
    case name do
      "name" -> Note.name(note)
      "basename" -> Note.basename(note)
      "path" -> note.path
      "folder" -> Note.folder(note)
      "ext" -> Note.extension(note)
      "size" -> note.size
      "ctime" -> note.created
      "mtime" -> note.modified
      "tags" -> Note.tags(note)
      "links" -> Note.links(note)
      "properties" -> note.properties
      "file" -> {:scope, "file"}
      _other -> throw({:invalid, "there is no file.#{name}"})
    end
  end

  defp member(text, "length", _context) when is_binary(text), do: String.length(text)
  defp member(list, "length", _context) when is_list(list), do: length(list)

  defp member(%DateTime{} = moment, name, _context)
       when name in ~w(year month day hour minute second),
       do: Map.fetch!(moment, String.to_existing_atom(name))

  defp member(%{} = map, name, _context) when not is_struct(map), do: map[name]
  defp member(_other, _name, _context), do: nil

  defp combined(:==, left, right), do: equal?(left, right)
  defp combined(:!=, left, right), do: not equal?(left, right)
  defp combined(:<, left, right), do: order(left, right) == :lt
  defp combined(:<=, left, right), do: order(left, right) in [:lt, :eq]
  defp combined(:>, left, right), do: order(left, right) == :gt
  defp combined(:>=, left, right), do: order(left, right) in [:gt, :eq]

  defp combined(:+, left, right) when is_number(left) and is_number(right), do: left + right
  defp combined(:+, %DateTime{} = left, right) when is_binary(right), do: shifted(left, right, 1)
  defp combined(:+, left, right) when is_list(left) and is_list(right), do: left ++ right

  defp combined(:+, left, right) when is_binary(left) or is_binary(right),
    do: shown(left) <> shown(right)

  defp combined(:-, left, right) when is_number(left) and is_number(right), do: left - right
  defp combined(:-, %DateTime{} = left, right) when is_binary(right), do: shifted(left, right, -1)

  defp combined(:-, %DateTime{} = left, %DateTime{} = right),
    do: DateTime.diff(left, right, :millisecond)

  defp combined(:*, left, right) when is_number(left) and is_number(right), do: left * right

  defp combined(:/, left, right) when is_number(left) and is_number(right) and right != 0,
    do: left / right

  defp combined(:%, left, right) when is_integer(left) and is_integer(right) and right != 0,
    do: rem(left, right)

  defp combined(_operator, _left, _right), do: nil

  defp equal?(left, right) when is_number(left) and is_number(right), do: left == right

  defp equal?(left, right) when is_list(left) and is_list(right),
    do: length(left) == length(right) and Enum.all?(Enum.zip(left, right), &equal?/1)

  defp equal?(left, right) do
    case order(left, right) do
      nil -> left === right
      order -> order == :eq
    end
  end

  defp equal?({left, right}), do: equal?(left, right)

  defp shifted(moment, duration, direction) do
    with [_all, amount, unit] <- Regex.run(~r/^\s*(\d+)\s*([A-Za-z]+)\s*$/, duration),
         %{^unit => unit} <- @units do
      DateTime.shift(moment, [{unit, direction * String.to_integer(amount)}])
    else
      _unreadable -> nil
    end
  end

  defp function("date", [value], _context), do: moment(value)
  defp function("now", [], context), do: now(context)

  defp function("today", [], context),
    do: context |> now() |> DateTime.to_date() |> moment()

  defp function("number", [value], _context), do: number(value)
  defp function("list", [value], _context), do: List.wrap(value)
  defp function("link", [target], _context), do: link(target, nil)
  defp function("link", [target, shown], _context), do: link(target, shown)

  defp function("min", values, _context),
    do: values |> List.flatten() |> Enum.filter(&is_number/1) |> Enum.min(fn -> nil end)

  defp function("max", values, _context),
    do: values |> List.flatten() |> Enum.filter(&is_number/1) |> Enum.max(fn -> nil end)

  defp function("distance", [from, to], _context) do
    with {_lat, _lon} = from <- Geo.point(from), {_lat, _lon} = to <- Geo.point(to) do
      Geo.distance_km(from, to)
    end
  end

  defp function(name, arguments, _context),
    do: throw({:invalid, "there is no function #{name}() taking #{length(arguments)} values"})

  defp method({:scope, "file"}, "inFolder", [folder], %{note: note}) when is_binary(folder),
    do: Note.in_folder?(note, folder)

  defp method({:scope, "file"}, "hasTag", wanted, %{note: note}) do
    held = note |> Note.tags() |> Enum.map(&String.downcase/1)

    Enum.any?(List.flatten(wanted), fn tag ->
      tag = tag |> shown() |> String.trim_leading("#") |> String.downcase()
      Enum.any?(held, &(&1 == tag or String.starts_with?(&1, tag <> "/")))
    end)
  end

  defp method({:scope, "file"}, "hasLink", [target], %{note: note}) do
    wanted = target |> shown() |> linked() |> String.downcase()

    note
    |> Note.links()
    |> Enum.any?(fn link ->
      link = String.downcase(link)
      link == wanted or Path.basename(link) == Path.basename(wanted, ".md")
    end)
  end

  defp method({:scope, "file"}, "hasProperty", [name], %{note: note}),
    do: Map.has_key?(note.properties, shown(name))

  defp method({:scope, "file"}, "asLink", _arguments, %{note: note}),
    do: link(note.path, nil)

  defp method(target, "isEmpty", [], _context), do: target in [nil, "", [], %{}]
  defp method(target, "isTruthy", [], _context), do: truthy?(target)
  defp method(target, "toString", [], _context), do: shown(target)

  defp method(text, "contains", [part], _context) when is_binary(text),
    do: folded(text) =~ folded(shown(part))

  defp method(list, "contains", [item], _context) when is_list(list),
    do: Enum.any?(list, &same?(&1, item))

  defp method(target, "containsAll", wanted, context) when is_binary(target) or is_list(target),
    do: wanted |> List.flatten() |> Enum.all?(&method(target, "contains", [&1], context))

  defp method(target, "containsAny", wanted, context) when is_binary(target) or is_list(target),
    do: wanted |> List.flatten() |> Enum.any?(&method(target, "contains", [&1], context))

  defp method(text, "startsWith", [part], _context) when is_binary(text) and is_binary(part),
    do: String.starts_with?(text, part)

  defp method(text, "endsWith", [part], _context) when is_binary(text) and is_binary(part),
    do: String.ends_with?(text, part)

  defp method(text, "lower", [], _context) when is_binary(text), do: String.downcase(text)
  defp method(text, "upper", [], _context) when is_binary(text), do: String.upcase(text)
  defp method(text, "trim", [], _context) when is_binary(text), do: String.trim(text)

  defp method(text, "title", [], _context) when is_binary(text),
    do: text |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

  defp method(text, "replace", [old, new], _context)
       when is_binary(text) and is_binary(old) and is_binary(new),
       do: String.replace(text, old, new)

  defp method(text, "split", [separator], _context) when is_binary(text) and is_binary(separator),
    do: String.split(text, separator)

  defp method(text, "slice", [from | to], _context) when is_binary(text) and is_integer(from),
    do: String.slice(text, span(from, to, String.length(text)))

  defp method(list, "slice", [from | to], _context) when is_list(list) and is_integer(from),
    do: Enum.slice(list, span(from, to, length(list)))

  defp method(text, "reverse", [], _context) when is_binary(text), do: String.reverse(text)
  defp method(list, "reverse", [], _context) when is_list(list), do: Enum.reverse(list)

  defp method(list, "join", separator, _context) when is_list(list),
    do: Enum.map_join(list, shown(List.first(separator) || ","), &shown/1)

  defp method(list, "sort", [], _context) when is_list(list),
    do: Enum.sort(list, &sorts_before?/2)

  defp method(list, "unique", [], _context) when is_list(list), do: Enum.uniq(list)
  defp method(list, "flat", [], _context) when is_list(list), do: List.flatten(list)

  defp method(number, "abs", [], _context) when is_number(number), do: abs(number)
  defp method(number, "ceil", [], _context) when is_number(number), do: ceil(number)
  defp method(number, "floor", [], _context) when is_number(number), do: floor(number)
  defp method(number, "round", [], _context) when is_number(number), do: round(number)

  defp method(number, name, [digits], _context)
       when is_number(number) and is_integer(digits) and digits >= 0 and
              name in ["round", "toFixed"] do
    rounded = Float.round(number * 1.0, min(digits, 15))
    if name == "toFixed", do: :erlang.float_to_binary(rounded, decimals: digits), else: rounded
  end

  defp method(%DateTime{} = moment, "date", [], _context),
    do: moment |> DateTime.to_date() |> moment()

  defp method(%DateTime{} = moment, "time", [], _context),
    do: moment |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()

  defp method(%DateTime{} = moment, "format", _pattern, _context), do: shown(moment)

  defp method(_target, name, _arguments, _context)
       when name in ~w(contains containsAll containsAny startsWith endsWith inFolder hasTag
                       hasLink hasProperty),
       do: false

  defp method(_target, _name, _arguments, _context), do: nil

  defp span(from, [to | _rest], _length) when is_integer(to) and to > from, do: from..(to - 1)//1
  defp span(from, [to | _rest], _length) when is_integer(to), do: from..from//-1
  defp span(from, _open, length), do: from..max(length - 1, from)//1

  defp same?(left, right) when is_binary(left) and is_binary(right),
    do: folded(left) == folded(right)

  defp same?(left, right), do: equal?(left, right)

  defp folded(text), do: String.downcase(text)

  defp linked(text) do
    case Regex.run(~r/^\[\[([^\]|#]+)/, text) do
      [_all, target] -> target
      nil -> text
    end
  end

  defp link(nil, _shown), do: nil

  defp link(target, shown) do
    target = shown(target)

    cond do
      target =~ ~r/^[a-z][a-z0-9+.-]*:\/\//i -> "[#{shown(shown || target)}](#{target})"
      shown -> "[[#{target}|#{shown(shown)}]]"
      true -> "[[#{target}]]"
    end
  end

  defp number(value) when is_number(value), do: value
  defp number(true), do: 1
  defp number(false), do: 0
  defp number(%DateTime{} = moment), do: DateTime.to_unix(moment, :millisecond)

  defp number(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _other -> nil
    end
  end

  defp number(_other), do: nil

  defp now(context), do: Map.get_lazy(context, :now, &DateTime.utc_now/0)

  defp sign(left, right) when left < right, do: :lt
  defp sign(left, right) when left > right, do: :gt
  defp sign(_left, _right), do: :eq

  defp rank(nil), do: 9
  defp rank(value) when is_number(value), do: 1
  defp rank(%DateTime{}), do: 2
  defp rank(value) when is_binary(value), do: 3
  defp rank(value) when is_boolean(value), do: 4
  defp rank(_other), do: 5
end
