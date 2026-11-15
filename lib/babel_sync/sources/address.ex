defmodule BabelSync.Sources.Address do
  @moduledoc """
  Tells the addresses of the open internet from those that only mean
  something from where the server stands: itself, its own network, a
  tailnet, link-local addresses such as a cloud's metadata service, and
  the IPv6 forms that carry any of these inside them.
  """

  import Bitwise

  @spec private?(:inet.ip_address()) :: boolean()
  def private?({a, b, _, _}) do
    a in [0, 10, 127] or a >= 224 or (a == 100 and b in 64..127) or (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or (a == 192 and b in [0, 168]) or (a == 198 and b in 18..19)
  end

  def private?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: private?(embedded(high, low))
  def private?({0x64, 0xFF9B, _, _, _, _, high, low}), do: private?(embedded(high, low))
  def private?({0x2002, high, low, _, _, _, _, _}), do: private?(embedded(high, low))
  def private?({0, 0, 0, 0, 0, 0, 0, last}) when last in [0, 1], do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFE00) == 0xFC00, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: true
  def private?({first, _, _, _, _, _, _, _}) when (first &&& 0xFF00) == 0xFF00, do: true
  def private?({_, _, _, _, _, _, _, _}), do: false

  @spec resolve(String.t()) :: [:inet.ip_address()]
  def resolve(host) do
    name = String.to_charlist(host)

    case :inet.parse_address(name) do
      {:ok, literal} ->
        [literal]

      {:error, :einval} ->
        for family <- [:inet, :inet6],
            {:ok, {:hostent, _, _, _, _, found}} <- [:inet.gethostbyname(name, family)],
            address <- found,
            do: address
    end
  end

  defp embedded(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
end
