defmodule BabelSyncWeb.ClientAddress do
  @moduledoc """
  The address a request came from. Behind a proxy on the same machine,
  such as a tunnel, every connection arrives from loopback, so the
  address the proxy reports is used instead. A forwarding header from
  anywhere else is ignored: the sender could have written anything in it.
  """

  @forwarding_headers ~w(cf-connecting-ip x-forwarded-for)

  @spec of(Plug.Conn.t()) :: String.t()
  def of(%Plug.Conn{remote_ip: remote_ip} = conn) do
    forwarded = if loopback?(remote_ip), do: forwarded(conn)
    forwarded || remote_ip |> :inet.ntoa() |> to_string()
  end

  defp forwarded(conn) do
    Enum.find_value(@forwarding_headers, fn header ->
      with [value | _rest] <- Plug.Conn.get_req_header(conn, header),
           [first | _rest] <- String.split(value, ",", trim: true),
           {:ok, address} <- first |> String.trim() |> to_charlist() |> :inet.parse_address() do
        address |> :inet.ntoa() |> to_string()
      else
        _absent -> nil
      end
    end)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_other), do: false
end
