defmodule BabelSync.Sources.Fetch do
  @moduledoc """
  The only way a source reaches the network.

  A request goes through only to a host the source was approved for,
  over https, and to an address on the open internet; a host the
  operator has named in `BABELSYNC_SOURCES_PRIVATE_HOSTS` may be on the
  server's own network and may be plain http. A redirect is followed
  only when where it leads passes the same checks.

  Secrets are added here and nowhere else. Each belongs to one host and
  goes out as one header, on requests to that host only, so the script
  that asked for the request never holds it; should the answer repeat
  it, it is blanked before the script reads the answer.
  """

  alias BabelSync.Sources.Fetch.Pinned

  @type secret :: %{host: String.t(), header: String.t(), value: String.t()}
  @type answer :: %{
          status: non_neg_integer(),
          headers: %{String.t() => String.t()},
          body: binary(),
          url: String.t()
        }

  @hops 5
  @methods ~w(GET POST PUT PATCH DELETE HEAD)
  @blank "[secret]"

  @spec request(map(), keyword()) :: {:ok, answer()} | {:error, String.t()}
  def request(%{url: url} = asked, grant) when is_binary(url) do
    method = asked |> Map.get(:method, "GET") |> String.upcase()

    if method in @methods,
      do: hop(%{asked | url: url} |> Map.put(:method, method), grant, @hops),
      else: {:error, "#{method} is not a method a source may use"}
  end

  defp hop(asked, grant, hops) do
    with {:ok, uri} <- allowed(asked.url, grant),
         {:ok, response} <- send_request(asked, uri, grant) do
      case {response.status in [301, 302, 303, 307, 308],
            Req.Response.get_header(response, "location")} do
        {true, [location | _]} when hops > 0 ->
          hop(onward(asked, uri, location, response.status), grant, hops - 1)

        {true, [_ | _]} ->
          {:error, "redirected too many times"}

        _answered ->
          {:ok, answer(response, uri, grant)}
      end
    end
  end

  defp onward(asked, from, location, status) do
    target = from |> URI.merge(location) |> URI.to_string()

    if status == 303 or (status in [301, 302] and asked.method == "POST"),
      do: asked |> Map.merge(%{url: target, method: "GET"}) |> Map.delete(:body),
      else: %{asked | url: target}
  end

  defp allowed(url, grant) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    private? = host in Keyword.get(grant, :private_hosts, [])

    cond do
      host in [nil, ""] ->
        {:error, "#{url} is not a web address"}

      uri.userinfo ->
        {:error, "a web address may not carry a password"}

      uri.scheme not in ["http", "https"] ->
        {:error, "#{url} is not a web address"}

      not granted?(host, Keyword.get(grant, :hosts, [])) ->
        {:error, "#{host} is not a host this source may reach"}

      uri.scheme == "http" and not private? ->
        {:error, "#{host} must be reached over https"}

      true ->
        {:ok, %{uri | host: host}}
    end
  end

  defp granted?(host, hosts) do
    Enum.any?(hosts, fn
      "*." <> domain -> String.ends_with?(host, "." <> domain)
      granted -> host == granted
    end)
  end

  defp send_request(asked, uri, grant) do
    headers =
      asked
      |> Map.get(:headers, %{})
      |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
      |> Enum.reject(fn {name, _value} ->
        name in ["host", "content-length", "transfer-encoding"]
      end)
      |> Map.new()
      |> Map.put_new("user-agent", "BabelSync source")
      |> Map.merge(
        for %{host: host} = secret <- secrets(grant),
            host == uri.host,
            into: %{},
            do: {String.downcase(secret.header), secret.value}
      )

    request =
      Req.new(
        method: asked.method |> String.downcase() |> String.to_existing_atom(),
        url: uri,
        headers: headers,
        body: Map.get(asked, :body),
        adapter: Pinned,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: Keyword.get(grant, :timeout, 30_000)
      )
      |> Req.Request.register_options([:pinned_private, :pinned_most])
      |> Req.Request.merge_options(
        pinned_private: uri.host in Keyword.get(grant, :private_hosts, []),
        pinned_most: Keyword.get(grant, :most, 5_000_000)
      )

    case Req.request(request) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, "#{uri.host}: #{Exception.message(error)}"}
    end
  end

  defp answer(response, uri, grant) do
    values = for %{value: value} <- secrets(grant), value != "", do: value

    %{
      status: response.status,
      url: URI.to_string(uri),
      headers:
        Map.new(response.headers, fn {name, held} ->
          {name, blank(Enum.join(held, ", "), values)}
        end),
      body: blank(response.body, values)
    }
  end

  defp blank(text, []), do: text
  defp blank(text, values), do: String.replace(text, values, @blank)

  defp secrets(grant), do: Keyword.get(grant, :secrets, [])
end
