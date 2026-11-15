defmodule BabelSync.Sources.Fetch.Pinned do
  @moduledoc """
  Makes one request on one connection to an address looked at first.

  Req's own adapter connects by name, so the name is looked up a second
  time after any check of where it leads, and a name can be made to
  answer differently the second time. Here the name is looked up once,
  every address it gives is checked, and the connection goes to one of
  those addresses, with the name still used for the certificate.

  Written here over Mint because neither Req nor Finch lets a request
  choose the address apart from the name without keeping a pool per
  name for ever.
  """

  alias BabelSync.Sources.Address

  @connect_ms 10_000

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{url: url} = request) do
    private? = Req.Request.get_option(request, :pinned_private, false)

    outcome =
      with {:ok, address} <- address(url.host, private?),
           {:ok, conn} <- connect(url, address),
           {:ok, conn, ref} <- send_request(conn, request) do
        most = Req.Request.get_option(request, :pinned_most, 5_000_000)
        within = Req.Request.get_option(request, :receive_timeout, 30_000)
        deadline = System.monotonic_time(:millisecond) + within
        received = receive_all(conn, ref, %Req.Response{status: 0, body: []}, most, deadline)
        Mint.HTTP.close(conn)
        received
      end

    case outcome do
      {:ok, response} -> {request, response}
      {:error, reason} -> {request, failure(reason)}
      {:error, _conn, reason} -> {request, failure(reason)}
    end
  end

  defp address(host, private?) do
    case Enum.split_with(Address.resolve(host), &Address.private?/1) do
      {[], []} -> {:error, "#{host} has no address"}
      {[], [address | _rest]} -> {:ok, address}
      {[address | _rest], _public} when private? -> {:ok, address}
      {_private, _public} -> {:error, "#{host} is on a private network"}
    end
  end

  defp connect(%URI{scheme: scheme, host: host, port: port}, address) do
    Mint.HTTP.connect(String.to_existing_atom(scheme), address, port,
      hostname: host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: @connect_ms]
    )
  end

  defp send_request(conn, %Req.Request{url: url} = request) do
    path = (url.path || "/") <> if(url.query, do: "?" <> url.query, else: "")
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}
    method = request.method |> to_string() |> String.upcase()
    Mint.HTTP.request(conn, method, path, headers, request.body)
  end

  defp receive_all(conn, ref, response, room, deadline) do
    left = deadline - System.monotonic_time(:millisecond)

    with true <- left > 0 || {:error, "took too long to answer"},
         {:ok, conn, parts} <- Mint.HTTP.recv(conn, 0, left) do
      {response, room, done?} = Enum.reduce(parts, {response, room, false}, &part(&1, &2, ref))

      cond do
        room < 0 -> {:error, "answered with more than this source may read"}
        done? -> {:ok, %{response | body: IO.iodata_to_binary(response.body)}}
        true -> receive_all(conn, ref, response, room, deadline)
      end
    else
      {:error, _conn, reason, _parts} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp part({:status, ref, status}, {response, room, done?}, ref),
    do: {%{response | status: status}, room, done?}

  defp part({:headers, ref, headers}, {response, room, done?}, ref) do
    held =
      Enum.reduce(headers, response.headers, fn {name, value}, held ->
        Map.update(held, name, [value], &(&1 ++ [value]))
      end)

    {%{response | headers: held}, room, done?}
  end

  defp part({:data, ref, data}, {response, room, done?}, ref),
    do: {%{response | body: [response.body, data]}, room - byte_size(data), done?}

  defp part({:done, ref}, {response, room, _done?}, ref), do: {response, room, true}
  defp part(_other, seen, _ref), do: seen

  defp failure(reason) when is_binary(reason), do: RuntimeError.exception(reason)
  defp failure(%{__exception__: true} = reason), do: reason
  defp failure(reason), do: RuntimeError.exception(inspect(reason))
end
