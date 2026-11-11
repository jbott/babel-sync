defmodule BabelSync.Sync.TextDiff do
  @moduledoc """
  Turns "the text was `old`, now it is `new`" into the smallest practical
  list of edits, measured in bytes and never splitting a UTF-8 character.

  Used whenever something that is not a collaborative editor changes a
  note as a whole: an agent writing through MCP, a client reporting a file
  that changed on disk, or restoring an old version.
  """

  @type op :: {:retain, pos_integer()} | {:delete, pos_integer()} | {:insert, String.t()}

  @refine_limit 2_000

  @spec ops(String.t(), String.t()) :: [op()]
  def ops(old, new) when old == new, do: retain(byte_size(old))

  def ops(old, new) do
    prefix = common_prefix(old, new)
    old_rest = binary_part(old, prefix, byte_size(old) - prefix)
    new_rest = binary_part(new, prefix, byte_size(new) - prefix)
    suffix = common_suffix(old_rest, new_rest)
    old_mid = binary_part(old_rest, 0, byte_size(old_rest) - suffix)
    new_mid = binary_part(new_rest, 0, byte_size(new_rest) - suffix)

    compact(retain(prefix) ++ middle(old_mid, new_mid) ++ retain(suffix))
  end

  defp middle("", ""), do: []
  defp middle(old, ""), do: [{:delete, byte_size(old)}]
  defp middle("", new), do: [{:insert, new}]

  defp middle(old, new) do
    lines(old)
    |> List.myers_difference(lines(new))
    |> refine()
  end

  defp refine([{:del, old}, {:ins, new} | rest]), do: changed(old, new) ++ refine(rest)
  defp refine([{:ins, new}, {:del, old} | rest]), do: changed(old, new) ++ refine(rest)
  defp refine([{:eq, same} | rest]), do: retain(bytes(same)) ++ refine(rest)
  defp refine([{:del, old} | rest]), do: [{:delete, bytes(old)} | refine(rest)]
  defp refine([{:ins, new} | rest]), do: [{:insert, IO.iodata_to_binary(new)} | refine(rest)]
  defp refine([]), do: []

  defp changed(old_lines, new_lines) do
    old = IO.iodata_to_binary(old_lines)
    new = IO.iodata_to_binary(new_lines)

    if byte_size(old) + byte_size(new) <= @refine_limit do
      for {kind, text} <- String.myers_difference(old, new) do
        case kind do
          :eq -> {:retain, byte_size(text)}
          :del -> {:delete, byte_size(text)}
          :ins -> {:insert, text}
        end
      end
    else
      [{:delete, byte_size(old)}, {:insert, new}]
    end
  end

  defp lines(text), do: String.split(text, ~r/(?<=\n)/, trim: true)

  defp bytes(lines), do: IO.iodata_length(lines)

  defp retain(0), do: []
  defp retain(count), do: [{:retain, count}]

  defp common_prefix(a, b) do
    back_to_boundary(a, b, :binary.longest_common_prefix([a, b]))
  end

  defp back_to_boundary(_a, _b, 0), do: 0

  defp back_to_boundary(a, b, at) do
    if continuation?(a, at) or continuation?(b, at),
      do: back_to_boundary(a, b, at - 1),
      else: at
  end

  defp common_suffix(a, b) do
    forward_to_boundary(a, :binary.longest_common_suffix([a, b]))
  end

  defp forward_to_boundary(_a, 0), do: 0

  defp forward_to_boundary(a, length) do
    if continuation?(a, byte_size(a) - length),
      do: forward_to_boundary(a, length - 1),
      else: length
  end

  defp continuation?(binary, at) when at < byte_size(binary) do
    Bitwise.band(:binary.at(binary, at), 0b1100_0000) == 0b1000_0000
  end

  defp continuation?(_binary, _at), do: false

  defp compact([{:retain, a}, {:retain, b} | rest]), do: compact([{:retain, a + b} | rest])
  defp compact([{:delete, a}, {:delete, b} | rest]), do: compact([{:delete, a + b} | rest])
  defp compact([{:insert, a}, {:insert, b} | rest]), do: compact([{:insert, a <> b} | rest])
  defp compact([op | rest]), do: [op | compact(rest)]
  defp compact([]), do: []
end
