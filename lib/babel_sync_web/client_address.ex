defmodule BabelSyncWeb.ClientAddress do
  @moduledoc """
  The address a request came from. Behind a proxy on the same machine,
  such as a tunnel, every connection arrives from loopback, so the
  address the proxy reports is used instead. A forwarding header from
  anywhere else is ignored: the sender could have written anything in it.
  """

  @forwarding_headers ~w(cf-connecting-ip x-forwarded-for)

  @spec of(Plug.Conn.t()) :: String.t()
  def of(%Plug.Conn{remote_ip: remote_ip, req_headers: headers}), do: resolve(remote_ip, headers)

  @spec of_socket(Phoenix.LiveView.Socket.t()) :: String.t()
  def of_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        resolve(address, Phoenix.LiveView.get_connect_info(socket, :x_headers) || [])

      nil ->
        "unknown"
    end
  end

  defp resolve(remote_ip, headers) do
    forwarded = if loopback?(remote_ip), do: forwarded(headers)
    forwarded || remote_ip |> :inet.ntoa() |> to_string()
  end

  defp forwarded(headers) do
    Enum.find_value(@forwarding_headers, fn header ->
      with {^header, value} <- List.keyfind(headers, header, 0),
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
